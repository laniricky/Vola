use dashmap::DashMap;
use tokio::sync::broadcast::{self, Sender, Receiver};
use crate::models::WsEvent;

/// Capacity of each room's broadcast channel (messages buffered if a client is slow)
const CHANNEL_CAPACITY: usize = 128;

/// The central Pub/Sub bus.
/// Keyed by `chat_room_id`. Equivalent to Redis channel: `room:{id}`.
/// 
/// When a message is published to a room, ALL connected WebSocket clients
/// subscribed to that room receive it instantly — regardless of which server 
/// instance handled their connection (swap DashMap → Redis for multi-server).
pub struct PubSub {
    rooms: DashMap<String, Sender<WsEvent>>,
}

impl PubSub {
    pub fn new() -> Self {
        Self {
            rooms: DashMap::new(),
        }
    }

    /// Subscribe to a chat room. Creates the channel if this is the first subscriber.
    pub fn subscribe(&self, room_id: &str) -> Receiver<WsEvent> {
        if let Some(tx) = self.rooms.get(room_id) {
            tx.subscribe()
        } else {
            let (tx, rx) = broadcast::channel(CHANNEL_CAPACITY);
            self.rooms.insert(room_id.to_string(), tx);
            rx
        }
    }

    /// Publish a message to a room. All subscribers receive it.
    /// Returns the number of clients that received the message.
    pub fn publish(&self, room_id: &str, message: WsEvent) -> usize {
        if let Some(tx) = self.rooms.get(room_id) {
            tx.send(message).unwrap_or(0)
        } else {
            0
        }
    }
}
