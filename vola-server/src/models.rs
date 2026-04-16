use serde::{Deserialize, Serialize};
use std::fmt;

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct ChatRoom {
    pub id: String,
    pub name: String,
}

#[derive(Deserialize)]
pub struct CreateRoomReq {
    pub name: String,
}

#[derive(Deserialize)]
pub struct CreateDmReq {
    pub target_user_id: String,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub enum MessageType {
    Text,
    ImageBlurHash,
    System,
}

impl fmt::Display for MessageType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            MessageType::Text => write!(f, "Text"),
            MessageType::ImageBlurHash => write!(f, "ImageBlurHash"),
            MessageType::System => write!(f, "System"),
        }
    }
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct ChatMessage {
    pub id: String,
    pub sender_id: String,
    pub chat_room_id: String,
    pub content: String,
    pub msg_type: MessageType,
    pub timestamp: i64,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(tag = "type", content = "payload")]
pub enum WsEvent {
    // Client -> Server
    Authenticate { token: String },
    #[serde(alias = "PublishMessage")]
    SendMessage(ChatMessage),
    Typing { chat_room_id: String, is_typing: bool },
    MarkRead { chat_room_id: String, message_id: String },
    
    // Server -> Client
    NewMessage(ChatMessage),
    PresenceUpdate { user_id: String, is_online: bool },
    UserTyping { user_id: String, chat_room_id: String, is_typing: bool },
    MessageRead { chat_room_id: String, user_id: String, message_id: String },
    Ack { message_id: String },
    Error { message: String },
}
