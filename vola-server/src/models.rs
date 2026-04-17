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
    pub reply_to_message_id: Option<String>,
    #[serde(default)]
    pub is_edited: bool,
    #[serde(default)]
    pub is_deleted: bool,
    #[serde(default)]
    pub reactions: std::collections::HashMap<String, Vec<String>>,
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
    WebRtcSignal {
        #[serde(skip_serializing_if = "Option::is_none")]
        sender_user_id: Option<String>,
        target_user_id: String,
        signal_payload: serde_json::Value,
    },
    
    // Server -> Client
    NewMessage(ChatMessage),
    PresenceUpdate { user_id: String, is_online: bool },
    UserTyping { user_id: String, chat_room_id: String, is_typing: bool },
    MessageRead { chat_room_id: String, user_id: String, message_id: String },
    Ack { message_id: String },
    Error { message: String },
    
    // Interactions
    EditMessage { message_id: String, new_content: String },
    DeleteMessage { message_id: String },
    AddReaction { message_id: String, emoji: String },
    RemoveReaction { message_id: String, emoji: String },
    
    MessageEdited { message_id: String, new_content: String },
    MessageDeleted { message_id: String },
    ReactionAdded { message_id: String, user_id: String, emoji: String },
    ReactionRemoved { message_id: String, user_id: String, emoji: String },
}
