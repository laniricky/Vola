import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'dart:async';
import 'dart:math';
import 'package:flutter_webrtc/flutter_webrtc.dart';

enum MessageType { Text, ImageBlurHash, System }

class ChatRoom {
  final String id;
  final String name;

  ChatRoom({required this.id, required this.name});

  factory ChatRoom.fromJson(Map<String, dynamic> json) {
    return ChatRoom(id: json['id'], name: json['name']);
  }
}

// ─── UserProfile ─────────────────────────────────────────────────────────────

class UserProfile {
  final String id;
  final String username;
  final String? displayName;
  final String? avatarUrl;
  final String? bio;
  final int? lastSeen;

  UserProfile({
    required this.id,
    required this.username,
    this.displayName,
    this.avatarUrl,
    this.bio,
    this.lastSeen,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      id: json['id'],
      username: json['username'],
      displayName: json['display_name'],
      avatarUrl: json['avatar_url'],
      bio: json['bio'],
      lastSeen: json['last_seen'],
    );
  }
}

class ChatMessage {
  final String id;
  final String senderId;
  final String chatRoomId;
  String content;
  MessageType msgType;
  final int timestamp;
  final String? replyToMessageId;
  bool isEdited;
  bool isDeleted;
  Map<String, List<String>> reactions;

  ChatMessage({
    required this.id,
    required this.senderId,
    required this.chatRoomId,
    required this.content,
    required this.msgType,
    required this.timestamp,
    this.replyToMessageId,
    this.isEdited = false,
    this.isDeleted = false,
    Map<String, List<String>>? reactions,
  }) : reactions = reactions ?? {};

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    Map<String, List<String>> parsedReactions = {};
    if (json['reactions'] != null) {
      json['reactions'].forEach((k, v) {
        parsedReactions[k] = List<String>.from(v);
      });
    }
    
    return ChatMessage(
      id: json['id'],
      senderId: json['sender_id'] ?? json['senderId'],
      chatRoomId: json['chat_room_id'] ?? json['chatRoomId'],
      content: json['content'],
      msgType: MessageType.values.firstWhere(
        (e) => e.toString().split('.').last == json['msg_type'],
        orElse: () => MessageType.Text,
      ),
      timestamp: json['timestamp'],
      replyToMessageId: json['reply_to_message_id'],
      isEdited: json['is_edited'] ?? false,
      isDeleted: json['is_deleted'] ?? false,
      reactions: parsedReactions,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'sender_id': senderId,
        'chat_room_id': chatRoomId,
        'content': content,
        'msg_type': msgType.toString().split('.').last,
        'timestamp': timestamp,
        'reply_to_message_id': replyToMessageId,
      };
}

class VolaEngine {
  final String baseUrl = 'http://10.0.2.2:3000';
  final String wsUrl = 'ws://10.0.2.2:3000/ws';
  
  String? userId;
  String? token;
  WebSocketChannel? _channel;
  
  final _messagesController = StreamController<List<ChatMessage>>.broadcast();
  final _typingController = StreamController<List<String>>.broadcast();
  final _statusController = StreamController<String>.broadcast();
  final _roomsController = StreamController<List<ChatRoom>>.broadcast();
  final _authController = StreamController<bool>.broadcast();
  final _readReceiptsController = StreamController<Map<String, String>>.broadcast();
  final _roomLastMessagesController = StreamController<Map<String, ChatMessage>>.broadcast();
  final _onlineUsersController = StreamController<Map<String, bool>>.broadcast();
  final _incomingSignalController = StreamController<Map<String, dynamic>>.broadcast();
  final _userProfilesController = StreamController<Map<String, UserProfile>>.broadcast();
  
  List<ChatMessage> _messages = [];
  List<String> _typingUsers = [];
  List<ChatRoom> _rooms = [];
  Set<String> _sentIds = {};
  Map<String, bool> _onlineUsers = {};
  Map<String, String> _readReceipts = {}; // userId -> messageId
  Map<String, ChatMessage> _roomLastMessages = {};
  Map<String, UserProfile> _userProfiles = {};
  String activeRoomId = 'room_1';
  bool hasMoreMessages = false;
  bool isLoadingMore = false;
  int _reconnectAttempt = 0;
  bool _intentionalClose = false;
  static const int _maxReconnectDelay = 30000; // 30 seconds cap

