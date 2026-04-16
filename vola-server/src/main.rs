mod models;
mod db;
mod auth;
mod pubsub;

use axum::{
    extract::{ws::{Message, WebSocket, WebSocketUpgrade}, State, Path, Query},
    response::IntoResponse,
    routing::{get, post, patch},
    Router,
    Json, http::StatusCode,
};
use axum::extract::Multipart;
use tokio::fs::File;
use tokio::io::AsyncWriteExt;
use tower_http::services::ServeDir;
use futures::{sink::SinkExt, stream::StreamExt};
use models::{WsEvent, ChatMessage};
use pubsub::PubSub;
use tracing::{error, info, warn};
use dotenvy::dotenv;
use std::sync::Arc;
use tokio::sync::broadcast::error::RecvError;
use tower_http::cors::CorsLayer;
use jsonwebtoken::{decode, DecodingKey, Validation};

/// Global shared state injected into every route and WebSocket connection
pub struct AppState {
    pub db: db::DbPool,
    pub pubsub: PubSub,
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();
    dotenv().ok();

    let db_pool = db::init_db().await;

    let shared_state = Arc::new(AppState {
        db: db_pool,
        pubsub: PubSub::new(),
    });

    tokio::fs::create_dir_all("uploads").await.unwrap();

    let app = Router::new()
        .route("/health", get(|| async { "Server is running smoothly" }))
        .route("/api/register", post(auth::register_user))
        .route("/api/login", post(auth::login_user))
        .route("/api/users/:id", get(auth::get_user_profile))
        .route("/api/users/me", patch(auth::update_my_profile))
        .route("/api/users/me/avatar", post(auth::upload_avatar))
        .route("/api/upload", post(upload_image))
        .nest_service("/uploads", ServeDir::new("uploads"))
        .route("/api/messages/:room_id", get(get_messages))
        .route("/api/rooms", get(get_rooms))
        .route("/api/rooms", post(create_room))
        .route("/api/rooms/:room_id/members", get(get_room_members))
        .route("/api/rooms/dm", post(create_dm))
        .route("/ws", get(ws_handler))
        .with_state(shared_state)
        .layer(CorsLayer::permissive());

    let listener = tokio::net::TcpListener::bind("127.0.0.1:3000").await.unwrap();
    info!("Vola WebSocket relay listening on {}", listener.local_addr().unwrap());
    axum::serve(listener, app).await.unwrap();
}

async fn ws_handler(
    ws: WebSocketUpgrade,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_socket(socket, state))
}

