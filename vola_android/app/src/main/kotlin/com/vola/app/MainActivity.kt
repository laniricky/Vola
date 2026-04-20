package com.vola.app

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.MediaStore
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.*
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.shape.*
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.*
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.*
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.*
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.*
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.*
import androidx.compose.ui.window.Dialog
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil.compose.AsyncImage
import kotlinx.coroutines.*
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.*

// ─── Color Palette ────────────────────────────────────────────────────────────
val BgDark   = Color(0xFF0F0F12)
val BgCard   = Color(0xFF16161A)
val BgInput  = Color(0xFF1E293B)
val Accent   = Color(0xFFFF512F)
val AccentEnd = Color(0xFFDD2476)
val TextPrim = Color(0xFFE2E8F0)
val TextSec  = Color(0xFF94A3B8)
val Online   = Color(0xFF22C55E)
val DmColor  = Color(0xFF4F46E5)
val GroupColor = Color(0xFF334155)

// ─── Theme ────────────────────────────────────────────────────────────────────
private val DarkColors = darkColorScheme(
    primary = Accent,
    secondary = AccentEnd,
    background = BgDark,
    surface = BgCard,
    onBackground = TextPrim,
    onSurface = TextPrim
)

// ─── Activity ─────────────────────────────────────────────────────────────────
class MainActivity : ComponentActivity() {
    private lateinit var engine: VolaEngine

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        engine = VolaEngine(applicationContext)
        engine.initialize()

        setContent {
            MaterialTheme(colorScheme = DarkColors) {
                Surface(color = BgDark) {
                    VolaApp(engine = engine, context = applicationContext)
                }
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        engine.dispose()
    }
}

// ─── Root App ─────────────────────────────────────────────────────────────────
@Composable
fun VolaApp(engine: VolaEngine, context: Context) {
    val auth by engine.authenticated.collectAsStateWithLifecycle()

    when (auth) {
        null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(color = Accent)
        }
        false -> AuthScreen(engine)
        true  -> ChatScreen(engine, context)
    }
}

// ─── Auth Screen ──────────────────────────────────────────────────────────────
@Composable
fun AuthScreen(engine: VolaEngine) {
    var isLogin by remember { mutableStateOf(true) }
    var username by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()

    Box(Modifier.fillMaxSize().background(BgDark), contentAlignment = Alignment.Center) {
        Column(
            Modifier.padding(24.dp).widthIn(max = 400.dp),
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            // Logo
            Box(
                Modifier.size(72.dp).clip(CircleShape)
                    .background(Brush.linearGradient(listOf(Accent, AccentEnd))),
                contentAlignment = Alignment.Center
            ) {
                Text("V", color = Color.White, fontSize = 36.sp, fontWeight = FontWeight.Black)
            }
            Text("Vola", color = TextPrim, fontSize = 28.sp, fontWeight = FontWeight.Black)
            Text(
                if (isLogin) "Welcome back" else "Create an account",
                color = TextSec, fontSize = 14.sp
            )
            Spacer(Modifier.height(8.dp))

            if (error.isNotEmpty()) {
                Card(colors = CardDefaults.cardColors(containerColor = Color(0xFF3D1515)), shape = RoundedCornerShape(8.dp)) {
                    Text(error, color = Color(0xFFFF6B6B), modifier = Modifier.padding(12.dp), fontSize = 13.sp)
                }
            }

            OutlinedTextField(
                value = username, onValueChange = { username = it },
                label = { Text("Username") }, singleLine = true, modifier = Modifier.fillMaxWidth(),
                colors = outlinedTextFieldColors(), keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next)
            )
            OutlinedTextField(
                value = password, onValueChange = { password = it },
                label = { Text("Password") }, singleLine = true, modifier = Modifier.fillMaxWidth(),
                visualTransformation = PasswordVisualTransformation(),
                colors = outlinedTextFieldColors(),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { doAuth(scope, engine, username, password, isLogin, { loading = it }, { error = it }) })
            )
            Button(
                onClick = { doAuth(scope, engine, username, password, isLogin, { loading = it }, { error = it }) },
                enabled = !loading && username.isNotBlank() && password.isNotBlank(),
                modifier = Modifier.fillMaxWidth().height(50.dp),
                shape = RoundedCornerShape(12.dp),
                colors = ButtonDefaults.buttonColors(containerColor = Accent)
            ) {
                if (loading) CircularProgressIndicator(Modifier.size(20.dp), color = Color.White, strokeWidth = 2.dp)
                else Text(if (isLogin) "Sign In" else "Register", fontWeight = FontWeight.Bold)
            }
            TextButton(onClick = { isLogin = !isLogin; error = "" }) {
                Text(
                    if (isLogin) "Don't have an account? Register" else "Already have an account? Sign In",
                    color = Accent
                )
            }
        }
    }
}

