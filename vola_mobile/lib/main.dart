import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blurhash/flutter_blurhash.dart';
import 'package:image_picker/image_picker.dart';
import 'services/vola_engine.dart';

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

class _ChatScreenState extends State<ChatScreen> {
  late final VolaEngine _engine;
  final TextEditingController _msgController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  
  bool _showLoadingMore = false;

  @override
  void initState() {
    super.initState();
    _engine = widget.engine;
    
    // Auto scroll to bottom on NEW messages (only if user is near bottom)
    _engine.messagesStream.listen((_) {
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
  }

  @override
  void dispose() {
    _msgController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _sendText() {
    if (_msgController.text.isNotEmpty) {
      _engine.sendMessage(_msgController.text, MessageType.Text);
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
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
                child: ListView.builder(
                  padding: EdgeInsets.zero,
                  itemCount: _roomMembers.length,
                  itemBuilder: (ctx, idx) {
                    final m = _roomMembers[idx];
                    final String name = m['display_name'] ?? m['username'];
                    return ListTile(
                      leading: CircleAvatar(backgroundColor: const Color(0xFF334155), child: Text(name[0])),
                      title: Text(name),
                      subtitle: Text('@${m['username']}', style: const TextStyle(color: Colors.grey)),
                      onTap: () {
                        if (m['id'] != _engine.userId) {
                          _engine.createDM(m['id']);
                          Navigator.pop(ctx);
                        }
                      },
                    );
                  },
                )
              )
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
                // firstWhere requires orElse mapping, so taking first element directly is safer
                final active = rooms.isNotEmpty ? rooms.where((r) => r.id == _engine.activeRoomId).toList().firstOrNull?.name : null;
                return Text(active ?? 'Loading...', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold));
              }
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
          Builder(
            builder: (context) {
              return IconButton(
                icon: const Icon(Icons.people, color: Colors.grey), 
                onPressed: () => Scaffold.of(context).openEndDrawer()
              );
            }
          ),
        ],
      ),
      body: Column(
        children: [
          // Reconnecting Banner
          StreamBuilder<String>(
            stream: _engine.statusStream,
            builder: (context, statusSnap) {
              if (statusSnap.data == 'Reconnecting...') {
                return Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Color(0xFFD4A017), Color(0xFFE6B422)],
                    ),
                  ),
                  child: const Text(
                    'Reconnecting to server...',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFF1A1A1A),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
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
                    // Auto mark-read when new messages arrive
                    if (msgs.isNotEmpty) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        _engine.markRead(msgs.last.id);
                      });
                    }
                    return ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                      // Extra items: loading indicator + "beginning" banner
                      itemCount: msgs.length + 2,
                      itemBuilder: (context, index) {
                        // Index 0: top sentinel (loading / beginning banner)
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
                        // Index msgs.length + 1: bottom spacer
                        if (index == msgs.length + 1) return const SizedBox(height: 4);
                        // Otherwise render the message (offset by 1 for top banner)
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
  }

  Widget _buildDrawer() {
    return Drawer(
      backgroundColor: const Color(0xFF16161A),
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          const DrawerHeader(
            decoration: BoxDecoration(color: Color(0xFF0F0F12)),
            child: Text('Vola', style: TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w900)),
          ),
          StreamBuilder<List<ChatRoom>>(
            stream: _engine.roomsStream,
            builder: (context, snapshot) {
              final rooms = snapshot.data ?? [];
              return StreamBuilder<Map<String, ChatMessage>>(
                stream: _engine.roomLastMessagesStream,
                // Assuming we might have added an initial getter, otherwise stream will catch up
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

  Widget _buildChatBubble(ChatMessage msg, bool isMe, List<ChatMessage> allMsgs, int idx, Map<String, String> receipts) {
    // Check if any other user's watermark is at or past this message index
    bool isRead = false;
    if (isMe) {
      for (final entry in receipts.entries) {
        if (entry.key == _engine.userId) continue;
        final watermarkIdx = allMsgs.indexWhere((m) => m.id == entry.value);
        if (watermarkIdx >= idx) {
          isRead = true;
          break;
        }
      }
    }

    return Align(
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
              Text(
                msg.content,
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ],
            Container(
              margin: msg.msgType == MessageType.ImageBlurHash ? const EdgeInsets.only(right: 8, bottom: 8) : const EdgeInsets.only(top: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _formatTime(msg.timestamp),
                    style: TextStyle(fontSize: 10, color: Colors.white.withOpacity(0.7)),
                  ),
                  if (isMe) ...[
                    const SizedBox(width: 4),
                    // Single grey tick = sent, double coloured tick = read
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
      ),
    );
  }

  String _formatTime(int ms) {
    final date = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  Widget _buildInputArea() {
    return Container(
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
                onChanged: (_) => _engine.emitTyping(),
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
    );
  }
}