async fn handle_socket(socket: WebSocket, state: Arc<AppState>) {
    info!("New WebSocket connection");

    let (ws_sender, mut ws_receiver) = socket.split();
    let ws_sender = Arc::new(tokio::sync::Mutex::new(ws_sender));

    // ─── STEP 1: Wait for Authentication ──────────────────────────────────────
    // The first message MUST be an Authenticate event. If not, kill the socket.
    let (auth_user_id, auth_user_name) = loop {
        match ws_receiver.next().await {
            Some(Ok(Message::Text(text))) => {
                match serde_json::from_str::<WsEvent>(&text) {
                    Ok(WsEvent::Authenticate { token }) => {
                        let secret = std::env::var("JWT_SECRET")
                            .unwrap_or_else(|_| "fallback_key".into());
                        match decode::<auth::Claims>(
                            &token,
                            &DecodingKey::from_secret(secret.as_bytes()),
                            &Validation::default(),
                        ) {
                            Ok(token_data) => {
                                info!(
                                    "✅ Verified: {} ({})",
                                    token_data.claims.name, token_data.claims.sub
                                );
                                break (token_data.claims.sub, token_data.claims.name);
                            }
                            Err(_) => {
                                warn!("❌ Invalid JWT — terminating socket");
                                return;
                            }
                        }
                    }
                    _ => {
                        warn!("First message was not Authenticate — terminating socket");
                        return;
                    }
                }
            }
            _ => return, // Connection dropped before auth
        }
    };

    // ─── STEP 2: Spawn ONE broadcast forwarder task ───────────────────────────
    // All room subscriptions feed into this single mpsc channel, which the
    // forwarder drains and pushes to the WebSocket sender. No more N spawns.
    let (forward_tx, mut forward_rx) = tokio::sync::mpsc::unbounded_channel::<WsEvent>();
    let forwarder_sender = ws_sender.clone();
    let forwarder_handle = tokio::spawn(async move {
        while let Some(event) = forward_rx.recv().await {
            let json = serde_json::to_string(&event).unwrap();
            let mut tx = forwarder_sender.lock().await;
            if tx.send(Message::Text(json)).await.is_err() {
                break; // Client disconnected
            }
        }
    });

    // Track which rooms this client is already subscribed to (dedup)
    let mut subscribed_rooms: std::collections::HashSet<String> = std::collections::HashSet::new();
    // Keep JoinHandles so we can abort room listeners on disconnect
    let mut room_listener_handles: Vec<tokio::task::JoinHandle<()>> = Vec::new();

    // ─── STEP 3: Process incoming messages ────────────────────────────────────
    while let Some(Ok(message)) = ws_receiver.next().await {
        match message {
            Message::Text(text) => {
                match serde_json::from_str::<WsEvent>(&text) {
                    Ok(WsEvent::SendMessage(chat_msg)) => {
                        // Persist to SQLite with REAL msg_type
                        let msg_type_str = chat_msg.msg_type.to_string();
                        let _ = sqlx::query(
                            "INSERT OR IGNORE INTO messages \
                             (id, sender_id, chat_room_id, content, msg_type, timestamp) \
                             VALUES (?, ?, ?, ?, ?, ?)",
                        )
                        .bind(&chat_msg.id)
                        .bind(&chat_msg.sender_id)
                        .bind(&chat_msg.chat_room_id)
                        .bind(&chat_msg.content)
                        .bind(&msg_type_str)
                        .bind(chat_msg.timestamp)
                        .execute(&state.db)
                        .await;

                        let room_id = chat_msg.chat_room_id.clone();

                        // Subscribe to this room ONCE (not per message)
                        if !subscribed_rooms.contains(&room_id) {
                            subscribed_rooms.insert(room_id.clone());
                            let mut room_rx = state.pubsub.subscribe(&room_id);
                            let fwd_tx = forward_tx.clone();
                            let handle = tokio::spawn(async move {
                                loop {
                                    match room_rx.recv().await {
                                        Ok(event) => {
                                            if fwd_tx.send(event).is_err() {
                                                break; // Forwarder dropped
                                            }
                                        }
                                        Err(RecvError::Lagged(n)) => {
                                            warn!("Client lagged by {} messages", n);
                                        }
                                        Err(RecvError::Closed) => break,
                                    }
                                }
                            });
                            room_listener_handles.push(handle);
                        }

                        // Publish to the room
                        let receivers = state
                            .pubsub
                            .publish(&room_id, WsEvent::NewMessage(chat_msg.clone()));
                        info!(
                            "Published to room '{}' → {} subscriber(s)",
                            room_id, receivers
                        );

                        // Ack back to sender
                        let ack = WsEvent::Ack {
                            message_id: chat_msg.id.clone(),
                        };
                        let ack_json = serde_json::to_string(&ack).unwrap();
                        let mut tx = ws_sender.lock().await;
                        if tx.send(Message::Text(ack_json)).await.is_err() {
                            break;
                        }
                    }

                    Ok(WsEvent::Authenticate { .. }) => {
                        // Already authenticated, ignore duplicate auth attempts
                        info!("Duplicate Authenticate received — ignoring");
                    }

                    Ok(WsEvent::Typing {
                        chat_room_id,
                        is_typing,
                    }) => {
                        // Inject REAL authenticated user identity
                        let typing_event = WsEvent::UserTyping {
                            user_id: auth_user_id.clone(),
                            chat_room_id: chat_room_id.clone(),
                            is_typing,
                        };
                        state.pubsub.publish(&chat_room_id, typing_event);
                    }

                    Ok(WsEvent::MarkRead {
                        chat_room_id,
                        message_id,
                    }) => {
                        // Update the pivot table watermark
                        sqlx::query("UPDATE user_rooms SET last_read_message_id = ? WHERE user_id = ? AND room_id = ?")
                            .bind(&message_id)
                            .bind(&auth_user_id)
                            .bind(&chat_room_id)
                            .execute(&state.db)
                            .await
                            .ok();

                        // Publish receipt to room
                        let read_event = WsEvent::MessageRead {
                            chat_room_id: chat_room_id.clone(),
                            user_id: auth_user_id.clone(),
                            message_id,
                        };
                        state.pubsub.publish(&chat_room_id, read_event);
                    }

                    Ok(_) => {}

                    Err(e) => {
                        error!("Failed to parse WsEvent: {} | raw: {}", e, text);
                        let err_ev = WsEvent::Error {
                            message: "Invalid message format".into(),
                        };
                        let json = serde_json::to_string(&err_ev).unwrap();
                        let mut tx = ws_sender.lock().await;
                        let _ = tx.send(Message::Text(json)).await;
                    }
                }
            }
            Message::Binary(_) => {
                info!("Binary payload received — reserved for future protobuf/media");
            }
            Message::Ping(_) | Message::Pong(_) => {}
            Message::Close(_) => {
                info!("Client {} ({}) disconnected gracefully", auth_user_name, auth_user_id);
                break;
            }
        }
    }

    // ─── CLEANUP: Cancel all room listener tasks and the forwarder ─────────────
    for handle in room_listener_handles {
        handle.abort();
    }
    forwarder_handle.abort();
    info!("Cleaned up {} room subscriptions for {}", subscribed_rooms.len(), auth_user_name);
}