private fun doAuth(
    scope: CoroutineScope, engine: VolaEngine, username: String, password: String,
    isLogin: Boolean, setLoading: (Boolean) -> Unit, setError: (String) -> Unit
) {
    scope.launch {
        setLoading(true); setError("")
        try { engine.authenticate(username, password, isLogin) }
        catch (e: Exception) {
            val errMsg = "[${e.javaClass.simpleName}] ${e.message ?: "Unknown error"}"
            android.util.Log.e("VolaAuth", "Auth failed", e)
            setError(errMsg)
        }
        finally { setLoading(false) }
    }
}

@Composable
fun outlinedTextFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedBorderColor = Accent, unfocusedBorderColor = GroupColor,
    focusedLabelColor = Accent, unfocusedLabelColor = TextSec,
    cursorColor = Accent, focusedTextColor = TextPrim, unfocusedTextColor = TextPrim
)

// ─── Chat Screen ──────────────────────────────────────────────────────────────
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatScreen(engine: VolaEngine, context: Context) {
    val scope = rememberCoroutineScope()
    val rooms by engine.rooms.collectAsStateWithLifecycle()
    val messages by engine.messages.collectAsStateWithLifecycle()
    val typingUsers by engine.typingUsers.collectAsStateWithLifecycle()
    val status by engine.status.collectAsStateWithLifecycle()
    val onlineUsers by engine.onlineUsers.collectAsStateWithLifecycle()
    val readReceipts by engine.readReceipts.collectAsStateWithLifecycle()
    val roomLastMessages by engine.roomLastMessages.collectAsStateWithLifecycle()
    val userProfiles by engine.userProfiles.collectAsStateWithLifecycle()

    var inputText by remember { mutableStateOf("") }
    var editingMsg by remember { mutableStateOf<ChatMessage?>(null) }
    var replyingTo by remember { mutableStateOf<ChatMessage?>(null) }
    var showMembers by remember { mutableStateOf(false) }
    var members by remember { mutableStateOf<List<RoomMember>>(emptyList()) }
    var showCreateRoom by remember { mutableStateOf(false) }
    var showNewDM by remember { mutableStateOf(false) }
    var showProfile by remember { mutableStateOf(false) }
    var typingTimerJob by remember { mutableStateOf<Job?>(null) }

    val listState = rememberLazyListState()
    val drawerState = rememberDrawerState(DrawerValue.Closed)
    val activeRoom = rooms.find { it.id == engine.activeRoomId }
    val isDM = engine.activeRoomId.startsWith("dm_")

    // Image picker
    val imagePickerLauncher = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        uri?.let {
            scope.launch {
                val file = uriToFile(context, it) ?: return@launch
                val payload = engine.uploadImage(file)
                if (payload != null) engine.sendMessage(payload, "ImageBlurHash")
            }
        }
    }

    // Auto scroll to bottom
    LaunchedEffect(messages.size) {
        if (messages.isNotEmpty()) listState.animateScrollToItem(messages.size - 1 + 1)
    }

    // Load members when needed
    LaunchedEffect(showMembers, engine.activeRoomId) {
        if (showMembers) {
            members = engine.fetchRoomMembers(engine.activeRoomId)
            members.forEach { m -> if (!userProfiles.containsKey(m.id)) engine.fetchProfile(m.id) }
        }
    }

    ModalNavigationDrawer(
        drawerState = drawerState,
        drawerContent = {
        RoomsDrawer(
                engine = engine, rooms = rooms, roomLastMessages = roomLastMessages,
                userProfiles = userProfiles, scope = scope,
                onRoomClick = { id ->
                    engine.setActiveRoom(id)
                    scope.launch { drawerState.close() }
                },
                onCreateRoom = { scope.launch { drawerState.close() }; showCreateRoom = true },
                onNewDM = { scope.launch { drawerState.close() }; showNewDM = true },
                onEditProfile = { showProfile = true; scope.launch { drawerState.close() } }
            )
        }
    ) {
        Scaffold(
            containerColor = BgDark,
            topBar = {
                Column {
                    // Reconnecting banner
                    AnimatedVisibility(status == "Reconnecting...") {
                        Box(Modifier.fillMaxWidth().background(Color(0xFFD4A017)).padding(8.dp), Alignment.Center) {
                            Text("Reconnecting to server...", color = Color.Black, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                        }
                    }
                    TopAppBar(
                        colors = TopAppBarDefaults.topAppBarColors(containerColor = BgCard),
                        navigationIcon = {
                            IconButton(onClick = { scope.launch { drawerState.open() } }) {
                                Icon(Icons.Default.Menu, contentDescription = "Menu", tint = TextSec)
                            }
                        },
                        title = {
                            Column {
                                Text(activeRoom?.name ?: "Loading...", color = TextPrim, fontSize = 16.sp, fontWeight = FontWeight.Bold)
                                val subtitle = when {
                                    typingUsers.isNotEmpty() -> if (typingUsers.size > 1) "Several people are typing..." else "Someone is typing..."
                                    status == "Connected" -> if (isDM) {
                                        val peerId = members.find { it.id != engine.userId }?.id
                                        if (peerId != null && onlineUsers[peerId] == true) "🟢 Online"
                                        else {
                                            val ls = peerId?.let { userProfiles[it]?.lastSeen }
                                            if (ls != null) "🔴 Last seen ${formatLastSeen(ls)}" else "🔴 Offline"
                                        }
                                    } else "🟢 Online"
                                    status == "Reconnecting..." -> "🟡 Reconnecting..."
                                    else -> "🔴 Disconnected"
                                }
                                Text(subtitle, color = if (typingUsers.isNotEmpty()) Accent else TextSec, fontSize = 12.sp,
                                    fontStyle = if (typingUsers.isNotEmpty()) FontStyle.Italic else FontStyle.Normal)
                            }
                        },
                        actions = {
                            IconButton(onClick = { showMembers = !showMembers }) {
                                Icon(Icons.Default.People, contentDescription = "Members",
                                    tint = if (showMembers) Accent else TextSec)
                            }
                            IconButton(onClick = { scope.launch { engine.logout() } }) {
                                Icon(Icons.Default.Logout, contentDescription = "Logout", tint = TextSec)
                            }
                        }
                    )
                }
            },
            bottomBar = {
                Column {
                    AnimatedVisibility(typingUsers.isNotEmpty()) {
                        val externalTyping = typingUsers.filter { it != engine.userId }
                        if (externalTyping.isNotEmpty()) {
                            val msgStr = if (isDM) {
                                "Typing..."
                            } else {
                                val names = externalTyping.map { uid -> userProfiles[uid]?.displayName ?: uid.take(8) }
                                if (names.size == 1) "${names.first()} is typing..." else "Several people are typing..."
                            }
                            Row(Modifier.fillMaxWidth().background(BgDark).padding(horizontal = 16.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                                Text(msgStr, color = Accent, fontSize = 12.sp, fontStyle = FontStyle.Italic)
                            }
                        }
                    }
                    InputArea(
                        inputText = inputText, editingMsg = editingMsg, replyingTo = replyingTo,
                        onTextChange = { inputText = it
                            typingTimerJob?.cancel()
                            engine.emitTyping(true)
                            typingTimerJob = scope.launch { delay(1500); engine.emitTyping(false) }
                        },
                        onSend = {
                            if (inputText.isNotBlank()) {
                                if (editingMsg != null) {
                                    engine.editMessage(editingMsg!!.id, inputText)
                                    editingMsg = null
                                } else {
                                    engine.sendMessage(inputText, "Text", replyingTo?.id)
                                    replyingTo = null
                                }
                                inputText = ""
                                engine.emitTyping(false)
                            }
                        },
                        onAttach = { imagePickerLauncher.launch("image/*") },
                        onCancelEdit = { editingMsg = null; inputText = ""; replyingTo = null }
                    )
                }
            }
        ) { padding ->
            Row(Modifier.padding(padding)) {
                // Message list
                LazyColumn(state = listState, modifier = Modifier.weight(1f).fillMaxHeight().padding(horizontal = 12.dp),
                    contentPadding = PaddingValues(vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    // Load more trigger
                    item {
                        if (engine.hasMoreMessages) {
                            Box(Modifier.fillMaxWidth(), Alignment.Center) {
                                TextButton(onClick = { scope.launch { engine.loadMoreMessages() } }) {
                                    Text("Load older messages", color = Accent, fontSize = 12.sp)
                                }
                            }
                        }
                    }
                    itemsIndexed(messages, key = { _, m -> m.id }) { idx, msg ->
                        val isMe = msg.senderId == engine.userId
                        // Mark read
                        if (idx == messages.size - 1 && !isMe) {
                            LaunchedEffect(msg.id) { engine.markRead(msg.id) }
                        }
                        MessageBubble(
                            msg = msg, isMe = isMe, messages = messages, idx = idx,
                            myUserId = engine.userId ?: "", readReceipts = readReceipts,
                            userProfiles = userProfiles,
                            onLongClick = { }, // TODO: context menu
                            onReply = { replyingTo = msg },
                            onReact = { emoji -> engine.addReaction(msg.id, emoji) },
                            onEdit = { editingMsg = msg; inputText = msg.content },
                            onDelete = { engine.deleteMessage(msg.id) }
                        )
                    }
                }

                // Members sidebar
                AnimatedVisibility(showMembers, enter = slideInHorizontally { it }, exit = slideOutHorizontally { it }) {
                    MembersPanel(
                        members = members, engine = engine, onlineUsers = onlineUsers,
                        userProfiles = userProfiles, scope = scope
                    )
                }
            }
        }
    }

    // Dialogs
    if (showCreateRoom) {
        CreateRoomDialog(onDismiss = { showCreateRoom = false }, onCreate = { name ->
            scope.launch { engine.createRoom(name); showCreateRoom = false }
        })
    }
    if (showNewDM) {
        NewDMDialog(
            engine = engine,
            scope = scope,
            onDismiss = { showNewDM = false },
            onDMCreated = { roomId ->
                showNewDM = false
                engine.setActiveRoom(roomId)
            }
        )
    }
    if (showProfile) {
        ProfileEditDialog(engine = engine, userProfiles = userProfiles, scope = scope, context = context, onDismiss = { showProfile = false })
    }
}

// ─── Rooms Drawer ─────────────────────────────────────────────────────────────
@Composable
fun RoomsDrawer(
    engine: VolaEngine, rooms: List<ChatRoom>, roomLastMessages: Map<String, ChatMessage>,
    userProfiles: Map<String, UserProfile>, scope: CoroutineScope,
    onRoomClick: (String) -> Unit, onCreateRoom: () -> Unit,
    onNewDM: () -> Unit, onEditProfile: () -> Unit
) {
    val myProfile = userProfiles[engine.userId]
    val displayName = myProfile?.displayName ?: engine.username ?: "You"
    val avatarUrl = myProfile?.avatarUrl

    val dmRooms = rooms.filter { it.id.startsWith("dm_") }
    val groupRooms = rooms.filter { !it.id.startsWith("dm_") }

    ModalDrawerSheet(drawerContainerColor = BgCard) {
        // Profile Header
        Box(
            Modifier.fillMaxWidth().clickable(onClick = onEditProfile)
                .background(Brush.linearGradient(listOf(Color(0xFF1A0A0A), BgDark)))
                .padding(20.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(Modifier.size(56.dp).clip(CircleShape).background(GroupColor)) {
                    if (avatarUrl != null) {
                        AsyncImage(model = avatarUrl, contentDescription = null, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                    } else {
                        Box(Modifier.fillMaxSize().background(Brush.linearGradient(listOf(Accent, AccentEnd))), Alignment.Center) {
                            Text(displayName.first().uppercaseChar().toString(), color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold)
                        }
                    }
                }
                Column(Modifier.weight(1f)) {
                    Text(displayName, color = TextPrim, fontSize = 16.sp, fontWeight = FontWeight.Bold)
                    if (myProfile?.bio?.isNotEmpty() == true)
                        Text(myProfile.bio, color = TextSec, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text("Tap to edit profile", color = Accent.copy(alpha = 0.7f), fontSize = 11.sp)
                }
                Icon(Icons.Default.Edit, contentDescription = null, tint = TextSec, modifier = Modifier.size(16.dp))
            }
        }

        Divider(color = Color(0xFF1E293B))

        // DMs section
        Row(
            Modifier.fillMaxWidth().padding(16.dp, 12.dp, 8.dp, 4.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text("DIRECT MESSAGES", color = TextSec, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
            IconButton(onClick = onNewDM, modifier = Modifier.size(28.dp)) {
                Icon(Icons.Default.Add, contentDescription = "New DM", tint = Accent, modifier = Modifier.size(16.dp))
            }
        }
        if (dmRooms.isEmpty()) {
            Text("No direct messages yet", color = TextSec.copy(alpha = 0.5f), fontSize = 12.sp,
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 4.dp))
        }
        dmRooms.forEach { room ->
            val lastMsg = roomLastMessages[room.id]
            val preview = lastMsg?.let { if (it.msgType == "ImageBlurHash") "📷 Image" else it.content } ?: "Tap to chat..."
            NavigationDrawerItem(
                selected = engine.activeRoomId == room.id,
                onClick = { onRoomClick(room.id) },
                modifier = Modifier.padding(horizontal = 8.dp, vertical = 1.dp),
                colors = NavigationDrawerItemDefaults.colors(
                    selectedContainerColor = DmColor.copy(alpha = 0.2f),
                    unselectedContainerColor = Color.Transparent
                ),
                icon = {
                    Box(Modifier.size(40.dp).clip(CircleShape).background(DmColor), Alignment.Center) {
                        Icon(Icons.Default.Person, contentDescription = null, tint = Color.White, modifier = Modifier.size(20.dp))
                    }
                },
                label = {
                    Column {
                        Text(room.name, color = TextPrim, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(preview, color = TextSec, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            )
        }

        Divider(color = Color(0xFF1E293B), modifier = Modifier.padding(vertical = 4.dp))

        // Groups section
        Row(
            Modifier.fillMaxWidth().padding(16.dp, 8.dp, 8.dp, 4.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text("GROUP ROOMS", color = TextSec, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
            IconButton(onClick = onCreateRoom, modifier = Modifier.size(28.dp)) {
                Icon(Icons.Default.Add, contentDescription = "New Room", tint = Accent, modifier = Modifier.size(16.dp))
            }
        }
        groupRooms.forEach { room ->
            val lastMsg = roomLastMessages[room.id]
            val preview = lastMsg?.let { if (it.msgType == "ImageBlurHash") "📷 Image" else it.content } ?: "Tap to view..."
            NavigationDrawerItem(
                selected = engine.activeRoomId == room.id,
                onClick = { onRoomClick(room.id) },
                modifier = Modifier.padding(horizontal = 8.dp, vertical = 1.dp),
                colors = NavigationDrawerItemDefaults.colors(
                    selectedContainerColor = Accent.copy(alpha = 0.15f),
                    unselectedContainerColor = Color.Transparent
                ),
                icon = {
                    Box(Modifier.size(40.dp).clip(CircleShape).background(GroupColor), Alignment.Center) {
                        Icon(Icons.Default.Group, contentDescription = null, tint = Color.White, modifier = Modifier.size(20.dp))
                    }
                },
                label = {
                    Column {
                        Text(room.name, color = TextPrim, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(preview, color = TextSec, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            )
        }
    }
}

// ─── New DM Dialog ─────────────────────────────────────────────────────────────
@Composable
fun NewDMDialog(
    engine: VolaEngine, scope: CoroutineScope,
    onDismiss: () -> Unit, onDMCreated: (String) -> Unit
) {
    var username by remember { mutableStateOf("") }
    var errorMsg by remember { mutableStateOf("") }
    var loading by remember { mutableStateOf(false) }

    Dialog(onDismissRequest = onDismiss) {
        Surface(
            shape = RoundedCornerShape(16.dp),
            color = BgCard,
            tonalElevation = 8.dp
        ) {
            Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text("New Direct Message", color = TextPrim, fontSize = 18.sp, fontWeight = FontWeight.Bold)

                OutlinedTextField(
                    value = username, onValueChange = { username = it; errorMsg = "" },
                    label = { Text("Username") },
                    singleLine = true,
                    colors = outlinedTextFieldColors(),
                    modifier = Modifier.fillMaxWidth(),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done)
                )

                if (errorMsg.isNotEmpty()) {
                    Text(errorMsg, color = Color(0xFFFF6B6B), fontSize = 12.sp)
                }

                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End, verticalAlignment = Alignment.CenterVertically) {
                    TextButton(onClick = onDismiss) { Text("Cancel", color = TextSec) }
                    Spacer(Modifier.width(8.dp))
                    Button(
                        onClick = {
                            if (username.isBlank()) { errorMsg = "Enter a username"; return@Button }
                            loading = true
                            scope.launch {
                                try {
                                    // First find user by username via fetchProfile workaround –
                                    // look them up in online users or resolve via register lookup.
                                    // For now, we search existing room members for the username.
                                    val roomMembers = engine.rooms.value
                                        .flatMap { engine.fetchRoomMembers(it.id) }
                                        .distinctBy { it.id }
                                    val target = roomMembers.find {
                                        it.username.equals(username.trim(), ignoreCase = true)
                                    }
                                    if (target == null) {
                                        errorMsg = "User \"${username.trim()}\" not found in any shared room"
                                        loading = false
                                        return@launch
                                    }
                                    val roomId = engine.createDM(target.id)
                                    if (roomId != null) {
                                        onDMCreated(roomId)
                                    } else {
                                        errorMsg = "Failed to create DM"
                                    }
                                } catch (e: Exception) {
                                    errorMsg = e.message ?: "Error"
                                } finally {
                                    loading = false
                                }
                            }
                        },
                        enabled = !loading,
                        colors = ButtonDefaults.buttonColors(containerColor = DmColor)
                    ) {
                        if (loading) CircularProgressIndicator(Modifier.size(16.dp), color = Color.White, strokeWidth = 2.dp)
                        else Text("Start Chat", color = Color.White)
                    }
                }
            }
        }
    }
}

// ─── Message Bubble ───────────────────────────────────────────────────────────
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun MessageBubble(
    msg: ChatMessage, isMe: Boolean, messages: List<ChatMessage>, idx: Int,
    myUserId: String, readReceipts: Map<String, String>, userProfiles: Map<String, UserProfile>,
    onLongClick: () -> Unit, onReply: () -> Unit, onReact: (String) -> Unit,
    onEdit: () -> Unit, onDelete: () -> Unit
) {
    val replyMsg = msg.replyToMessageId?.let { id -> messages.find { it.id == id } }
    var showActions by remember { mutableStateOf(false) }
    val senderProfile = userProfiles[msg.senderId]
    val senderName = senderProfile?.displayName ?: msg.senderId.take(8)

    Column(
        Modifier.fillMaxWidth().padding(vertical = 2.dp),
        horizontalAlignment = if (isMe) Alignment.End else Alignment.Start
    ) {
        // Sender name (group chats)
        if (!isMe && !msg.chatRoomId.startsWith("dm_")) {
            Text(senderName, color = Accent, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(start = 8.dp, bottom = 2.dp))
        }

        Box(
            Modifier.combinedClickable(onClick = { showActions = !showActions }, onLongClick = onLongClick)
                .widthIn(max = 300.dp)
                .clip(RoundedCornerShape(
                    topStart = 16.dp, topEnd = 16.dp,
                    bottomStart = if (isMe) 16.dp else 4.dp,
                    bottomEnd = if (isMe) 4.dp else 16.dp
                ))
                .background(if (isMe) Brush.linearGradient(listOf(Accent, AccentEnd)) else Brush.linearGradient(listOf(BgInput, BgInput)))
                .padding(12.dp, 10.dp)
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                // Reply preview
                replyMsg?.let {
                    Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(4.dp))
                        .background(Color.Black.copy(alpha = 0.2f)).padding(8.dp, 4.dp)
                    ) {
                        Text("↩ ${it.content.take(60)}", color = Color.White.copy(alpha = 0.7f), fontSize = 11.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    }
                }

                if (msg.isDeleted) {
                    Text("This message was deleted", color = Color.White.copy(alpha = 0.5f), fontSize = 13.sp, fontStyle = FontStyle.Italic)
                } else if (msg.msgType == "ImageBlurHash") {
                    val json = try { com.google.gson.JsonParser.parseString(msg.content).asJsonObject } catch(e: Exception) { null }
                    val hdUrl = json?.get("hd_url")?.asString
                    if (hdUrl != null) {
                        AsyncImage(
                            model = hdUrl,
                            contentDescription = "Shared Image",
                            contentScale = ContentScale.Crop,
                            modifier = Modifier.widthIn(max = 240.dp).heightIn(max = 300.dp).clip(RoundedCornerShape(8.dp))
                        )
                    } else {
                        Text("📷 Image", color = Color.White, fontSize = 13.sp)
                    }
                } else {
                    Text(msg.content, color = Color.White, fontSize = 14.sp)
                }

                Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        formatTime(msg.timestamp), color = Color.White.copy(alpha = 0.5f), fontSize = 10.sp
                    )
                    if (msg.isEdited && !msg.isDeleted) Text("(edited)", color = Color.White.copy(alpha = 0.4f), fontSize = 10.sp)
                    if (isMe) {
                        val isRead = readReceipts.any { (uid, msgId) -> uid != myUserId && msgId == msg.id }
                        Icon(
                            if (isRead) Icons.Default.DoneAll else Icons.Default.Done,
                            contentDescription = null, tint = if (isRead) Online else Color.White.copy(0.5f), modifier = Modifier.size(12.dp)
                        )
                    }
                }

                // Reactions
                if (msg.reactions.isNotEmpty()) {
                    Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        msg.reactions.forEach { (emoji, users) ->
                            Box(Modifier.clip(RoundedCornerShape(12.dp)).background(Color.Black.copy(0.25f)).padding(6.dp, 3.dp)) {
                                Text("$emoji ${users.size}", color = Color.White, fontSize = 11.sp)
                            }
                        }
                    }
                }
            }
        }

        // Action buttons
        AnimatedVisibility(showActions && !msg.isDeleted) {
            Row(Modifier.padding(4.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                listOf("👍", "❤️", "😂", "🔥").forEach { emoji ->
                    TextButton(onClick = { onReact(emoji); showActions = false },
                        contentPadding = PaddingValues(4.dp)
                    ) { Text(emoji, fontSize = 18.sp) }
                }
                IconButton(onClick = { onReply(); showActions = false }, modifier = Modifier.size(32.dp)) {
                    Icon(Icons.Default.Reply, contentDescription = "Reply", tint = TextSec, modifier = Modifier.size(18.dp))
                }
                if (isMe) {
                    IconButton(onClick = { onEdit(); showActions = false }, modifier = Modifier.size(32.dp)) {
                        Icon(Icons.Default.Edit, contentDescription = "Edit", tint = TextSec, modifier = Modifier.size(18.dp))
                    }
                    IconButton(onClick = { onDelete(); showActions = false }, modifier = Modifier.size(32.dp)) {
                        Icon(Icons.Default.Delete, contentDescription = "Delete", tint = Color(0xFFEF4444), modifier = Modifier.size(18.dp))
                    }
                }
            }
        }
    }
}

// ─── Input Area ───────────────────────────────────────────────────────────────
@Composable
fun InputArea(
    inputText: String, editingMsg: ChatMessage?, replyingTo: ChatMessage?,
    onTextChange: (String) -> Unit, onSend: () -> Unit, onAttach: () -> Unit, onCancelEdit: () -> Unit
) {
    Column(Modifier.background(BgCard)) {
        if (editingMsg != null || replyingTo != null) {
            Row(
                Modifier.fillMaxWidth().background(BgInput).padding(12.dp, 8.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Icon(
                    if (editingMsg != null) Icons.Default.Edit else Icons.Default.Reply,
                    contentDescription = null, tint = Accent, modifier = Modifier.size(16.dp)
                )
                Text(
                    (editingMsg ?: replyingTo)!!.content.take(80),
                    color = TextSec, fontSize = 12.sp, modifier = Modifier.weight(1f),
                    maxLines = 1, overflow = TextOverflow.Ellipsis,
                    fontStyle = if (editingMsg != null) FontStyle.Normal else FontStyle.Italic
                )
                IconButton(onClick = onCancelEdit, modifier = Modifier.size(20.dp)) {
                    Icon(Icons.Default.Close, contentDescription = "Cancel", tint = TextSec, modifier = Modifier.size(16.dp))
                }
            }
        }
        Row(
            Modifier.fillMaxWidth().padding(8.dp),
            verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            IconButton(onClick = onAttach) {
                Icon(Icons.Default.AttachFile, contentDescription = "Attach", tint = TextSec)
            }
            OutlinedTextField(
                value = inputText, onValueChange = onTextChange,
                modifier = Modifier.weight(1f),
                placeholder = { Text("Write a message...", color = TextSec) },
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = Accent, unfocusedBorderColor = GroupColor,
                    cursorColor = Accent, focusedTextColor = TextPrim, unfocusedTextColor = TextPrim,
                    focusedContainerColor = BgInput, unfocusedContainerColor = BgInput
                ),
                shape = RoundedCornerShape(24.dp),
                maxLines = 5,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                keyboardActions = KeyboardActions(onSend = { onSend() })
            )
            Box(
                Modifier.size(48.dp).clip(CircleShape)
                    .background(if (inputText.isNotBlank()) Brush.linearGradient(listOf(Accent, AccentEnd)) else Brush.linearGradient(listOf(GroupColor, GroupColor)))
                    .clickable(enabled = inputText.isNotBlank(), onClick = onSend),
                Alignment.Center
            ) {
                Icon(Icons.Default.Send, contentDescription = "Send", tint = Color.White, modifier = Modifier.size(22.dp))
            }
        }
    }
}

// ─── Members Panel ────────────────────────────────────────────────────────────
@Composable
fun MembersPanel(
    members: List<RoomMember>, engine: VolaEngine, onlineUsers: Map<String, Boolean>,
    userProfiles: Map<String, UserProfile>, scope: CoroutineScope
) {
    Column(Modifier.width(220.dp).fillMaxHeight().background(Color(0xFF0F172A))) {
        Text("Members", Modifier.padding(16.dp, 12.dp), color = TextPrim, fontSize = 14.sp, fontWeight = FontWeight.Bold)
        Divider(color = BgInput)
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            items(members, key = { it.id }) { m ->
                val profile = userProfiles[m.id]
                val name = profile?.displayName ?: m.displayName ?: m.username
                val isOnline = onlineUsers[m.id] == true
                val lastSeen = profile?.lastSeen

                Row(
                    Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp))
                        .clickable(enabled = m.id != engine.userId) {
                            scope.launch {
                                val roomId = engine.createDM(m.id)
                                if (roomId != null) engine.setActiveRoom(roomId)
                            }
                        }.padding(8.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Box(Modifier.size(36.dp)) {
                        Box(Modifier.fillMaxSize().clip(CircleShape).background(GroupColor), Alignment.Center) {
                            if (profile?.avatarUrl != null) {
                                AsyncImage(model = profile.avatarUrl, contentDescription = null, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                            } else {
                                Text(name.first().uppercaseChar().toString(), color = TextPrim, fontSize = 14.sp, fontWeight = FontWeight.Bold)
                            }
                        }
                        if (isOnline) {
                            Box(Modifier.size(10.dp).clip(CircleShape).background(Online).align(Alignment.BottomEnd).border(2.dp, Color(0xFF0F172A), CircleShape))
                        }
                    }
                    Column(Modifier.weight(1f)) {
                        Text(name + if (m.id == engine.userId) " (You)" else "", color = TextPrim, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        val sub = when {
                            isOnline -> "Online"
                            lastSeen != null -> formatLastSeen(lastSeen)
                            else -> "@${m.username}"
                        }
                        Text(sub, color = TextSec, fontSize = 11.sp)
                    }
                }
            }
        }
    }
}

// ─── Profile Dialog ───────────────────────────────────────────────────────────
@Composable
fun ProfileEditDialog(
    engine: VolaEngine, userProfiles: Map<String, UserProfile>,
    scope: CoroutineScope, context: Context, onDismiss: () -> Unit
) {
    val myProfile = userProfiles[engine.userId]
    var displayName by remember { mutableStateOf(myProfile?.displayName ?: "") }
    var bio by remember { mutableStateOf(myProfile?.bio ?: "") }
    var saving by remember { mutableStateOf(false) }

    val imagePickerLauncher = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        uri?.let {
            scope.launch {
                val file = uriToFile(context, it) ?: return@launch
                engine.uploadAvatar(file)
            }
        }
    }

    Dialog(onDismissRequest = onDismiss) {
        Card(colors = CardDefaults.cardColors(containerColor = BgInput), shape = RoundedCornerShape(20.dp)) {
            Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Edit Profile", color = TextPrim, fontSize = 20.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                    IconButton(onClick = onDismiss) { Icon(Icons.Default.Close, contentDescription = "Close", tint = TextSec) }
                }
                // Avatar
                Box(Modifier.align(Alignment.CenterHorizontally).size(96.dp).clip(CircleShape)
                    .clickable { imagePickerLauncher.launch("image/*") }
                ) {
                    val freshProfile = userProfiles[engine.userId]
                    if (freshProfile?.avatarUrl != null) {
                        AsyncImage(model = freshProfile.avatarUrl, contentDescription = null, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                    } else {
                        Box(Modifier.fillMaxSize().background(Brush.linearGradient(listOf(Accent, AccentEnd))), Alignment.Center) {
                            val n = freshProfile?.displayName ?: engine.username ?: "?"
                            Text(n.first().uppercaseChar().toString(), color = Color.White, fontSize = 36.sp, fontWeight = FontWeight.Bold)
                        }
                    }
                    Box(Modifier.size(28.dp).clip(CircleShape).background(Accent).align(Alignment.BottomEnd), Alignment.Center) {
                        Icon(Icons.Default.CameraAlt, contentDescription = null, tint = Color.White, modifier = Modifier.size(14.dp))
                    }
                }
                OutlinedTextField(
                    value = displayName, onValueChange = { displayName = it },
                    label = { Text("Display Name") }, modifier = Modifier.fillMaxWidth(),
                    colors = outlinedTextFieldColors(), singleLine = true
                )
                OutlinedTextField(
                    value = bio, onValueChange = { bio = it },
                    label = { Text("Bio") }, modifier = Modifier.fillMaxWidth(),
                    colors = outlinedTextFieldColors(), minLines = 2, maxLines = 3
                )
                Button(
                    onClick = {
                        scope.launch {
                            saving = true
                            engine.updateProfile(displayName.takeIf { it.isNotBlank() }, bio.takeIf { it.isNotBlank() })
                            saving = false
                            onDismiss()
                        }
                    },
                    enabled = !saving, modifier = Modifier.fillMaxWidth().height(48.dp),
                    shape = RoundedCornerShape(12.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = Accent)
                ) {
                    if (saving) CircularProgressIndicator(Modifier.size(20.dp), color = Color.White, strokeWidth = 2.dp)
                    else Text("Save Changes", fontWeight = FontWeight.Bold)
                }
            }
        }
    }
}

// ─── Create Room Dialog ───────────────────────────────────────────────────────
@Composable
fun CreateRoomDialog(onDismiss: () -> Unit, onCreate: (String) -> Unit) {
    var name by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = BgInput, titleContentColor = TextPrim, textContentColor = TextSec,
        title = { Text("Create New Room") },
        text = {
            OutlinedTextField(
                value = name, onValueChange = { name = it },
                label = { Text("Room Name") }, modifier = Modifier.fillMaxWidth(),
                colors = outlinedTextFieldColors(), singleLine = true
            )
        },
        confirmButton = {
            Button(onClick = { if (name.isNotBlank()) onCreate(name) },
                colors = ButtonDefaults.buttonColors(containerColor = Accent)
            ) { Text("Create") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel", color = TextSec) } }
    )
}

// ─── Helpers ──────────────────────────────────────────────────────────────────
fun formatTime(timestamp: Long): String {
    return SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(timestamp * 1000))
}

fun formatLastSeen(unixSec: Long): String {
    val diff = (System.currentTimeMillis() / 1000) - unixSec
    return when {
        diff < 60 -> "just now"
        diff < 3600 -> "${diff / 60}m ago"
        diff < 86400 -> "${diff / 3600}h ago"
        else -> "${diff / 86400}d ago"
    }
}

fun uriToFile(context: Context, uri: Uri): File? {
    return try {
        val inputStream = context.contentResolver.openInputStream(uri) ?: return null
        val ext = context.contentResolver.getType(uri)?.substringAfterLast('/') ?: "jpg"
        val file = File(context.cacheDir, "upload_${System.currentTimeMillis()}.$ext")
        FileOutputStream(file).use { out -> inputStream.copyTo(out) }
        file
    } catch (e: Exception) { null }
}
