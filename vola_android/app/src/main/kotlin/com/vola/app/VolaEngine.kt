package com.vola.app

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.google.gson.Gson
import com.google.gson.JsonObject
import com.google.gson.reflect.TypeToken
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.File
import java.util.concurrent.TimeUnit

// ─── DataStore ────────────────────────────────────────────────────────────────
val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = "vola_prefs")

// ─── Data Models ─────────────────────────────────────────────────────────────
data class ChatRoom(val id: String, val name: String)

data class ChatMessage(
    val id: String,
    val senderId: String,
    val chatRoomId: String,
    var content: String,
    val msgType: String, // "Text", "ImageBlurHash", "System"
    val timestamp: Long,
    val replyToMessageId: String? = null,
    var isEdited: Boolean = false,
    var isDeleted: Boolean = false,
    var reactions: Map<String, List<String>> = emptyMap()
)

data class UserProfile(
    val id: String,
    val username: String,
    val displayName: String?,
    val avatarUrl: String?,
    val bio: String?,
    val lastSeen: Long?
)

data class RoomMember(
    val id: String,
    val username: String,
    val displayName: String?,
    val lastReadMessageId: String?
)

// ─── Engine ───────────────────────────────────────────────────────────────────
class VolaEngine(private val context: Context) {

    companion object {
        // ⚠️ Change SERVER_IP to your PC's local IP when connecting a real device over WiFi
        const val SERVER_IP = "10.100.8.139"
        const val BASE_URL = "http://$SERVER_IP:3000"
        const val WS_URL = "ws://$SERVER_IP:3000/ws"

        val TOKEN_KEY = stringPreferencesKey("vola_token")
        val USER_ID_KEY = stringPreferencesKey("vola_user_id")
        val USERNAME_KEY = stringPreferencesKey("vola_username")
    }

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val gson = Gson()
    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.SECONDS)
        .writeTimeout(15, TimeUnit.SECONDS)
        .build()

    var token: String? = null; private set
    var userId: String? = null; private set
    var username: String? = null; private set
    var activeRoomId: String = "room_1"; private set

    private var webSocket: WebSocket? = null
    private var reconnectJob: Job? = null
    private var reconnectDelay = 1000L
    private var intentionalClose = false
    private val sentIds = mutableSetOf<String>()

    // ─── State Flows ─────────────────────────────────────────────────────────
    private val _authenticated = MutableStateFlow<Boolean?>(null)
    val authenticated = _authenticated.asStateFlow()

    private val _messages = MutableStateFlow<List<ChatMessage>>(emptyList())
    val messages = _messages.asStateFlow()

    private val _rooms = MutableStateFlow<List<ChatRoom>>(emptyList())
    val rooms = _rooms.asStateFlow()

    private val _typingUsers = MutableStateFlow<List<String>>(emptyList())
    val typingUsers = _typingUsers.asStateFlow()

    private val _status = MutableStateFlow("Connecting...")
    val status = _status.asStateFlow()

    private val _onlineUsers = MutableStateFlow<Map<String, Boolean>>(emptyMap())
    val onlineUsers = _onlineUsers.asStateFlow()

    private val _readReceipts = MutableStateFlow<Map<String, String>>(emptyMap())
    val readReceipts = _readReceipts.asStateFlow()

    private val _roomLastMessages = MutableStateFlow<Map<String, ChatMessage>>(emptyMap())
    val roomLastMessages = _roomLastMessages.asStateFlow()

    private val _userProfiles = MutableStateFlow<Map<String, UserProfile>>(emptyMap())
    val userProfiles = _userProfiles.asStateFlow()

    var hasMoreMessages = false; private set
    var isLoadingMore = false; private set

    // ─── Init ─────────────────────────────────────────────────────────────────
    fun initialize() {
        scope.launch {
            val prefs = context.dataStore.data.first()
            token = prefs[TOKEN_KEY]
            userId = prefs[USER_ID_KEY]
            username = prefs[USERNAME_KEY]

            fetchRooms()
            fetchOnlineUsers()

            if (token != null) {
                _authenticated.value = true
                userId?.let { fetchProfile(it) }
                connectWebSocket()
            } else {
                _authenticated.value = false
            }
        }
    }

    // ─── Auth ─────────────────────────────────────────────────────────────────
    suspend fun authenticate(uname: String, pass: String, isLogin: Boolean) = withContext(Dispatchers.IO) {
        val endpoint = if (isLogin) "/api/login" else "/api/register"
        val body = """{"username":"$uname","password":"$pass"}"""
            .toRequestBody("application/json".toMediaType())

        val req = Request.Builder().url("$BASE_URL$endpoint").post(body).build()
        val res = client.newCall(req).execute()
        val json = gson.fromJson(res.body?.string(), JsonObject::class.java)

        if (!res.isSuccessful) throw Exception(json?.get("error")?.asString ?: "Auth failed (${res.code})")

        token = json.get("token").asString
        userId = json.get("id").asString
        username = json.get("username").asString

        context.dataStore.edit { prefs ->
            prefs[TOKEN_KEY] = token!!
            prefs[USER_ID_KEY] = userId!!
            prefs[USERNAME_KEY] = username!!
        }

        _authenticated.value = true
        fetchRooms()
        userId?.let { fetchProfile(it) }
        connectWebSocket()
    }

    suspend fun logout() {
        intentionalClose = true
        webSocket?.close(1000, "logout")
        webSocket = null
        token = null; userId = null; username = null
        context.dataStore.edit { it.clear() }
        _messages.value = emptyList()
        _rooms.value = emptyList()
        _authenticated.value = false
    }

    // ─── WebSocket ────────────────────────────────────────────────────────────
    private fun connectWebSocket() {
        if (token == null) return
        intentionalClose = false

        val req = Request.Builder()
            .url(WS_URL)
            .header("Authorization", "Bearer $token")
            .build()

        webSocket = client.newWebSocket(req, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                reconnectDelay = 1000L
                _status.value = "Connected"
                scope.launch { fetchMessages(activeRoomId) }
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                handleMessage(text)
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                _status.value = "Reconnecting..."
                if (!intentionalClose) scheduleReconnect()
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                if (!intentionalClose) {
                    _status.value = "Reconnecting..."
                    scheduleReconnect()
                }
            }
        })
    }

    private fun scheduleReconnect() {
        reconnectJob?.cancel()
        reconnectJob = scope.launch {
            delay(reconnectDelay.coerceAtMost(30_000))
            reconnectDelay = (reconnectDelay * 2).coerceAtMost(30_000)
            connectWebSocket()
        }
    }

    private fun handleMessage(raw: String) {
        try {
            val obj = gson.fromJson(raw, JsonObject::class.java)
            val type = obj.get("type")?.asString ?: return
            val payload = obj.getAsJsonObject("payload") ?: return

            when (type) {
                "NewMessage" -> {
                    val msg = parseMessage(payload) ?: return
                    if (sentIds.contains(msg.id)) { sentIds.remove(msg.id); return }
                    if (msg.chatRoomId == activeRoomId) {
                        _messages.value = _messages.value + msg
                    }
                    updateLastMessage(msg)
                }
                "EditedMessage" -> {
                    val id = payload.get("id")?.asString ?: return
                    val content = payload.get("content")?.asString ?: return
                    _messages.value = _messages.value.map {
                        if (it.id == id) it.copy(content = content, isEdited = true) else it
                    }
                }
                "DeletedMessage" -> {
                    val id = payload.get("message_id")?.asString ?: return
                    _messages.value = _messages.value.map {
                        if (it.id == id) it.copy(isDeleted = true, content = "This message was deleted") else it
                    }
                }
                "UserTyping" -> {
                    val uid = payload.get("user_id")?.asString ?: return
                    val isTyping = payload.get("is_typing")?.asBoolean ?: return
                    val roomId = payload.get("chat_room_id")?.asString ?: return
                    if (roomId == activeRoomId && uid != userId) {
                        _typingUsers.value = if (isTyping)
                            (_typingUsers.value + uid).distinct()
                        else
                            _typingUsers.value.filter { it != uid }
                    }
                }
                "PresenceUpdate" -> {
                    val uid = payload.get("user_id")?.asString ?: return
                    val online = payload.get("is_online")?.asBoolean ?: return
                    _onlineUsers.value = _onlineUsers.value + (uid to online)
                }
                "ReadReceipt" -> {
                    val uid = payload.get("user_id")?.asString ?: return
                    val msgId = payload.get("message_id")?.asString ?: return
                    _readReceipts.value = _readReceipts.value + (uid to msgId)
                }
                "ReactionUpdate" -> {
                    val msgId = payload.get("message_id")?.asString ?: return
                    val reactionsEl = payload.getAsJsonObject("reactions") ?: return
                    val reactionMap = mutableMapOf<String, List<String>>()
                    reactionsEl.keySet().forEach { emoji ->
                        val users = gson.fromJson<List<String>>(
                            reactionsEl.getAsJsonArray(emoji),
                            object : TypeToken<List<String>>() {}.type
                        )
                        reactionMap[emoji] = users
                    }
                    _messages.value = _messages.value.map {
                        if (it.id == msgId) it.copy(reactions = reactionMap) else it
                    }
                }
                "NewRoom" -> {
                    scope.launch { fetchRooms() }
                }
                "Error" -> {
                    // Handle silently
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    // ─── Rooms ────────────────────────────────────────────────────────────────
    private suspend fun fetchRooms() = withContext(Dispatchers.IO) {
        try {
            val req = Request.Builder().url("$BASE_URL/api/rooms").build()
            val res = client.newCall(req).execute()
            if (res.isSuccessful) {
                val type = object : TypeToken<List<Map<String, String>>>() {}.type
                val list: List<Map<String, String>> = gson.fromJson(res.body?.string(), type)
                _rooms.value = list.map { ChatRoom(it["id"]!!, it["name"]!!) }
            }
        } catch (e: Exception) { e.printStackTrace() }
    }

    fun setActiveRoom(roomId: String) {
        activeRoomId = roomId
        _messages.value = emptyList()
        _typingUsers.value = emptyList()
        hasMoreMessages = false
        scope.launch { fetchMessages(roomId) }
    }

    suspend fun createRoom(name: String) = withContext(Dispatchers.IO) {
        val body = """{"name":"$name"}""".toRequestBody("application/json".toMediaType())
        val req = Request.Builder()
            .url("$BASE_URL/api/rooms")
            .header("Authorization", "Bearer $token")
            .post(body).build()
        client.newCall(req).execute()
        fetchRooms()
    }

    suspend fun createDM(targetUserId: String): String? = withContext(Dispatchers.IO) {
        val body = """{"target_user_id":"$targetUserId"}"""
            .toRequestBody("application/json".toMediaType())
        val req = Request.Builder()
            .url("$BASE_URL/api/rooms/dm")
            .header("Authorization", "Bearer $token")
            .post(body).build()
        val res = client.newCall(req).execute()
        if (res.isSuccessful) {
            val json = gson.fromJson(res.body?.string(), JsonObject::class.java)
            val roomId = json.get("id")?.asString
            fetchRooms()
            roomId
        } else null
    }

    // ─── Messages ─────────────────────────────────────────────────────────────
    private suspend fun fetchMessages(roomId: String) = withContext(Dispatchers.IO) {
        try {
            val req = Request.Builder()
                .url("$BASE_URL/api/rooms/$roomId/messages")
                .header("Authorization", "Bearer $token")
                .build()
            val res = client.newCall(req).execute()
            if (res.isSuccessful) {
                val type = object : TypeToken<List<JsonObject>>() {}.type
                val list: List<JsonObject> = gson.fromJson(res.body?.string(), type)
                val msgs = list.mapNotNull { parseMessage(it) }
                _messages.value = msgs
                hasMoreMessages = msgs.size >= 50
                msgs.lastOrNull()?.let { updateLastMessage(it) }
            }
        } catch (e: Exception) { e.printStackTrace() }
    }

    suspend fun loadMoreMessages() = withContext(Dispatchers.IO) {
        if (isLoadingMore || !hasMoreMessages) return@withContext
        isLoadingMore = true
        val oldest = _messages.value.firstOrNull()?.id ?: run { isLoadingMore = false; return@withContext }
        try {
            val req = Request.Builder()
                .url("$BASE_URL/api/rooms/$activeRoomId/messages?before=$oldest")
                .header("Authorization", "Bearer $token")
                .build()
            val res = client.newCall(req).execute()
            if (res.isSuccessful) {
                val type = object : TypeToken<List<JsonObject>>() {}.type
                val list: List<JsonObject> = gson.fromJson(res.body?.string(), type)
                val msgs = list.mapNotNull { parseMessage(it) }
                _messages.value = msgs + _messages.value
                hasMoreMessages = msgs.size >= 50
            }
        } catch (e: Exception) { e.printStackTrace() }
        isLoadingMore = false
    }

    fun sendMessage(content: String, type: String = "Text", replyToId: String? = null) {
        if (content.isBlank()) return
        val payload = JsonObject().apply {
            addProperty("chat_room_id", activeRoomId)
            addProperty("content", content)
            addProperty("msg_type", type)
            if (replyToId != null) addProperty("reply_to_message_id", replyToId)
        }
        val envelope = JsonObject().apply {
            addProperty("type", "SendMessage")
            add("payload", payload)
        }
        webSocket?.send(gson.toJson(envelope))
    }

    fun editMessage(id: String, newContent: String) {
        val payload = JsonObject().apply {
            addProperty("message_id", id)
            addProperty("new_content", newContent)
        }
        val envelope = JsonObject().apply {
            addProperty("type", "EditMessage")
            add("payload", payload)
        }
        webSocket?.send(gson.toJson(envelope))
    }

    fun deleteMessage(id: String) {
        val payload = JsonObject().apply { addProperty("message_id", id) }
        val envelope = JsonObject().apply {
            addProperty("type", "DeleteMessage")
            add("payload", payload)
        }
        webSocket?.send(gson.toJson(envelope))
    }

    fun addReaction(messageId: String, emoji: String) {
        val payload = JsonObject().apply {
            addProperty("message_id", messageId)
            addProperty("emoji", emoji)
        }
        webSocket?.send(gson.toJson(JsonObject().apply {
            addProperty("type", "AddReaction"); add("payload", payload)
        }))
    }

    fun markRead(messageId: String) {
        val payload = JsonObject().apply {
            addProperty("chat_room_id", activeRoomId)
            addProperty("message_id", messageId)
        }
        webSocket?.send(gson.toJson(JsonObject().apply {
            addProperty("type", "MarkRead"); add("payload", payload)
        }))
        userId?.let { uid ->
            _readReceipts.value = _readReceipts.value + (uid to messageId)
        }
    }

    fun emitTyping(isTyping: Boolean) {
        val payload = JsonObject().apply {
            addProperty("chat_room_id", activeRoomId)
            addProperty("is_typing", isTyping)
        }
        webSocket?.send(gson.toJson(JsonObject().apply {
            addProperty("type", "Typing"); add("payload", payload)
        }))
    }

    // ─── Members ──────────────────────────────────────────────────────────────
    suspend fun fetchRoomMembers(roomId: String): List<RoomMember> = withContext(Dispatchers.IO) {
        try {
            val req = Request.Builder()
                .url("$BASE_URL/api/rooms/$roomId/members")
                .header("Authorization", "Bearer $token")
                .build()
            val res = client.newCall(req).execute()
            if (res.isSuccessful) {
                val type = object : TypeToken<List<JsonObject>>() {}.type
                val list: List<JsonObject> = gson.fromJson(res.body?.string(), type)
                list.map { m ->
                    RoomMember(
                        id = m.get("id").asString,
                        username = m.get("username").asString,
                        displayName = m.get("display_name")?.takeIf { !it.isJsonNull }?.asString,
                        lastReadMessageId = m.get("last_read_message_id")?.takeIf { !it.isJsonNull }?.asString
                    )
                }
            } else emptyList()
        } catch (e: Exception) { emptyList() }
    }

    // ─── Presence ─────────────────────────────────────────────────────────────
    private suspend fun fetchOnlineUsers() = withContext(Dispatchers.IO) {
        try {
            val req = Request.Builder().url("$BASE_URL/api/users/online").build()
            val res = client.newCall(req).execute()
            if (res.isSuccessful) {
                val type = object : TypeToken<List<String>>() {}.type
                val ids: List<String> = gson.fromJson(res.body?.string(), type)
                _onlineUsers.value = ids.associateWith { true }
            }
        } catch (e: Exception) { e.printStackTrace() }
    }

    // ─── Profiles ─────────────────────────────────────────────────────────────
    suspend fun fetchProfile(targetId: String) = withContext(Dispatchers.IO) {
        try {
            val req = Request.Builder().url("$BASE_URL/api/users/$targetId").build()
            val res = client.newCall(req).execute()
            if (res.isSuccessful) {
                val json = gson.fromJson(res.body?.string(), JsonObject::class.java)
                val profile = UserProfile(
                    id = json.get("id").asString,
                    username = json.get("username").asString,
                    displayName = json.get("display_name")?.takeIf { !it.isJsonNull }?.asString,
                    avatarUrl = json.get("avatar_url")?.takeIf { !it.isJsonNull }?.asString,
                    bio = json.get("bio")?.takeIf { !it.isJsonNull }?.asString,
                    lastSeen = json.get("last_seen")?.takeIf { !it.isJsonNull }?.asLong
                )
                _userProfiles.value = _userProfiles.value + (targetId to profile)
            }
        } catch (e: Exception) { e.printStackTrace() }
    }

    suspend fun updateProfile(displayName: String?, bio: String?) = withContext(Dispatchers.IO) {
        if (token == null) return@withContext
        val bodyMap = mutableMapOf<String, String>()
        displayName?.let { bodyMap["display_name"] = it }
        bio?.let { bodyMap["bio"] = it }
        val body = gson.toJson(bodyMap).toRequestBody("application/json".toMediaType())
        val req = Request.Builder()
            .url("$BASE_URL/api/users/me")
            .header("Authorization", "Bearer $token")
            .patch(body).build()
        val res = client.newCall(req).execute()
        if (res.isSuccessful && userId != null) {
            val json = gson.fromJson(res.body?.string(), JsonObject::class.java)
            val profile = UserProfile(
                id = json.get("id").asString,
                username = json.get("username").asString,
                displayName = json.get("display_name")?.takeIf { !it.isJsonNull }?.asString,
                avatarUrl = json.get("avatar_url")?.takeIf { !it.isJsonNull }?.asString,
                bio = json.get("bio")?.takeIf { !it.isJsonNull }?.asString,
                lastSeen = json.get("last_seen")?.takeIf { !it.isJsonNull }?.asLong
            )
            _userProfiles.value = _userProfiles.value + (userId!! to profile)
        }
    }

    suspend fun uploadAvatar(file: File) = withContext(Dispatchers.IO) {
        if (token == null || userId == null) return@withContext
        try {
            val requestBody = MultipartBody.Builder().setType(MultipartBody.FORM)
                .addFormDataPart("avatar", file.name, file.asRequestBody("image/*".toMediaType()))
                .build()
            val req = Request.Builder()
                .url("$BASE_URL/api/users/me/avatar")
                .header("Authorization", "Bearer $token")
                .post(requestBody).build()
            val res = client.newCall(req).execute()
            if (res.isSuccessful) {
                val json = gson.fromJson(res.body?.string(), JsonObject::class.java)
                val url = json.get("avatar_url")?.asString ?: return@withContext
                val existing = _userProfiles.value[userId!!]
                _userProfiles.value = _userProfiles.value + (userId!! to UserProfile(
                    id = userId!!,
                    username = existing?.username ?: "",
                    displayName = existing?.displayName,
                    avatarUrl = url,
                    bio = existing?.bio,
                    lastSeen = existing?.lastSeen
                ))
            }
        } catch (e: Exception) { e.printStackTrace() }
    }

    // ─── Image Upload ─────────────────────────────────────────────────────────
    suspend fun uploadImage(file: File): String? = withContext(Dispatchers.IO) {
        try {
            val requestBody = MultipartBody.Builder().setType(MultipartBody.FORM)
                .addFormDataPart("file", file.name, file.asRequestBody("image/*".toMediaType()))
                .build()
            val req = Request.Builder()
                .url("$BASE_URL/api/upload")
                .post(requestBody).build()
            val res = client.newCall(req).execute()
            if (res.isSuccessful) {
                val json = gson.fromJson(res.body?.string(), JsonObject::class.java)
                val hash = json.get("hash")?.asString
                val hdUrl = json.get("hd_url")?.asString
                if (hash != null && hdUrl != null) {
                    gson.toJson(mapOf("hash" to hash, "hd_url" to hdUrl))
                } else null
            } else null
        } catch (e: Exception) { null }
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────
    private fun parseMessage(obj: JsonObject): ChatMessage? {
        return try {
            val reactionsEl = obj.getAsJsonObject("reactions")
            val reactionMap = mutableMapOf<String, List<String>>()
            reactionsEl?.keySet()?.forEach { emoji ->
                val users = gson.fromJson<List<String>>(
                    reactionsEl.getAsJsonArray(emoji),
                    object : TypeToken<List<String>>() {}.type
                )
                reactionMap[emoji] = users
            }
            ChatMessage(
                id = obj.get("id").asString,
                senderId = obj.get("sender_id")?.asString ?: obj.get("senderId").asString,
                chatRoomId = obj.get("chat_room_id")?.asString ?: obj.get("chatRoomId").asString,
                content = obj.get("content").asString,
                msgType = obj.get("msg_type").asString,
                timestamp = obj.get("timestamp").asLong,
                replyToMessageId = obj.get("reply_to_message_id")?.takeIf { !it.isJsonNull }?.asString,
                isEdited = obj.get("is_edited")?.asBoolean ?: false,
                isDeleted = obj.get("is_deleted")?.asBoolean ?: false,
                reactions = reactionMap
            )
        } catch (e: Exception) { null }
    }

    private fun updateLastMessage(msg: ChatMessage) {
        _roomLastMessages.value = _roomLastMessages.value + (msg.chatRoomId to msg)
    }

    fun dispose() {
        intentionalClose = true
        reconnectJob?.cancel()
        webSocket?.close(1000, "dispose")
        scope.cancel()
    }
}