#[derive(serde::Deserialize, Default)]
struct MessagesQuery {
    before: Option<i64>,
    limit: Option<i64>,
}

async fn get_messages(
    Path(room_id): Path<String>,
    Query(params): Query<MessagesQuery>,
    State(state): State<Arc<AppState>>
) -> Result<Json<Vec<ChatMessage>>, StatusCode> {
    use sqlx::Row;

    let limit = params.limit.unwrap_or(50).min(100);

    let records = if let Some(before_ts) = params.before {
        sqlx::query(
            "SELECT id, sender_id, chat_room_id, content, msg_type, timestamp \
             FROM messages WHERE chat_room_id = ? AND timestamp < ? \
             ORDER BY timestamp DESC LIMIT ?"
        )
        .bind(&room_id)
        .bind(before_ts)
        .bind(limit)
        .fetch_all(&state.db)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
    } else {
        sqlx::query(
            "SELECT id, sender_id, chat_room_id, content, msg_type, timestamp \
             FROM (SELECT id, sender_id, chat_room_id, content, msg_type, timestamp \
                   FROM messages WHERE chat_room_id = ? ORDER BY timestamp DESC LIMIT ?) \
             ORDER BY timestamp ASC"
        )
        .bind(&room_id)
        .bind(limit)
        .fetch_all(&state.db)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
    };

    let mut messages: Vec<ChatMessage> = records.iter().map(|rec| {
        let msg_type_str: String = rec.get("msg_type");
        let msg_type = match msg_type_str.as_str() {
            "ImageBlurHash" => models::MessageType::ImageBlurHash,
            "System" => models::MessageType::System,
            _ => models::MessageType::Text,
        };
        ChatMessage {
            id: rec.get("id"),
            sender_id: rec.get("sender_id"),
            chat_room_id: rec.get("chat_room_id"),
            content: rec.get("content"),
            msg_type,
            timestamp: rec.get("timestamp"),
        }
    }).collect();

    // Cursor pages come back DESC — reverse to ASC for display
    if params.before.is_some() {
        messages.reverse();
    }

    Ok(Json(messages))
}

