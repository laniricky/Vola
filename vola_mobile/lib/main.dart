import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blurhash/flutter_blurhash.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'services/vola_engine.dart';
import 'services/vola_webrtc.dart';

void main() {
  runApp(const VolaApp());
}

class VolaApp extends StatelessWidget {
  const VolaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vola',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F0F12),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFF512F),
          secondary: Color(0xFFDD2476),
        ),
        fontFamily: 'Roboto',
      ),
      home: const AuthWrapper(),
    );
  }
}

class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  final VolaEngine _engine = VolaEngine();
  bool? _isAuthenticated;

  @override
  void initState() {
    super.initState();
    _engine.authStream.listen((auth) {
      if (mounted) setState(() => _isAuthenticated = auth);
    });
    _engine.initialize();
  }

  @override
  void dispose() {
    _engine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isAuthenticated == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_isAuthenticated!) {
      return AuthScreen(engine: _engine);
    }
    return ChatScreen(engine: _engine);
  }
}

class AuthScreen extends StatefulWidget {
  final VolaEngine engine;
  const AuthScreen({super.key, required this.engine});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool isLogin = true;
  String username = '';
  String password = '';
  bool isLoading = false;
  String error = '';

  void _submit() async {
    setState(() {
      isLoading = true;
      error = '';
    });
    try {
      await widget.engine.authenticate(username, password, isLogin);
    } catch (e) {
      setState(() => error = e.toString().replaceAll('Exception: ', ''));
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 20)
              ]
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isLogin ? 'Welcome Back' : 'Create Account',
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)
                ),
                const SizedBox(height: 24),
                if (error.isNotEmpty) ...[
                  Text(error, style: const TextStyle(color: Colors.redAccent)),
                  const SizedBox(height: 16),
                ],
                TextField(
                  decoration: InputDecoration(
                    hintText: 'Username',
                    filled: true,
                    fillColor: const Color(0xFF0F172A),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none)
                  ),
                  onChanged: (v) => username = v,
                ),
                const SizedBox(height: 16),
                TextField(
                  obscureText: true,
                  decoration: InputDecoration(
                    hintText: 'Password',
                    filled: true,
                    fillColor: const Color(0xFF0F172A),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none)
                  ),
                  onChanged: (v) => password = v,
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF512F),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))
                    ),
                    onPressed: isLoading ? null : _submit,
                    child: isLoading 
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : Text(isLogin ? 'Login' : 'Register', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () => setState(() => isLogin = !isLogin),
                  child: Text(
                    isLogin ? "Don't have an account? Register" : "Already have an account? Login",
                    style: const TextStyle(color: Color(0xFF94A3B8))
                  ),
                )
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ChatScreen extends StatefulWidget {
  final VolaEngine engine;
  const ChatScreen({super.key, required this.engine});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  late final VolaEngine _engine;
  late final VolaWebRTC _webrtc;
  final TextEditingController _msgController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FlutterLocalNotificationsPlugin _localNotifs = FlutterLocalNotificationsPlugin();
  AppLifecycleState _appState = AppLifecycleState.resumed;
  
  ChatMessage? _editingMessage;
  ChatMessage? _replyingTo;
  
  bool _showLoadingMore = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _engine = widget.engine;
    _webrtc = VolaWebRTC(_engine);
    _webrtc.initializeRenderers();
    
    const initializationSettingsAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initializationSettings = InitializationSettings(android: initializationSettingsAndroid);
    _localNotifs.initialize(initializationSettings);

    // Auto scroll to bottom on NEW messages (only if user is near bottom)
    _engine.messagesStream.listen((messages) {
      if (messages.isEmpty) return;
      final newestMsg = messages.last;
      final isMe = newestMsg.senderId == (_engine.userId ?? 'me');

      if (!isMe && _appState != AppLifecycleState.resumed) {
          const androidDetails = AndroidNotificationDetails('vola_channel', 'Vola Notifications', importance: Importance.max, priority: Priority.high);
          const details = NotificationDetails(android: androidDetails);
          final body = newestMsg.msgType == MessageType.ImageBlurHash ? '📷 Sent an image' : newestMsg.content;
          _localNotifs.show(0, 'Vola: New Message', body, details);
      }

      Future.delayed(const Duration(milliseconds: 100), () {
        if (_scrollController.hasClients) {
          final pos = _scrollController.position;
          // Only auto-scroll if within 200px of bottom
          if (pos.maxScrollExtent - pos.pixels < 200) {
            _scrollController.animateTo(
              pos.maxScrollExtent,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            );
          }
        }
      });
    });

    // Infinite scroll: load older messages when user reaches the top
    _scrollController.addListener(() {
      if (_scrollController.position.pixels <= 80 &&
          _engine.hasMoreMessages &&
          !_engine.isLoadingMore) {
        setState(() => _showLoadingMore = true);
        _engine.loadMoreMessages().then((_) {
          if (mounted) setState(() => _showLoadingMore = false);
        });
      }
    });

    // Fetch own profile so the Drawer header has display name + avatar ready
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_engine.userId != null) {
        _engine.fetchProfile(_engine.userId!);
      }
    });
  }

  @override
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appState = state;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _msgController.dispose();
    _scrollController.dispose();
    _webrtc.dispose();
    super.dispose();
  }

  void _sendText() {
    if (_msgController.text.isNotEmpty) {
      if (_editingMessage != null) {
        _engine.editMessage(_editingMessage!.id, _msgController.text);
        setState(() => _editingMessage = null);
      } else {
        _engine.sendMessage(_msgController.text, MessageType.Text, _replyingTo?.id);
        if (_replyingTo != null) setState(() => _replyingTo = null);
      }
      _msgController.clear();
    }
  }

  List<Map<String, dynamic>> _roomMembers = [];
  bool _isLoadingMembers = false;

  void _pickAndUploadImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);
    if (pickedFile != null) {
      await _engine.uploadImage(pickedFile.path);
    }
  }

  void _showCreateRoomDialog() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('Create New Room'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(hintText: 'Room Name', filled: true, fillColor: Color(0xFF0F172A)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF512F)),
            onPressed: () async {
              if (ctrl.text.trim().isNotEmpty) {
                await _engine.createRoom(ctrl.text.trim());
                if (mounted) Navigator.pop(ctx);
              }
            },
            child: const Text('Create', style: TextStyle(color: Colors.white)),
          )
        ],
      )
    );
  }

  void _loadMembers() async {
    setState(() => _isLoadingMembers = true);
    final members = await _engine.fetchRoomMembers(_engine.activeRoomId);
    if (mounted) {
      setState(() {
         _roomMembers = members;
         _isLoadingMembers = false;
      });
      // Fetch profiles for each member
      for (final m in members) {
        final id = m['id'] as String?;
        if (id != null && !_engine.userProfiles.containsKey(id)) {
          _engine.fetchProfile(id);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scaffold = Scaffold(
      drawer: _buildDrawer(),
      endDrawer: Drawer(
        backgroundColor: const Color(0xFF0F172A),
        child: Column(
          children: [
            const DrawerHeader(
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFF1E293B)))),
              child: Center(child: Text('Room Members', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
            ),
            if (_isLoadingMembers) const Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator()),
            if (!_isLoadingMembers)
              Expanded(
                child: StreamBuilder<Map<String, bool>>(
                  stream: _engine.onlineUsersStream,
                  initialData: _engine.onlineUsers,
                  builder: (context, onlineSnap) {
                    final onlineMap = onlineSnap.data ?? {};
                    return StreamBuilder<Map<String, UserProfile>>(
                      stream: _engine.userProfilesStream,
                      initialData: _engine.userProfiles,
                      builder: (context, profileSnap) {
                        final profiles = profileSnap.data ?? {};
                        return ListView.builder(
                          padding: EdgeInsets.zero,
                          itemCount: _roomMembers.length,
                          itemBuilder: (ctx, idx) {
                            final m = _roomMembers[idx];
                            final String rawName = m['display_name'] ?? m['username'];
                            final String id = m['id'] ?? '';
                            final bool isOnline = onlineMap[id] == true;
                            final profile = profiles[id];
                            final displayName = profile?.displayName ?? rawName;
                            final avatarUrl = profile?.avatarUrl;
                            final lastSeen = profile?.lastSeen;
                            final lastSeenStr = (!isOnline && lastSeen != null)
                                ? 'Last seen ${_formatLastSeen(lastSeen)}'
                                : null;
                            return ListTile(
                              leading: Stack(
                                children: [
                                  CircleAvatar(
                                    backgroundColor: const Color(0xFF334155),
                                    backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl) : null,
                                    child: avatarUrl == null ? Text(displayName[0].toUpperCase()) : null,
                                  ),
                                  if (isOnline)
                                    Positioned(
                                      right: 0, bottom: 0,
                                      child: Container(
                                        width: 12, height: 12,
                                        decoration: BoxDecoration(
                                          color: Colors.greenAccent,
                                          shape: BoxShape.circle,
                                          border: Border.all(color: const Color(0xFF0F172A), width: 2),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              title: Text(displayName),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text('@${m['username']}', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                                  if (profile?.bio != null && profile!.bio!.isNotEmpty)
                                    Text(profile.bio!, style: const TextStyle(color: Colors.grey, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
                                  if (lastSeenStr != null)
                                    Text(lastSeenStr, style: TextStyle(color: Colors.grey.withOpacity(0.6), fontSize: 11)),
                                ],
                              ),
                              onTap: () {
                                if (m['id'] != _engine.userId) {
                                  _engine.createDM(m['id']);
                                  Navigator.pop(ctx);
                                }
                              },
                            );
                          },
                        );
                      },
                    );
                  },
                ),
              ),
          ],
        ),
      ),
      onEndDrawerChanged: (isOpen) {
        if (isOpen) _loadMembers();
      },
      appBar: AppBar(
        backgroundColor: const Color(0xFF16161A),
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StreamBuilder<List<ChatRoom>>(
              stream: _engine.roomsStream,
              builder: (context, snap) {
                final rooms = snap.data ?? [];
                final active = rooms.where((r) => r.id == _engine.activeRoomId).toList().firstOrNull?.name;
                return Text(active ?? 'Loading...', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold));
              },
            ),
            StreamBuilder<List<String>>(
              stream: _engine.typingStream,
              builder: (context, snapshot) {
                final typing = snapshot.data ?? [];
                if (typing.isNotEmpty) {
                  return Text(
                    typing.length > 1 ? 'Several people are typing...' : 'Someone is typing...',
                    style: const TextStyle(fontSize: 12, color: Color(0xFFFF512F), fontStyle: FontStyle.italic),
                  );
                }
                return StreamBuilder<String>(
                  stream: _engine.statusStream,
                  builder: (context, statusSnap) {
                    final status = statusSnap.data ?? 'Reconnecting...';
                    return Text(status, style: const TextStyle(fontSize: 12, color: Colors.grey));
                  },
                );
              },
            ),
          ],
        ),
        actions: [
          IconButton(icon: const Icon(Icons.search, color: Colors.grey), onPressed: () {}),
          if (_engine.activeRoomId.startsWith('dm_') && _roomMembers.isNotEmpty) ...[
            IconButton(
              icon: const Icon(Icons.call, color: Color(0xFF22C55E)),
              onPressed: () {
                final target = _roomMembers.firstWhere((m) => m['id'] != _engine.userId, orElse: () => {});
                if (target.isNotEmpty) _webrtc.startCall(target['id'], withVideo: false);
              },
            ),
            IconButton(
              icon: const Icon(Icons.videocam, color: Color(0xFF3B82F6)),
              onPressed: () {
                final target = _roomMembers.firstWhere((m) => m['id'] != _engine.userId, orElse: () => {});
                if (target.isNotEmpty) _webrtc.startCall(target['id'], withVideo: true);
              },
            ),
          ],
          Builder(
            builder: (context) => IconButton(
              icon: const Icon(Icons.people, color: Colors.grey),
              onPressed: () => Scaffold.of(context).openEndDrawer(),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          StreamBuilder<String>(
            stream: _engine.statusStream,
            builder: (context, statusSnap) {
              if (statusSnap.data == 'Reconnecting...') {
                return Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(colors: [Color(0xFFD4A017), Color(0xFFE6B422)]),
                  ),
                  child: const Text(
                    'Reconnecting to server...',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Color(0xFF1A1A1A), fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                );
              }
              return const SizedBox.shrink();
            },
          ),
          Expanded(
            child: StreamBuilder<Map<String, String>>(
              stream: _engine.readReceiptsStream,
              initialData: _engine.readReceipts,
              builder: (context, receiptsSnap) {
                final receipts = receiptsSnap.data ?? {};
                return StreamBuilder<List<ChatMessage>>(
                  stream: _engine.messagesStream,
                  builder: (context, snapshot) {
                    final msgs = snapshot.data ?? [];
                    if (msgs.isNotEmpty) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        _engine.markRead(msgs.last.id);
                      });
                    }
                    return ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                      itemCount: msgs.length + 2,
                      itemBuilder: (context, index) {
                        if (index == 0) {
                          if (_showLoadingMore) {
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 12),
                              child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
                            );
                          }
                          if (!_engine.hasMoreMessages && msgs.isNotEmpty) {
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Center(
                                child: Text(
                                  '─── Beginning of conversation ───',
                                  style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 12),
                                ),
                              ),
                            );
                          }
                          return const SizedBox.shrink();
                        }
                        if (index == msgs.length + 1) return const SizedBox(height: 4);
                        final msg = msgs[index - 1];
                        final isMe = msg.senderId == (_engine.userId ?? 'me');
                        return _buildChatBubble(msg, isMe, msgs, index - 1, receipts);
                      },
                    );
                  },
                );
              },
            ),
          ),
          _buildInputArea(),
        ],
      ),
    );

    // ── Wrap with call overlay when a call is active ───────────────────────────
    return StreamBuilder<CallState>(
      stream: _webrtc.callStateStream,
      initialData: CallState.idle,
      builder: (context, callSnap) {
        final callState = callSnap.data ?? CallState.idle;
        if (callState == CallState.idle) return scaffold;
        return Stack(
          children: [
            scaffold,
            Positioned.fill(
              child: Container(
                color: Colors.black87,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_webrtc.isVideo) ...[
                      Positioned.fill(
                        child: RTCVideoView(
                          _webrtc.remoteRenderer,
                          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                        ),
                      ),
                      Positioned(
                        bottom: 140, right: 20,
                        width: 120, height: 160,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: ColoredBox(
                            color: Colors.black,
                            child: RTCVideoView(
                              _webrtc.localRenderer,
                              mirror: true,
                              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                            ),
                          ),
                        ),
                      ),
                    ],
                    if (!_webrtc.isVideo || callState != CallState.connected) ...[
                      const SizedBox(height: 100),
                      CircleAvatar(
                        radius: 50,
                        backgroundColor: const Color(0xFF334155),
                        child: Text(
                          (_webrtc.remoteUserId?.isNotEmpty == true)
                              ? _webrtc.remoteUserId![0].toUpperCase()
                              : '?',
                          style: const TextStyle(fontSize: 40, color: Colors.white),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        callState == CallState.calling
                            ? 'Calling...'
                            : callState == CallState.ringing
                                ? (_webrtc.isVideo ? 'Incoming Video Call' : 'Incoming Audio Call')
                                : 'Call Connected',
                        style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                      ),
                      if (_webrtc.remoteUserId != null) ...[
                        const SizedBox(height: 8),
                        Text(_webrtc.remoteUserId!, style: const TextStyle(color: Colors.grey, fontSize: 14)),
                      ],
                    ],
                    const Spacer(),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 60),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (callState == CallState.ringing) ...[
                            _callButton(
                              icon: Icons.call,
                              color: const Color(0xFF22C55E),
                              onTap: () => _webrtc.acceptCall(),
                            ),
                            const SizedBox(width: 40),
                          ],
                          if (callState == CallState.connected) ...[
                            _callButton(
                              icon: _webrtc.isMuted ? Icons.mic_off : Icons.mic,
                              color: _webrtc.isMuted ? const Color(0xFFEF4444) : Colors.white24,
                              onTap: () => _webrtc.toggleMute(),
                            ),
                            const SizedBox(width: 20),
                            if (_webrtc.isVideo) ...[
                              _callButton(
                                icon: _webrtc.isVideoOff ? Icons.videocam_off : Icons.videocam,
                                color: _webrtc.isVideoOff ? const Color(0xFFEF4444) : Colors.white24,
                                onTap: () => _webrtc.toggleVideo(),
                              ),
                              const SizedBox(width: 20),
                            ],
                          ],
                          _callButton(
                            icon: Icons.call_end,
                            color: const Color(0xFFEF4444),
                            onTap: () => callState == CallState.ringing
                                ? _webrtc.rejectCall()
                                : _webrtc.endCall(),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  String _formatLastSeen(int unixSeconds) {
    final dt = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  Widget _callButton({required IconData icon, required Color color, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Icon(icon, color: Colors.white, size: 28),
      ),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      backgroundColor: const Color(0xFF16161A),
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          StreamBuilder<Map<String, UserProfile>>(
            stream: _engine.userProfilesStream,
            initialData: _engine.userProfiles,
            builder: (ctx, profileSnap) {
              final profiles = profileSnap.data ?? {};
              final myProfile = profiles[_engine.userId];
              final displayName = myProfile?.displayName ?? _engine.userId ?? 'You';
              final avatarUrl = myProfile?.avatarUrl;

              return GestureDetector(
                onTap: () => _showProfileEditSheet(myProfile),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(16, 48, 16, 16),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Color(0xFF1A0A0A), Color(0xFF0F0F12)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 28,
                        backgroundColor: const Color(0xFF334155),
                        backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl) : null,
                        child: avatarUrl == null
                            ? Text(displayName[0].toUpperCase(), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold))
                            : null,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(displayName, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
                            if (myProfile?.bio != null && myProfile!.bio!.isNotEmpty)
                              Text(myProfile.bio!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 12)),
                            Text('Tap to edit profile', style: TextStyle(color: const Color(0xFFFF512F).withOpacity(0.8), fontSize: 11)),
                          ],
                        ),
                      ),
                      const Icon(Icons.edit, size: 16, color: Colors.grey),
                    ],
                  ),
                ),
              );
            }
          ),
          StreamBuilder<List<ChatRoom>>(
            stream: _engine.roomsStream,
            builder: (context, snapshot) {
              final rooms = snapshot.data ?? [];
              return StreamBuilder<Map<String, ChatMessage>>(
                stream: _engine.roomLastMessagesStream,
                builder: (context, lastMsgsSnap) {
                  final lastMsgs = lastMsgsSnap.data ?? {};
                  return Column(
                    children: rooms.map((r) {
                      final isDM = r.id.startsWith('dm_');
                      final lastMsg = lastMsgs[r.id];
                      final previewText = lastMsg != null
                          ? (lastMsg.msgType == MessageType.ImageBlurHash ? '📷 Image' : lastMsg.content)
                          : 'Tap to view chat...';

                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: isDM ? const Color(0xFF4F46E5) : const Color(0xFF334155),
                          radius: 18,
                          child: Icon(isDM ? Icons.person : Icons.group, color: Colors.white, size: 20),
                        ),
                        title: Text(r.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                        subtitle: Text(
                          previewText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: Colors.grey.withOpacity(0.8), fontSize: 13),
                        ),
                        selected: _engine.activeRoomId == r.id,
                        selectedTileColor: const Color(0xFF222226),
                        onTap: () {
                                _engine.setActiveRoom(r.id);
                                Navigator.pop(context);
                                setState(() {});
                             },
                           );
                    }).toList()
                             ..add(
                               ListTile(
                                 leading: const Icon(Icons.add, color: Colors.grey),
                                 title: const Text('Create Room', style: TextStyle(color: Colors.grey)),
                                 onTap: () {
                                   Navigator.pop(context);
                                   _showCreateRoomDialog();
                                 },
                               )
                             ),
                  );
                }
              );
            },
          ),
        ],
      ),
    );
  }

  void _showProfileEditSheet(UserProfile? current) {
    final nameCtrl = TextEditingController(text: current?.displayName ?? '');
    final bioCtrl = TextEditingController(text: current?.bio ?? '');
    final picker = ImagePicker();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom, left: 24, right: 24, top: 24),
        child: StatefulBuilder(
          builder: (ctx, setSheetState) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('Edit Profile', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
                ],
              ),
              const SizedBox(height: 16),
              Center(
                child: GestureDetector(
                  onTap: () async {
                    final file = await picker.pickImage(source: ImageSource.gallery, imageQuality: 75);
                    if (file != null) {
                      await _engine.uploadAvatar(File(file.path));
                    }
                  },
                  child: StreamBuilder<Map<String, UserProfile>>(
                    stream: _engine.userProfilesStream,
                    initialData: _engine.userProfiles,
                    builder: (ctx, snap) {
                      final avatarUrl = snap.data?[_engine.userId]?.avatarUrl;
                      return Stack(
                        children: [
                          CircleAvatar(
                            radius: 48,
                            backgroundColor: const Color(0xFF334155),
                            backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl) : null,
                            child: avatarUrl == null ? const Icon(Icons.person, size: 48, color: Colors.grey) : null,
                          ),
                          Positioned(
                            bottom: 0, right: 0,
                            child: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: const BoxDecoration(color: Color(0xFFFF512F), shape: BoxShape.circle),
                              child: const Icon(Icons.camera_alt, size: 14, color: Colors.white),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: nameCtrl,
                decoration: InputDecoration(
                  labelText: 'Display Name',
                  filled: true,
                  fillColor: const Color(0xFF0F172A),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: bioCtrl,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: 'Bio',
                  filled: true,
                  fillColor: const Color(0xFF0F172A),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF512F),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () async {
                    await _engine.updateProfile(displayName: nameCtrl.text.trim(), bio: bioCtrl.text.trim());
                    if (mounted) Navigator.pop(ctx);
                  },
                  child: const Text('Save Changes', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImageOverlay(String content) {
    String hash = content;
    String hdUrl = '';
    try {
      final decoded = jsonDecode(content);
      hash = decoded['hash'] ?? content;
      hdUrl = decoded['hd_url'] ?? '';
    } catch (e) {
      // Fallback if not json
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        BlurHash(hash: hash),
        if (hdUrl.isNotEmpty) 
          Image.network(
            hdUrl,
            fit: BoxFit.cover,
            loadingBuilder: (context, child, loadingProgress) {
              if (loadingProgress == null) return child;
              return const SizedBox.shrink(); // Show just BlurHash while loading
            },
            errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
          ),
      ],
    );
  }

  void _showMsgActions(ChatMessage msg, bool isMe) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF16161A),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: ['👍', '❤️', '😂', '😮', '😢'].map((emoji) => GestureDetector(
                  onTap: () {
                    final hasReacted = msg.reactions[emoji]?.contains(_engine.userId) ?? false;
                    if (hasReacted) {
                      _engine.removeReaction(msg.id, emoji);
                    } else {
                      _engine.addReaction(msg.id, emoji);
                    }
                    Navigator.pop(ctx);
                  },
                  child: Text(emoji, style: const TextStyle(fontSize: 32)),
                )).toList(),
              ),
            ),
            const Divider(color: Colors.white24),
            ListTile(
              leading: const Icon(Icons.reply, color: Colors.white),
              title: const Text('Reply', style: TextStyle(color: Colors.white)),
              onTap: () {
                setState(() { _replyingTo = msg; _editingMessage = null; });
                Navigator.pop(ctx);
              },
            ),
            if (isMe && msg.msgType != MessageType.System) ...[
              ListTile(
                leading: const Icon(Icons.edit, color: Colors.white),
                title: const Text('Edit', style: TextStyle(color: Colors.white)),
                onTap: () {
                  setState(() { _editingMessage = msg; _replyingTo = null; _msgController.text = msg.content; });
                  Navigator.pop(ctx);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete, color: Colors.redAccent),
                title: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
                onTap: () {
                  _engine.deleteMessage(msg.id);
                  Navigator.pop(ctx);
                },
              ),
            ]
          ],
        ),
      )
    );
  }

  Widget _buildChatBubble(ChatMessage msg, bool isMe, List<ChatMessage> allMsgs, int idx, Map<String, String> receipts) {
    bool isRead = false;
    if (isMe) {
      for (final entry in receipts.entries) {
        if (entry.key == _engine.userId) continue;
        final watermarkIdx = allMsgs.indexWhere((m) => m.id == entry.value);
        if (watermarkIdx >= idx) { isRead = true; break; }
      }
    }

    return GestureDetector(
      onLongPress: () => _showMsgActions(msg, isMe),
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
          padding: msg.msgType == MessageType.ImageBlurHash ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: isMe ? const Color(0xFFFF512F) : const Color(0xFF222226),
            borderRadius: BorderRadius.circular(16).copyWith(
              bottomRight: isMe ? const Radius.circular(4) : const Radius.circular(16),
              bottomLeft: !isMe ? const Radius.circular(4) : const Radius.circular(16),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch, // Allow preview to stretch
            mainAxisSize: MainAxisSize.min,
            children: [
              if (msg.replyToMessageId != null) ...[
                  Container(
                    padding: const EdgeInsets.all(6),
                    margin: const EdgeInsets.only(bottom: 6),
                    decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(8)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.reply, size: 12, color: Colors.white70),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            allMsgs.firstWhere((m) => m.id == msg.replyToMessageId, orElse: () => ChatMessage(id: '', senderId: '', chatRoomId: '', content: 'Deleted message', msgType: MessageType.System, timestamp: 0)).content,
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12, color: Colors.white70, fontStyle: FontStyle.italic),
                          ),
                        ),
                      ],
                    ),
                  )
              ],
              
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (msg.msgType == MessageType.ImageBlurHash)...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: SizedBox(
                         width: 250,
                         height: 250,
                         child: _buildImageOverlay(msg.content),
                      ),
                    )
                  ] else ...[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        msg.content,
                        style: TextStyle(
                          color: Colors.white, 
                          fontSize: 16, 
                          fontStyle: msg.msgType == MessageType.System ? FontStyle.italic : FontStyle.normal
                        ),
                      ),
                    )
                  ],
                  Container(
                    margin: msg.msgType == MessageType.ImageBlurHash ? const EdgeInsets.only(right: 8, bottom: 8) : const EdgeInsets.only(top: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (msg.isEdited) const Padding(padding: EdgeInsets.only(right: 4), child: Text('(edited)', style: TextStyle(color: Colors.white54, fontSize: 10, fontStyle: FontStyle.italic))),
                        Text(
                          _formatTime(msg.timestamp),
                          style: TextStyle(fontSize: 10, color: Colors.white.withOpacity(0.7)),
                        ),
                        if (isMe) ...[
                          const SizedBox(width: 4),
                          Icon(
                            isRead ? Icons.done_all : Icons.done,
                            size: 12,
                            color: isRead ? const Color(0xFF7ECEF4) : Colors.white.withOpacity(0.6),
                          ),
                        ]
                      ],
                    ),
                  )
                ],
              ),
              if (msg.reactions.isNotEmpty) ...[
                const SizedBox(height: 4),
                Wrap(
                  spacing: 4, runSpacing: 4,
                  children: msg.reactions.entries.map((e) {
                    final isReacted = e.value.contains(_engine.userId ?? 'me');
                    return GestureDetector(
                      onTap: () {
                         if (isReacted) { _engine.removeReaction(msg.id, e.key); } else { _engine.addReaction(msg.id, e.key); }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                           color: isReacted ? Colors.blue.withOpacity(0.3) : Colors.white10,
                           borderRadius: BorderRadius.circular(12),
                           border: Border.all(color: isReacted ? Colors.blue : Colors.transparent),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(e.key, style: const TextStyle(fontSize: 12)),
                            const SizedBox(width: 4),
                            Text(e.value.length.toString(), style: const TextStyle(fontSize: 12, color: Colors.white70)),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ]
            ],
          ),
        ),
      ),
    );
  }

  String _formatTime(int ms) {
    final date = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  Widget _buildInputArea() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_replyingTo != null || _editingMessage != null) 
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: const Color(0xFF222226),
            child: Row(
              children: [
                Icon(_replyingTo != null ? Icons.reply : Icons.edit, color: const Color(0xFFFF512F), size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${_replyingTo != null ? 'Replying to' : 'Editing'}: ${(_replyingTo ?? _editingMessage)!.content}',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 13, fontStyle: FontStyle.italic),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.grey, size: 18),
                  onPressed: () {
                    setState(() { _replyingTo = null; _editingMessage = null; });
                    _msgController.clear();
                  },
                )
              ],
            ),
          ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          color: const Color(0xFF16161A),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.image, color: Colors.grey),
                onPressed: _pickAndUploadImage,
              ),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF222226),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: TextField(
                    controller: _msgController,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      hintText: 'Write a message...',
                      hintStyle: TextStyle(color: Colors.grey),
                      border: InputBorder.none,
                    ),
                    onChanged: (_) { /* Typying tracking missing */ },
                    onSubmitted: (_) => _sendText(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: _sendText,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [Color(0xFFFF512F), Color(0xFFDD2476)],
                    ),
                  ),
                  child: const Icon(Icons.send, color: Colors.white, size: 20),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