  Stream<List<ChatMessage>> get messagesStream => _messagesController.stream;
  Stream<List<String>> get typingStream => _typingController.stream;
  Stream<String> get statusStream => _statusController.stream;
  Stream<List<ChatRoom>> get roomsStream => _roomsController.stream;
  Stream<bool> get authStream => _authController.stream;
  Stream<Map<String, String>> get readReceiptsStream => _readReceiptsController.stream;
  Stream<Map<String, ChatMessage>> get roomLastMessagesStream => _roomLastMessagesController.stream;
  Stream<Map<String, bool>> get onlineUsersStream => _onlineUsersController.stream;
  Stream<Map<String, dynamic>> get incomingSignalStream => _incomingSignalController.stream;
  Stream<Map<String, UserProfile>> get userProfilesStream => _userProfilesController.stream;
  Map<String, String> get readReceipts => Map.unmodifiable(_readReceipts);
  Map<String, bool> get onlineUsers => Map.unmodifiable(_onlineUsers);
  Map<String, UserProfile> get userProfiles => Map.unmodifiable(_userProfiles);

  Timer? _typingTimer;

  Future<void> _fetchOnlineUsers() async {
    try {
      var res = await http.get(Uri.parse('$baseUrl/api/users/online'));
      if (res.statusCode == 200) {
        List data = jsonDecode(res.body);
        _onlineUsers.clear();
        for (var id in data) _onlineUsers[id] = true;
        _onlineUsersController.add(_onlineUsers);
      }
    } catch (e) {
      print('Failed to fetch online users: $e');
    }
  }

  Future<void> initialize() async {
    _fetchRooms();
    _fetchOnlineUsers();

    final prefs = await SharedPreferences.getInstance();
    token = prefs.getString('vola_token');
    userId = prefs.getString('vola_user_id');

    if (token != null) {
      _authController.add(true);
      _connectWebSocket();
    } else {
      _authController.add(false);
    }
  }

  Future<void> authenticate(String username, String password, bool isLogin) async {
    final endpoint = isLogin ? '/api/login' : '/api/register';
    var res = await http.post(
      Uri.parse('$baseUrl$endpoint'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'username': username, 'password': password}),
    );