async fn get_rooms(
    State(state): State<Arc<AppState>>,
    headers: axum::http::HeaderMap,
) -> Result<Json<Vec<models::ChatRoom>>, StatusCode> {
    use sqlx::Row;
    
    // We allow fetching rooms without strict auth failure so login screen can load dummy rooms, 
    // but if authenticated, we'll fetch their specific DMs too.
    let user_id_result = auth::extract_user_id_from_header(&headers);
    
    let records = if let Ok(user_id) = user_id_result {
        sqlx::query(
            "SELECT id, name FROM chat_rooms WHERE id NOT LIKE 'dm_%'
             UNION
             SELECT c.id, c.name FROM chat_rooms c
             JOIN user_rooms ur ON c.id = ur.room_id
             WHERE ur.user_id = ? AND c.id LIKE 'dm_%'"
        )
        .bind(user_id)
        .fetch_all(&state.db)
        .await
    } else {
        sqlx::query("SELECT id, name FROM chat_rooms WHERE id NOT LIKE 'dm_%'")
            .fetch_all(&state.db)
            .await
    }.map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    let mut rooms = Vec::new();
    for rec in records {
        rooms.push(models::ChatRoom {
            id: rec.get("id"),
            name: rec.get("name"),
        });
    }

    Ok(Json(rooms))
}

async fn create_room(
    State(state): State<Arc<AppState>>,
    headers: axum::http::HeaderMap,
    Json(payload): Json<models::CreateRoomReq>,
) -> Result<Json<models::ChatRoom>, (StatusCode, String)> {
    let user_id = auth::extract_user_id_from_header(&headers)?;
    let new_id = format!("room_{}", &uuid::Uuid::new_v4().to_string().replace("-", "")[0..8]);

    sqlx::query("INSERT INTO chat_rooms (id, name) VALUES (?, ?)")
        .bind(&new_id)
        .bind(&payload.name)
        .execute(&state.db)
        .await
        .map_err(|_| (StatusCode::INTERNAL_SERVER_ERROR, "Failed to create room".into()))?;

    // Auto-join the creator
    sqlx::query("INSERT INTO user_rooms (user_id, room_id) VALUES (?, ?)")
        .bind(&user_id)
        .bind(&new_id)
        .execute(&state.db)
        .await
        .ok();

    Ok(Json(models::ChatRoom {
        id: new_id,
        name: payload.name,
    }))
}

async fn create_dm(
    State(state): State<Arc<AppState>>,
    headers: axum::http::HeaderMap,
    Json(payload): Json<models::CreateDmReq>,
) -> Result<Json<models::ChatRoom>, (StatusCode, String)> {
    use sqlx::Row;
    let user_id = auth::extract_user_id_from_header(&headers)?;
    let target = payload.target_user_id;
    
    if user_id == target {
        return Err((StatusCode::BAD_REQUEST, "Cannot DM yourself".into()));
    }

    let mut ids = vec![user_id.clone(), target.clone()];
    ids.sort();
    let dm_id = format!("dm_{}_{}", ids[0], ids[1]);

    // Check if exists
    let existing_row = sqlx::query("SELECT id, name FROM chat_rooms WHERE id = ?")
        .bind(&dm_id)
        .fetch_optional(&state.db)
        .await
        .map_err(|_| (StatusCode::INTERNAL_SERVER_ERROR, "DB Error".into()))?;

    if let Some(row) = existing_row {
        return Ok(Json(models::ChatRoom {
            id: row.get("id"),
            name: row.get("name"),
        }));
    }

    // Attempt to fetch target explicitly to build a nice name
    let target_row = sqlx::query("SELECT username FROM users WHERE id = ?")
        .bind(&target)
        .fetch_optional(&state.db)
        .await
        .map_err(|_| (StatusCode::INTERNAL_SERVER_ERROR, "DB Error".into()))?;

    let _t_username: String = target_row.map(|r| r.get("username")).unwrap_or_else(|| "User".into());
    let room_name = format!("DM"); // Front-end resolves the real name from the member list

    sqlx::query("INSERT INTO chat_rooms (id, name) VALUES (?, ?)")
        .bind(&dm_id)
        .bind(&room_name)
        .execute(&state.db)
        .await
        .map_err(|_| (StatusCode::INTERNAL_SERVER_ERROR, "Create Error".into()))?;

    // Insert both mappings
    sqlx::query("INSERT INTO user_rooms (user_id, room_id) VALUES (?, ?), (?, ?)")
        .bind(&user_id).bind(&dm_id)
        .bind(&target).bind(&dm_id)
        .execute(&state.db)
        .await
        .ok();

    Ok(Json(models::ChatRoom {
        id: dm_id,
        name: room_name,
    }))
}

