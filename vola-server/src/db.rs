use sqlx::{sqlite::SqlitePoolOptions, Sqlite, Pool};
use std::env;
use tracing::info;

pub type DbPool = Pool<Sqlite>;

pub async fn init_db() -> DbPool {
    let database_url = env::var("DATABASE_URL").unwrap_or_else(|_| "sqlite://vola.db".to_string());
    
    let pool = SqlitePoolOptions::new()
        .max_connections(5)
        .connect(&database_url)
        .await
        .expect("Failed to connect to SQLite database");

    // Initialize tables (In a real app, use migrations like sqlx-cli)
    let schema = r#"
        CREATE TABLE IF NOT EXISTS users (
            id TEXT PRIMARY KEY,
            username TEXT UNIQUE NOT NULL,
            password_hash TEXT,
            display_name TEXT,
            avatar_url TEXT,
            bio TEXT,
            passkey_id TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );

        CREATE TABLE IF NOT EXISTS personas (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            name TEXT NOT NULL,
            icon TEXT,
            FOREIGN KEY(user_id) REFERENCES users(id)
        );

        CREATE TABLE IF NOT EXISTS messages (
            id TEXT PRIMARY KEY,
            sender_id TEXT NOT NULL,
            chat_room_id TEXT NOT NULL,
            content TEXT NOT NULL,
            msg_type TEXT NOT NULL,
            timestamp INTEGER NOT NULL,
            FOREIGN KEY(sender_id) REFERENCES users(id)
        );
        CREATE TABLE IF NOT EXISTS chat_rooms (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );

        CREATE TABLE IF NOT EXISTS user_rooms (
            user_id TEXT,
            room_id TEXT,
            last_read_message_id TEXT,
            PRIMARY KEY(user_id, room_id),
            FOREIGN KEY(user_id) REFERENCES users(id),
            FOREIGN KEY(room_id) REFERENCES chat_rooms(id)
        );

        -- Insert Dummy Rooms for Testing Context Switching
        INSERT OR IGNORE INTO chat_rooms (id, name) VALUES ('room_1', 'Product Team');
        INSERT OR IGNORE INTO chat_rooms (id, name) VALUES ('room_2', 'Engineering');
        INSERT OR IGNORE INTO chat_rooms (id, name) VALUES ('room_3', 'General Lounge');
    "#;

    sqlx::query(schema)
        .execute(&pool)
        .await
        .expect("Failed to initialize database schema");

    // Add column if missing (simple migration for existing dev instances)
    sqlx::query("ALTER TABLE user_rooms ADD COLUMN last_read_message_id TEXT")
        .execute(&pool)
        .await
        .ok();

    info!("Database initialized and tables verified");
    pool
}
