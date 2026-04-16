use axum::{extract::State, Json, http::StatusCode};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use uuid::Uuid;
use jsonwebtoken::{encode, Header, EncodingKey};
use std::time::{SystemTime, UNIX_EPOCH};
use crate::AppState;
use std::env;
use sha2::{Sha256, Digest};

#[derive(Debug, Serialize, Deserialize)]
pub struct Claims {
    pub sub: String,    // User ID
    pub name: String,   // Username
    pub exp: usize,     // Expiration time
}

// ─── Request / Response Structs ───────────────────────────────────────────────

#[derive(Deserialize)]
pub struct RegisterReq {
    pub username: String,
    pub password: String,
}

#[derive(Deserialize)]
pub struct LoginReq {
    pub username: String,
    pub password: String,
}

#[derive(Serialize)]
pub struct AuthRes {
    pub id: String,
    pub username: String,
    pub display_name: Option<String>,
    pub avatar_url: Option<String>,
    pub token: String,
}

#[derive(Serialize)]
pub struct UserProfile {
    pub id: String,
    pub username: String,
    pub display_name: Option<String>,
    pub avatar_url: Option<String>,
    pub bio: Option<String>,
}

#[derive(Deserialize)]
pub struct UpdateProfileReq {
    pub display_name: Option<String>,
    pub bio: Option<String>,
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

fn hash_password(password: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(password.as_bytes());
    format!("{:x}", hasher.finalize())
}

fn issue_jwt(user_id: &str, username: &str) -> String {
    let secret = env::var("JWT_SECRET").unwrap_or_else(|_| "fallback_key".into());
    let expiration = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as usize + 3600 * 24 * 30; // 30 days

    let claims = Claims {
        sub: user_id.to_string(),
        name: username.to_string(),
        exp: expiration,
    };

    encode(
        &Header::default(),
        &claims,
        &EncodingKey::from_secret(secret.as_bytes()),
    )
    .unwrap()
}

// ─── POST /api/register ───────────────────────────────────────────────────────

pub async fn register_user(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<RegisterReq>,
) -> Result<Json<AuthRes>, (StatusCode, String)> {
    if payload.username.trim().is_empty() || payload.password.trim().is_empty() {
        return Err((StatusCode::BAD_REQUEST, "Username and password are required".into()));
    }
    if payload.username.len() > 32 {
        return Err((StatusCode::BAD_REQUEST, "Username must be 32 characters or less".into()));
    }
    if payload.password.len() < 4 {
        return Err((StatusCode::BAD_REQUEST, "Password must be at least 4 characters".into()));
    }

    let new_id = Uuid::new_v4().to_string();
    let pw_hash = hash_password(&payload.password);

    let result = sqlx::query(
        "INSERT INTO users (id, username, password_hash, display_name) VALUES (?, ?, ?, ?)"
    )
    .bind(&new_id)
    .bind(&payload.username)
    .bind(&pw_hash)
    .bind(&payload.username) // display_name defaults to username
    .execute(&state.db)
    .await;

    match result {
        Ok(_) => {
            let token = issue_jwt(&new_id, &payload.username);
            Ok(Json(AuthRes {
                id: new_id,
                username: payload.username,
                display_name: None,
                avatar_url: None,
                token,
            }))
        },
        Err(e) => {
            tracing::error!("Failed to register user: {}", e);
            Err((StatusCode::CONFLICT, "Username is already taken".into()))
        }
    }
}

// ─── POST /api/login ──────────────────────────────────────────────────────────

pub async fn login_user(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<LoginReq>,
) -> Result<Json<AuthRes>, (StatusCode, String)> {
    use sqlx::Row;

    let pw_hash = hash_password(&payload.password);

    let row = sqlx::query(
        "SELECT id, username, display_name, avatar_url FROM users WHERE username = ? AND password_hash = ?"
    )
    .bind(&payload.username)
    .bind(&pw_hash)
    .fetch_optional(&state.db)
    .await
    .map_err(|e| {
        tracing::error!("Login query failed: {}", e);
        (StatusCode::INTERNAL_SERVER_ERROR, "Server error".into())
    })?;

    match row {
        Some(rec) => {
            let id: String = rec.get("id");
            let username: String = rec.get("username");
            let display_name: Option<String> = rec.get("display_name");
            let avatar_url: Option<String> = rec.get("avatar_url");
            let token = issue_jwt(&id, &username);

            Ok(Json(AuthRes {
                id,
                username,
                display_name,
                avatar_url,
                token,
            }))
        },
        None => {
            Err((StatusCode::UNAUTHORIZED, "Invalid username or password".into()))
        }
    }
}

// ─── GET /api/users/:id ──────────────────────────────────────────────────────

pub async fn get_user_profile(
    axum::extract::Path(user_id): axum::extract::Path<String>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<UserProfile>, StatusCode> {
    use sqlx::Row;

    let row = sqlx::query(
        "SELECT id, username, display_name, avatar_url, bio FROM users WHERE id = ?"
    )
    .bind(&user_id)
    .fetch_optional(&state.db)
    .await
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    match row {
        Some(rec) => Ok(Json(UserProfile {
            id: rec.get("id"),
            username: rec.get("username"),
            display_name: rec.get("display_name"),
            avatar_url: rec.get("avatar_url"),
            bio: rec.get("bio"),
        })),
        None => Err(StatusCode::NOT_FOUND),
    }
}

// ─── PATCH /api/users/me ─────────────────────────────────────────────────────
// Authenticated route — extracts user_id from Authorization: Bearer <jwt>

pub async fn update_my_profile(
    State(state): State<Arc<AppState>>,
    headers: axum::http::HeaderMap,
    Json(payload): Json<UpdateProfileReq>,
) -> Result<Json<UserProfile>, (StatusCode, String)> {
    use sqlx::Row;

    let user_id = extract_user_id_from_header(&headers)?;

    if let Some(ref name) = payload.display_name {
        sqlx::query("UPDATE users SET display_name = ? WHERE id = ?")
            .bind(name)
            .bind(&user_id)
            .execute(&state.db)
            .await
            .map_err(|_| (StatusCode::INTERNAL_SERVER_ERROR, "Failed to update".into()))?;
    }
    if let Some(ref bio) = payload.bio {
        sqlx::query("UPDATE users SET bio = ? WHERE id = ?")
            .bind(bio)
            .bind(&user_id)
            .execute(&state.db)
            .await
            .map_err(|_| (StatusCode::INTERNAL_SERVER_ERROR, "Failed to update".into()))?;
    }

    // Return updated profile
    let row = sqlx::query("SELECT id, username, display_name, avatar_url, bio FROM users WHERE id = ?")
        .bind(&user_id)
        .fetch_one(&state.db)
        .await
        .map_err(|_| (StatusCode::INTERNAL_SERVER_ERROR, "Failed to fetch profile".into()))?;

    Ok(Json(UserProfile {
        id: row.get("id"),
        username: row.get("username"),
        display_name: row.get("display_name"),
        avatar_url: row.get("avatar_url"),
        bio: row.get("bio"),
    }))
}

// ─── POST /api/users/me/avatar ───────────────────────────────────────────────

pub async fn upload_avatar(
    State(state): State<Arc<AppState>>,
    headers: axum::http::HeaderMap,
    mut multipart: axum::extract::Multipart,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let user_id = extract_user_id_from_header(&headers)?;

    while let Some(field) = multipart.next_field().await.map_err(|_| (StatusCode::BAD_REQUEST, "Bad upload".into()))? {
        let name = field.name().unwrap_or("").to_string();
        if name == "avatar" {
            let ext = field.file_name().unwrap_or("avatar.jpg").split('.').last().unwrap_or("jpg").to_string();
            let save_path = format!("uploads/avatar_{}_{}.{}", user_id, Uuid::new_v4(), ext);
            let public_url = format!("http://127.0.0.1:3000/{}", save_path);
            
            let data = field.bytes().await.map_err(|_| (StatusCode::BAD_REQUEST, "Failed to read bytes".into()))?;
            
            let mut file = tokio::fs::File::create(&save_path).await
                .map_err(|_| (StatusCode::INTERNAL_SERVER_ERROR, "Failed to write".into()))?;
            tokio::io::AsyncWriteExt::write_all(&mut file, &data).await
                .map_err(|_| (StatusCode::INTERNAL_SERVER_ERROR, "Failed to write".into()))?;
            
            sqlx::query("UPDATE users SET avatar_url = ? WHERE id = ?")
                .bind(&public_url)
                .bind(&user_id)
                .execute(&state.db)
                .await
                .map_err(|_| (StatusCode::INTERNAL_SERVER_ERROR, "Failed to update".into()))?;
            
            return Ok(Json(serde_json::json!({ "avatar_url": public_url })));
        }
    }
    Err((StatusCode::BAD_REQUEST, "No avatar field found".into()))
}

// ─── Helper: Extract user_id from Bearer token ──────────────────────────────

pub fn extract_user_id_from_header(headers: &axum::http::HeaderMap) -> Result<String, (StatusCode, String)> {
    let auth_header = headers.get("authorization")
        .and_then(|v| v.to_str().ok())
        .ok_or((StatusCode::UNAUTHORIZED, "Missing Authorization header".into()))?;
    
    let token = auth_header.strip_prefix("Bearer ")
        .ok_or((StatusCode::UNAUTHORIZED, "Invalid Authorization format".into()))?;
    
    let secret = env::var("JWT_SECRET").unwrap_or_else(|_| "fallback_key".into());
    let token_data = jsonwebtoken::decode::<Claims>(
        token,
        &jsonwebtoken::DecodingKey::from_secret(secret.as_bytes()),
        &jsonwebtoken::Validation::default(),
    ).map_err(|_| (StatusCode::UNAUTHORIZED, "Invalid token".into()))?;

    Ok(token_data.claims.sub)
}