#[derive(serde::Serialize)]
struct RoomMember {
    id: String,
    username: String,
    display_name: Option<String>,
    avatar_url: Option<String>,
    last_read_message_id: Option<String>,
}

async fn get_room_members(
    Path(room_id): Path<String>,
    State(state): State<Arc<AppState>>
) -> Result<Json<Vec<RoomMember>>, StatusCode> {
    use sqlx::Row;
    
    // Fallback: For now, if user_rooms is empty (due to dummy rooms), 
    // everyone is basically in the dummy rooms. But for real rooms, we fetch mapping.
    let records = sqlx::query(
        "SELECT u.id, u.username, u.display_name, u.avatar_url, ur.last_read_message_id 
         FROM users u
         JOIN user_rooms ur ON u.id = ur.user_id
         WHERE ur.room_id = ?"
    )
    .bind(room_id)
    .fetch_all(&state.db)
    .await
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    let mut members = Vec::new();
    for rec in records {
        members.push(RoomMember {
            id: rec.get("id"),
            username: rec.get("username"),
            display_name: rec.get("display_name"),
            avatar_url: rec.get("avatar_url"),
            last_read_message_id: rec.get("last_read_message_id"),
        });
    }

    Ok(Json(members))
}

async fn upload_image(mut multipart: Multipart) -> Result<Json<serde_json::Value>, StatusCode> {
    while let Some(field) = multipart.next_field().await.map_err(|_| StatusCode::BAD_REQUEST)? {
        let name = field.name().unwrap_or("").to_string();
        if name == "file" {
            let file_name = field.file_name().unwrap_or("upload.jpg").to_string();
            let id = uuid::Uuid::new_v4().to_string();
            let ext = file_name.split('.').last().unwrap_or("jpg");
            let save_path = format!("uploads/{}.{}", id, ext);
            let public_url = format!("http://127.0.0.1:3000/{}", save_path);
            
            let data = field.bytes().await.map_err(|_| StatusCode::BAD_REQUEST)?;
            
            // Save the file to disk
            let mut file = File::create(&save_path).await.map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
            file.write_all(&data).await.map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
            
            // Compute real BlurHash from image bytes (offload to blocking thread)
            let data_clone = data.to_vec();
            let hash = tokio::task::spawn_blocking(move || -> Result<String, StatusCode> {
                let img = image::load_from_memory(&data_clone)
                    .map_err(|_| StatusCode::BAD_REQUEST)?;
                let thumbnail = img.thumbnail(32, 32);
                let (w, h) = (thumbnail.width(), thumbnail.height());
                let rgba = thumbnail.to_rgba8();
                let pixels: Vec<u8> = rgba.into_raw();
                let hash = blurhash::encode(4, 3, w, h, &pixels)
                    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
                Ok(hash)
            })
            .await
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
            .map_err(|e| e)?;
            
            return Ok(Json(serde_json::json!({
                "hash": hash,
                "hd_url": public_url
            })));
        }
    }
    Err(StatusCode::BAD_REQUEST)
}