    if (res.statusCode == 200) {
      var data = jsonDecode(res.body);
      token = data['token'];
      userId = data['id'];
      
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('vola_token', token!);
      await prefs.setString('vola_user_id', userId!);
      await prefs.setString('vola_username', data['username']);

      _authController.add(true);
      _connectWebSocket();
    } else {
      throw Exception(res.body);
    }
  }

  Future<void> logout() async {
    _intentionalClose = true;
    _channel?.sink.close();
    _channel = null;
    
    token = null;
    userId = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('vola_token');
    await prefs.remove('vola_user_id');
    await prefs.remove('vola_username');
    
    _authController.add(false);
  }

  Future<void> _fetchRooms() async {
      var res = await http.get(Uri.parse('$baseUrl/api/rooms'));
      if (res.statusCode == 200) {
        List data = jsonDecode(res.body);
        _rooms = data.map((x) => ChatRoom.fromJson(x)).toList();
        _roomsController.add(_rooms);
      }
  }

  Future<void> createRoom(String name) async {
    if (token == null) return;
    var res = await http.post(
      Uri.parse('$baseUrl/api/rooms'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token'
      },
      body: jsonEncode({'name': name}),
    );
    if (res.statusCode == 200) {
      await _fetchRooms();
    }
  }

  Future<void> createDM(String targetUserId) async {
    if (token == null) return;
    var res = await http.post(
      Uri.parse('$baseUrl/api/rooms/dm'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token'
      },
      body: jsonEncode({'target_user_id': targetUserId}),
    );
    if (res.statusCode == 200) {
      var data = jsonDecode(res.body);
      await _fetchRooms();
      setActiveRoom(data['id']);
    }
  }

  Future<List<Map<String, dynamic>>> fetchRoomMembers(String roomId) async {
    try {
      var res = await http.get(Uri.parse('$baseUrl/api/rooms/$roomId/members'));
      if (res.statusCode == 200) {
        return List<Map<String, dynamic>>.from(jsonDecode(res.body));
      }
    } catch (e) {
      print('Failed to fetch room members: $e');
    }
    return [];
  }

  void setActiveRoom(String newRoomId) {
     activeRoomId = newRoomId;
     _readReceipts = {}; // Reset receipts on room switch
     _readReceiptsController.add(_readReceipts);
     _fetchMessageHistory();
     _fetchRoomMembers(); // Seed read receipt watermarks
  }

  Future<void> _fetchRoomMembers() async {
    try {
      final res = await fetchRoomMembers(activeRoomId);
      for (final m in res) {
        final uid = m['id'] as String?;
        final lastRead = m['last_read_message_id'] as String?;
        if (uid != null && lastRead != null) {
          _readReceipts[uid] = lastRead;
        }
      }
      _readReceiptsController.add(_readReceipts);
    } catch (e) {
      print('Failed to seed read receipts: $e');
    }
  }

  Future<void> _fetchMessageHistory() async {
      _messages.clear();
      _typingUsers.clear();
      _messagesController.add(_messages);
      _typingController.add(_typingUsers);

      var res = await http.get(Uri.parse('$baseUrl/api/messages/$activeRoomId?limit=50'));
      if (res.statusCode == 200) {
        List data = jsonDecode(res.body);
        _messages = data.map((x) => ChatMessage.fromJson(x)).toList();
        _sentIds.clear();
        for (var m in _messages) _sentIds.add(m.id);
        hasMoreMessages = _messages.length == 50;
        if (_messages.isNotEmpty) {
          _roomLastMessages[activeRoomId] = _messages.last;
          _roomLastMessagesController.add(_roomLastMessages);
        }
        _messagesController.add(_messages);
      }
  }

  Future<void> loadMoreMessages() async {
    if (isLoadingMore || !hasMoreMessages || _messages.isEmpty) return;
    isLoadingMore = true;
    try {
      final oldestTs = _messages.first.timestamp;
      final res = await http.get(
        Uri.parse('$baseUrl/api/messages/$activeRoomId?before=$oldestTs&limit=50')
      );
      if (res.statusCode == 200) {
        final List data = jsonDecode(res.body);
        final older = data.map((x) => ChatMessage.fromJson(x)).toList();
        if (older.isNotEmpty) {
          for (var m in older) _sentIds.add(m.id);
          _messages = [...older, ..._messages];
          hasMoreMessages = older.length == 50;
        } else {
          hasMoreMessages = false;
        }
        _messagesController.add(_messages);
      }
    } catch (e) {
      print('Failed to load older messages: $e');
    } finally {
      isLoadingMore = false;
    }
  }

  void _connectWebSocket() async {
    if (token == null) return;
    _intentionalClose = false;
    _statusController.add('Connecting...');
    
    try {
      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));
      _channel!.sink.add(jsonEncode({"type": "Authenticate", "payload": {"token": token}}));
      _statusController.add('Connected');
      _reconnectAttempt = 0; // Reset backoff on successful connect

      // Initial history pull
      _fetchMessageHistory();

      _channel!.stream.listen((message) {
        final data = jsonDecode(message);
        if (data['type'] == 'NewMessage') {
          final incoming = ChatMessage.fromJson(data['payload']);
          if (_sentIds.contains(incoming.id)) return;
          
          _roomLastMessages[incoming.chatRoomId] = incoming;
          _roomLastMessagesController.add(_roomLastMessages);

          if (incoming.chatRoomId == activeRoomId) {
             _messages.add(incoming);
             _messagesController.add(_messages);
          }
        } else if (data['type'] == 'UserTyping') {
          final payload = data['payload'];
          final String uId = payload['user_id'];
          final String chatRoomId = payload['chat_room_id'];
          final bool isTyping = payload['is_typing'];
          
          if (chatRoomId == activeRoomId) {
            if (isTyping) {
              if (!_typingUsers.contains(uId)) _typingUsers.add(uId);
            } else {
              _typingUsers.remove(uId);
            }
            _typingController.add(_typingUsers);
          }
        } else if (data['type'] == 'MessageRead') {
          final payload = data['payload'];
          final String uId = payload['user_id'];
          final String chatRoomId = payload['chat_room_id'];
          final String messageId = payload['message_id'];
          if (chatRoomId == activeRoomId) {
            _readReceipts[uId] = messageId;
            _readReceiptsController.add(_readReceipts);
          }
        } else if (data['type'] == 'PresenceUpdate') {
          final payload = data['payload'];
          final String uId = payload['user_id'];
          final bool isOnline = payload['is_online'];
          _onlineUsers[uId] = isOnline;
          _onlineUsersController.add(_onlineUsers);
        } else if (data['type'] == 'WebRtcSignal') {
          _incomingSignalController.add(data['payload'] as Map<String, dynamic>);
        } else if (data['type'] == 'MessageEdited') {
          final payload = data['payload'];
          final index = _messages.indexWhere((m) => m.id == payload['message_id']);
          if (index != -1) {
             _messages[index].content = payload['new_content'];
             _messages[index].isEdited = true;
             _messagesController.add(List.from(_messages));
          }
        } else if (data['type'] == 'MessageDeleted') {
          final payload = data['payload'];
          final index = _messages.indexWhere((m) => m.id == payload['message_id']);
          if (index != -1) {
             _messages[index].content = 'This message was deleted';
             _messages[index].isDeleted = true;
             _messages[index].msgType = MessageType.System;
             _messagesController.add(List.from(_messages));
          }
        } else if (data['type'] == 'ReactionAdded') {
          final payload = data['payload'];
          final index = _messages.indexWhere((m) => m.id == payload['message_id']);
          if (index != -1) {
             final emoji = payload['emoji'];
             final uId = payload['user_id'];
             if (!(_messages[index].reactions[emoji]?.contains(uId) ?? false)) {
               _messages[index].reactions.putIfAbsent(emoji, () => []).add(uId);
               _messagesController.add(List.from(_messages));
             }
          }
        } else if (data['type'] == 'ReactionRemoved') {
          final payload = data['payload'];
          final index = _messages.indexWhere((m) => m.id == payload['message_id']);
          if (index != -1) {
             final emoji = payload['emoji'];
             final uId = payload['user_id'];
             _messages[index].reactions[emoji]?.remove(uId);
             if (_messages[index].reactions[emoji]?.isEmpty == true) {
               _messages[index].reactions.remove(emoji);
             }
             _messagesController.add(List.from(_messages));
          }
        }
      }, onDone: () {
        if (_intentionalClose) {
          _statusController.add('Disconnected');
          return;
        }
        // Exponential backoff: 1s, 2s, 4s, 8s, 16s, 30s cap
        _statusController.add('Reconnecting...');
        final delay = Duration(
          milliseconds: (_maxReconnectDelay < (1000 * (1 << _reconnectAttempt)))
              ? _maxReconnectDelay
              : 1000 * (1 << _reconnectAttempt),
        );
        _reconnectAttempt++;
        print('[Vola] Reconnecting in ${delay.inMilliseconds}ms (attempt $_reconnectAttempt)');
        Future.delayed(delay, _connectWebSocket);
      }, onError: (e) {
        _statusController.add('Reconnecting...');
      });
      
    } catch (e) {
      _statusController.add('Reconnecting...');
      final delay = Duration(
        milliseconds: (_maxReconnectDelay < (1000 * (1 << _reconnectAttempt)))
            ? _maxReconnectDelay
            : 1000 * (1 << _reconnectAttempt),
      );
      _reconnectAttempt++;
      Future.delayed(delay, _connectWebSocket);
    }
  }

  void sendMessage(String content, [MessageType type = MessageType.Text, String? replyToId]) {
    if (content.trim().isEmpty || _channel == null) return;
    
    final newMsg = ChatMessage(
        id: Random().nextInt(999999).toString(),
        senderId: userId ?? 'me',
        chatRoomId: activeRoomId,
        content: content,
        msgType: type,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        replyToMessageId: replyToId,
    );

    _sentIds.add(newMsg.id);
    _messages.add(newMsg);
    _messagesController.add(List.from(_messages));

    _channel!.sink.add(jsonEncode({
      "type": "PublishMessage",
      "payload": newMsg.toJson(),
    }));
  }

  void editMessage(String messageId, String newContent) {
    _channel?.sink.add(jsonEncode({"type": "EditMessage", "payload": {"message_id": messageId, "new_content": newContent}}));
  }

  void deleteMessage(String messageId) {
    _channel?.sink.add(jsonEncode({"type": "DeleteMessage", "payload": {"message_id": messageId}}));
  }

  void addReaction(String messageId, String emoji) {
    _channel?.sink.add(jsonEncode({"type": "AddReaction", "payload": {"message_id": messageId, "emoji": emoji}}));
  }

  void removeReaction(String messageId, String emoji) {
    _channel?.sink.add(jsonEncode({"type": "RemoveReaction", "payload": {"message_id": messageId, "emoji": emoji}}));
  }

  Future<void> uploadImage(String filePath) async {
    try {
      var request = http.MultipartRequest('POST', Uri.parse('$baseUrl/api/upload'));
      request.files.add(await http.MultipartFile.fromPath('file', filePath));
      var res = await request.send();
      if (res.statusCode == 200) {
        var respStr = await res.stream.bytesToString();
        var data = jsonDecode(respStr);
        if (data['hash'] != null && data['hd_url'] != null) {
          // Replace 127.0.0.1 with 10.0.2.2 for Android emulator URL rewriting
          String urlStr = data['hd_url'];
          urlStr = urlStr.replaceAll('127.0.0.1', '10.0.2.2');
          data['hd_url'] = urlStr;
          sendMessage(jsonEncode(data), MessageType.ImageBlurHash);
        }
      }
    } catch (e) {
      print('Failed to upload image $e');
    }
  }

  void emitTyping() {
    if (_channel != null) {
      _channel!.sink.add(jsonEncode({
        "type": "Typing",
        "payload": {"chat_room_id": activeRoomId, "is_typing": true}
      }));
      
      _typingTimer?.cancel();
      _typingTimer = Timer(Duration(milliseconds: 1500), () {
         _channel!.sink.add(jsonEncode({
          "type": "Typing",
          "payload": {"chat_room_id": activeRoomId, "is_typing": false}
        }));
      });
    }
  }

  void markRead(String messageId) {
    if (_channel == null) return;
    _channel!.sink.add(jsonEncode({
      'type': 'MarkRead',
      'payload': {'chat_room_id': activeRoomId, 'message_id': messageId},
    }));
    // Optimistically update local receipt for self
    if (userId != null) {
      _readReceipts[userId!] = messageId;
      _readReceiptsController.add(_readReceipts);
    }
  }

  void sendSignal(String targetUserId, Map<String, dynamic> payload) {
    if (_channel == null) return;
    _channel!.sink.add(jsonEncode({
      'type': 'WebRtcSignal',
      'payload': {
        'target_user_id': targetUserId,
        'signal_payload': payload,
      },
    }));
  }

  // ─── Profile API Methods ────────────────────────────────────────────────────

  Future<void> fetchProfile(String targetId) async {
    try {
      final res = await http.get(Uri.parse('$baseUrl/api/users/$targetId'));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final profile = UserProfile.fromJson(data);
        _userProfiles[targetId] = profile;
        _userProfilesController.add(_userProfiles);
      }
    } catch (e) {
      print('Failed to fetch profile: $e');
    }
  }

  Future<void> updateProfile({String? displayName, String? bio}) async {
    if (token == null) return;
    try {
      final body = <String, dynamic>{};
      if (displayName != null) body['display_name'] = displayName;
      if (bio != null) body['bio'] = bio;

      final res = await http.patch(
        Uri.parse('$baseUrl/api/users/me'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode(body),
      );
      if (res.statusCode == 200 && userId != null) {
        final data = jsonDecode(res.body);
        _userProfiles[userId!] = UserProfile.fromJson(data);
        _userProfilesController.add(_userProfiles);
      }
    } catch (e) {
      print('Failed to update profile: $e');
    }
  }

  Future<void> uploadAvatar(File imageFile) async {
    if (token == null || userId == null) return;
    try {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$baseUrl/api/users/me/avatar'),
      );
      request.headers['Authorization'] = 'Bearer $token';
      request.files.add(await http.MultipartFile.fromPath('avatar', imageFile.path));

      final streamed = await request.send();
      if (streamed.statusCode == 200) {
        final body = await streamed.stream.bytesToString();
        final data = jsonDecode(body);
        final avatarUrl = data['avatar_url'] as String?;
        if (avatarUrl != null) {
          // Rewrite for emulator
          final fixedUrl = avatarUrl.replaceAll('127.0.0.1', '10.0.2.2');
          final existing = _userProfiles[userId!];
          _userProfiles[userId!] = UserProfile(
            id: userId!,
            username: existing?.username ?? '',
            displayName: existing?.displayName,
            avatarUrl: fixedUrl,
            bio: existing?.bio,
            lastSeen: existing?.lastSeen,
          );
          _userProfilesController.add(_userProfiles);
        }
      }
    } catch (e) {
      print('Failed to upload avatar: $e');
    }
  }

  void dispose() {
    _intentionalClose = true;
    _channel?.sink.close();
    _messagesController.close();
    _typingController.close();
    _roomsController.close();
    _statusController.close();
    _authController.close();
    _readReceiptsController.close();
    _roomLastMessagesController.close();
    _onlineUsersController.close();
    _incomingSignalController.close();
    _userProfilesController.close();
  }
}
