import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'dart:async';
import 'dart:math';

enum MessageType { Text, ImageBlurHash, System }

class ChatRoom {
  final String id;
  final String name;

  ChatRoom({required this.id, required this.name});

  factory ChatRoom.fromJson(Map<String, dynamic> json) {
    return ChatRoom(id: json['id'], name: json['name']);
  }
}

class ChatMessage {
  final String id;
  final String senderId;
  final String chatRoomId;
  final String content;
  final MessageType msgType;
  final int timestamp;

  ChatMessage({
    required this.id,
    required this.senderId,
    required this.chatRoomId,
    required this.content,
    required this.msgType,
    required this.timestamp,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
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
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'sender_id': senderId,
        'chat_room_id': chatRoomId,
        'content': content,
        'msg_type': msgType.toString().split('.').last,
        'timestamp': timestamp,
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
  
  List<ChatMessage> _messages = [];
  List<String> _typingUsers = [];
  List<ChatRoom> _rooms = [];
  Set<String> _sentIds = {};
  Map<String, String> _readReceipts = {}; // userId -> messageId
  Map<String, ChatMessage> _roomLastMessages = {};
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
  Map<String, String> get readReceipts => Map.unmodifiable(_readReceipts);

  Timer? _typingTimer;

  Future<void> initialize() async {
    _fetchRooms();

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

  void sendMessage(String content, [MessageType type = MessageType.Text]) {
    if (content.trim().isEmpty || _channel == null) return;
    
    final newMsg = ChatMessage(
        id: Random().nextInt(999999).toString(),
        senderId: userId ?? 'me',
        chatRoomId: activeRoomId,
        content: content,
        msgType: type,
        timestamp: DateTime.now().millisecondsSinceEpoch,
    );

    _sentIds.add(newMsg.id);
    _messages.add(newMsg);
    _messagesController.add(_messages);

    _channel!.sink.add(jsonEncode({
      "type": "PublishMessage",
      "payload": newMsg.toJson(),
    }));
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
  }
}
