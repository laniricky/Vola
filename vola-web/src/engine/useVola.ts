import { useState, useEffect, useRef, useCallback } from 'react';

export type MessageType = 'Text' | 'ImageBlurHash' | 'System';

export interface ChatMessage {
  id: string;
  sender_id: string;
  chat_room_id: string;
  content: string;
  msg_type: MessageType;
  timestamp: number;
  reply_to_message_id?: string | null;
  is_edited?: boolean;
  is_deleted?: boolean;
  reactions?: Record<string, string[]>; // { emoji: [user_id, ...] }
}

export interface UserProfile {
  id: string;
  username: string;
  display_name?: string | null;
  avatar_url?: string | null;
  bio?: string | null;
  last_seen?: number | null;
}

export interface ChatRoom {
  id: string;
  name: string;
}

const API_BASE = 'http://127.0.0.1:3000';
const WS_URL = 'ws://127.0.0.1:3000/ws';
const MAX_RECONNECT_DELAY = 30000; // 30 seconds cap

export function useVola() {
  const [userId, setUserId] = useState<string | null>(localStorage.getItem('vola_user_id'));
  const [token, setToken] = useState<string | null>(localStorage.getItem('vola_token'));
  
  const [socketStatus, setSocketStatus] = useState<'Connected' | 'Disconnected' | 'Reconnecting'>('Disconnected');
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [typingUsers, setTypingUsers] = useState<string[]>([]);
  const [readReceipts, setReadReceipts] = useState<Record<string, string>>({}); // user_id -> message_id
  const [onlineUsers, setOnlineUsers] = useState<Record<string, boolean>>({});
  const [incomingSignal, setIncomingSignal] = useState<any>(null);
  const [hasMoreMessages, setHasMoreMessages] = useState(false);
  const [isLoadingMore, setIsLoadingMore] = useState(false);
  const [roomLastMessages, setRoomLastMessages] = useState<Record<string, ChatMessage>>({});
  
  const [userProfiles, setUserProfiles] = useState<Record<string, UserProfile>>({});

  const [rooms, setRooms] = useState<ChatRoom[]>([]);
  const [activeRoomId, setActiveRoomId] = useState<string>('room_1');
  
  const ws = useRef<WebSocket | null>(null);
  const sentIds = useRef<Set<string>>(new Set());
  const typingTimeoutRef = useRef<NodeJS.Timeout | null>(null);
  const reconnectAttempt = useRef(0);
  const reconnectTimer = useRef<NodeJS.Timeout | null>(null);
  const activeRoomRef = useRef(activeRoomId);
  const intentionalClose = useRef(false);

  // Keep ref in sync with state so socket callbacks see latest value
  useEffect(() => {
    activeRoomRef.current = activeRoomId;
  }, [activeRoomId]);

  // 1. Fetch Rooms (one-time)
  const fetchRooms = useCallback(async () => {
    try {
      const res = await fetch(`${API_BASE}/api/rooms`);
      const data = await res.json();
      if (data && Array.isArray(data)) setRooms(data);
    } catch (err) {
      console.error(err);
    }
  }, []);

  const fetchOnlineUsers = useCallback(async () => {
    try {
      const res = await fetch(`${API_BASE}/api/users/online`);
      const data: string[] = await res.json();
      if (data && Array.isArray(data)) {
        const map: Record<string, boolean> = {};
        data.forEach(id => { map[id] = true; });
        setOnlineUsers(map);
      }
    } catch (err) {
      console.error(err);
    }
  }, []);

  useEffect(() => {
    fetchRooms();
    fetchOnlineUsers();
  }, [fetchRooms, fetchOnlineUsers]); // Run once on mount

  // 2. WebSocket Connection with Exponential Backoff Reconnect
  // Decoupled from activeRoomId — the socket lives independently.
  useEffect(() => {
    if (!token) return;

    function connect() {
      if (ws.current && ws.current.readyState === WebSocket.OPEN) return;
      
      intentionalClose.current = false;
      const socket = new WebSocket(WS_URL);
      
      socket.onopen = () => {
        setSocketStatus('Connected');
        reconnectAttempt.current = 0; // Reset backoff on success
        ws.current = socket;
        socket.send(JSON.stringify({ type: "Authenticate", payload: { token } }));
      };

      socket.onmessage = (event) => {
        try {
          const data = JSON.parse(event.data);
          if (data.type === 'NewMessage') {
            const incoming: ChatMessage = data.payload;
            if (sentIds.current.has(incoming.id)) return;
            
            // Always update the per-room last message snapshot (for sidebar previews)
            setRoomLastMessages(prev => ({ ...prev, [incoming.chat_room_id]: incoming }));

            setMessages(prev => {
                if (incoming.chat_room_id === activeRoomRef.current) {
                    return [...prev, incoming];
                }
                return prev;
            });
          } else if (data.type === 'UserTyping') {
            const { user_id, chat_room_id, is_typing } = data.payload;
            if (chat_room_id === activeRoomRef.current) {
                setTypingUsers(prev => {
                   if (is_typing) return prev.includes(user_id) ? prev : [...prev, user_id];
                   return prev.filter(id => id !== user_id);
                });
            }
          } else if (data.type === 'MessageRead') {
            const { chat_room_id, user_id, message_id } = data.payload;
            if (chat_room_id === activeRoomRef.current) {
                setReadReceipts(prev => ({...prev, [user_id]: message_id}));
            }
          } else if (data.type === 'PresenceUpdate') {
             const { user_id, is_online } = data.payload;
             setOnlineUsers(prev => ({ ...prev, [user_id]: is_online }));
          } else if (data.type === 'WebRtcSignal') {
             setIncomingSignal(data.payload);
          } else if (data.type === 'MessageEdited') {
             setMessages(prev => prev.map(m => m.id === data.payload.message_id ? { ...m, content: data.payload.new_content, is_edited: true } : m));
          } else if (data.type === 'MessageDeleted') {
             setMessages(prev => prev.map(m => m.id === data.payload.message_id ? { ...m, content: 'This message was deleted', is_deleted: true, msg_type: 'System' } : m));
          } else if (data.type === 'ReactionAdded') {
             const { message_id, emoji, user_id } = data.payload;
             setMessages(prev => prev.map(m => {
               if (m.id !== message_id) return m;
               const newRx = { ...(m.reactions || {}) };
               const users = [...(newRx[emoji] || [])];
               if (!users.includes(user_id)) users.push(user_id);
               newRx[emoji] = users;
               return { ...m, reactions: newRx };
             }));
          } else if (data.type === 'ReactionRemoved') {
             const { message_id, emoji, user_id } = data.payload;
             setMessages(prev => prev.map(m => {
               if (m.id !== message_id) return m;
               const newRx = { ...(m.reactions || {}) };
               if (newRx[emoji]) {
                 newRx[emoji] = newRx[emoji].filter((id: string) => id !== user_id);
                 if (newRx[emoji].length === 0) delete newRx[emoji];
               }
               return { ...m, reactions: newRx };
             }));
          }
        } catch (err) {
          console.error('Socket parse error:', err);
        }
      };

      socket.onclose = () => {
        ws.current = null;
        if (intentionalClose.current) {
          setSocketStatus('Disconnected');
          return;
        }
        // Exponential backoff: 1s, 2s, 4s, 8s, 16s, 30s cap
        setSocketStatus('Reconnecting');
        const delay = Math.min(1000 * Math.pow(2, reconnectAttempt.current), MAX_RECONNECT_DELAY);
        reconnectAttempt.current += 1;
        console.log(`[Vola] Reconnecting in ${delay}ms (attempt ${reconnectAttempt.current})`);
        reconnectTimer.current = setTimeout(connect, delay);
      };

      socket.onerror = () => {
        // onclose will fire after this, which handles reconnect
        socket.close();
      };
    }

    connect();

    return () => {
      intentionalClose.current = true;
      if (reconnectTimer.current) clearTimeout(reconnectTimer.current);
      if (ws.current && ws.current.readyState === WebSocket.OPEN) ws.current.close();
    };
  }, [token]);

  // 3. Fetch History on Room Switch (decoupled from socket lifecycle)
  useEffect(() => {
     setMessages([]);
     setTypingUsers([]);
     setHasMoreMessages(false);
     setReadReceipts({}); // Reset when switching rooms
     fetch(`${API_BASE}/api/messages/${activeRoomId}?limit=50`)
         .then(res => res.json())
         .then((data: ChatMessage[]) => {
            if (data && Array.isArray(data)) {
               setMessages(data);
               setHasMoreMessages(data.length === 50);
               data.forEach((m: ChatMessage) => sentIds.current.add(m.id));
               // Seed last-message preview for this room
               if (data.length > 0) {
                 setRoomLastMessages(prev => ({ ...prev, [activeRoomId]: data[data.length - 1] }));
               }
            }
         })
         .catch(console.error);
  }, [activeRoomId]);

  // Load older messages (infinite scroll)
  const loadMoreMessages = useCallback(async () => {
    if (isLoadingMore || !hasMoreMessages || messages.length === 0) return;
    setIsLoadingMore(true);
    try {
      const oldestTs = messages[0].timestamp;
      const res = await fetch(`${API_BASE}/api/messages/${activeRoomId}?before=${oldestTs}&limit=50`);
      const older: ChatMessage[] = await res.json();
      if (older && older.length > 0) {
        older.forEach(m => sentIds.current.add(m.id));
        setMessages(prev => [...older, ...prev]);
        setHasMoreMessages(older.length === 50);
      } else {
        setHasMoreMessages(false);
      }
    } catch (e) {
      console.error('Failed to load older messages', e);
    } finally {
      setIsLoadingMore(false);
    }
  }, [isLoadingMore, hasMoreMessages, messages, activeRoomId]);

  const sendMessage = useCallback((content: string, type: MessageType = 'Text', replyToId?: string) => {
    if (!content.trim() || !ws.current || ws.current.readyState !== WebSocket.OPEN) return;
    const newMsg: ChatMessage = {
      id: Math.random().toString(36).substr(2, 9),
      sender_id: userId || 'me',
      chat_room_id: activeRoomId,
      content,
      msg_type: type,
      timestamp: Date.now(),
      reply_to_message_id: replyToId
    };
    
    sentIds.current.add(newMsg.id);
    setMessages(prev => [...prev, newMsg]);

    ws.current.send(JSON.stringify({
      type: "PublishMessage",
      payload: newMsg
    }));
  }, [userId, activeRoomId]);

  const editMessage = useCallback((messageId: string, newContent: string) => {
    if (!ws.current || ws.current.readyState !== WebSocket.OPEN) return;
    ws.current.send(JSON.stringify({ type: 'EditMessage', payload: { message_id: messageId, new_content: newContent } }));
  }, []);

  const deleteMessage = useCallback((messageId: string) => {
    if (!ws.current || ws.current.readyState !== WebSocket.OPEN) return;
    ws.current.send(JSON.stringify({ type: 'DeleteMessage', payload: { message_id: messageId } }));
  }, []);

  const addReaction = useCallback((messageId: string, emoji: string) => {
    if (!ws.current || ws.current.readyState !== WebSocket.OPEN) return;
    ws.current.send(JSON.stringify({ type: 'AddReaction', payload: { message_id: messageId, emoji } }));
  }, []);

  const removeReaction = useCallback((messageId: string, emoji: string) => {
    if (!ws.current || ws.current.readyState !== WebSocket.OPEN) return;
    ws.current.send(JSON.stringify({ type: 'RemoveReaction', payload: { message_id: messageId, emoji } }));
  }, []);

  const emitTyping = useCallback(() => {
     if (ws.current && ws.current.readyState === WebSocket.OPEN) {
       ws.current.send(JSON.stringify({ type: 'Typing', payload: { chat_room_id: activeRoomId, is_typing: true } }));
       
       if (typingTimeoutRef.current) clearTimeout(typingTimeoutRef.current);
       typingTimeoutRef.current = setTimeout(() => {
         if (ws.current && ws.current.readyState === WebSocket.OPEN) {
           ws.current.send(JSON.stringify({ type: 'Typing', payload: { chat_room_id: activeRoomId, is_typing: false } }));
         }
       }, 1500);
     }
  }, [activeRoomId]);

  const stopTyping = useCallback(() => {
     if (ws.current && ws.current.readyState === WebSocket.OPEN) {
       ws.current.send(JSON.stringify({ type: 'Typing', payload: { chat_room_id: activeRoomId, is_typing: false } }));
     }
  }, [activeRoomId]);

  const markRead = useCallback((messageId: string) => {
      if (ws.current && ws.current.readyState === WebSocket.OPEN) {
          ws.current.send(JSON.stringify({ type: 'MarkRead', payload: { chat_room_id: activeRoomId, message_id: messageId } }));
      }
  }, [activeRoomId]);

  const sendSignal = useCallback((targetUserId: string, payload: any) => {
      if (ws.current && ws.current.readyState === WebSocket.OPEN) {
          ws.current.send(JSON.stringify({
              type: 'WebRtcSignal',
              payload: { target_user_id: targetUserId, signal_payload: payload }
          }));
      }
  }, []);

  const uploadImage = useCallback(async (file: File) => {
    const formData = new FormData();
    formData.append('file', file);
    try {
      const res = await fetch(`${API_BASE}/api/upload`, {
        method: 'POST',
        body: formData
      });
      const data = await res.json();
      if (data && data.hash && data.hd_url) {
        sendMessage(JSON.stringify(data), 'ImageBlurHash');
      }
    } catch (err) {
      console.error('Failed to upload image:', err);
    }
  }, [sendMessage]);

  const createRoom = useCallback(async (name: string) => {
      try {
          const res = await fetch(`${API_BASE}/api/rooms`, {
              method: 'POST',
              headers: {
                  'Content-Type': 'application/json',
                  'Authorization': `Bearer ${token}`
              },
              body: JSON.stringify({ name })
          });
          if (res.ok) {
              await fetchRooms();
          }
      } catch (e) {
          console.error("Failed to create room", e);
      }
  }, [token, fetchRooms]);

  const createDM = useCallback(async (targetUserId: string) => {
      try {
          const res = await fetch(`${API_BASE}/api/rooms/dm`, {
              method: 'POST',
              headers: {
                  'Content-Type': 'application/json',
                  'Authorization': `Bearer ${token}`
              },
              body: JSON.stringify({ target_user_id: targetUserId })
          });
          if (res.ok) {
              const data = await res.json();
              await fetchRooms();
              setActiveRoomId(data.id);
          }
      } catch (e) {
          console.error("Failed to create DM", e);
      }
  }, [token, fetchRooms]);

  const fetchProfile = useCallback(async (targetId: string) => {
    try {
      const res = await fetch(`${API_BASE}/api/users/${targetId}`);
      if (res.ok) {
        const data: UserProfile = await res.json();
        setUserProfiles(prev => ({ ...prev, [targetId]: data }));
      }
    } catch (e) {
      console.error("Failed to fetch user profile", e);
    }
  }, []);

  const updateProfile = useCallback(async (updates: { display_name?: string, bio?: string }) => {
    if (!token) return;
    try {
      const res = await fetch(`${API_BASE}/api/users/me`, {
        method: 'PATCH',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${token}`
        },
        body: JSON.stringify(updates)
      });
      if (res.ok) {
        const data: UserProfile = await res.json();
        setUserProfiles(prev => ({ ...prev, [data.id]: data }));
      }
    } catch (e) {
      console.error("Failed to update profile", e);
    }
  }, [token]);

  const uploadAvatar = useCallback(async (fileObj: File) => {
    if (!token) return;
    try {
        const formData = new FormData();
        formData.append('avatar', fileObj);
        const res = await fetch(`${API_BASE}/api/users/me/avatar`, {
            method: 'POST',
            headers: { 'Authorization': `Bearer ${token}` },
            body: formData
        });
        if (res.ok) {
           const { avatar_url } = await res.json();
           if (userId) {
              setUserProfiles(prev => ({
                 ...prev,
                 [userId]: { ...(prev[userId] || {} as UserProfile), avatar_url }
              }));
           }
        }
    } catch (e) {
        console.error("Avatar upload failed", e);
    }
  }, [token, userId]);

  const logout = useCallback(() => {
    localStorage.removeItem('vola_token');
    localStorage.removeItem('vola_user_id');
    setToken(null);
    setUserId(null);
    intentionalClose.current = true;
    if (ws.current) {
        ws.current.close();
    }
  }, []);

  return {
    userId,
    token, // added to check auth state externally
    setToken,
    setUserId,
    logout,
    socketStatus,
    rooms,
    activeRoomId,
    setActiveRoomId,
    messages,
    typingUsers,
    onlineUsers,
    sendMessage,
    emitTyping,
    stopTyping,
    markRead,
    readReceipts,
    setReadReceipts,
    uploadImage,
    createRoom,
    createDM,
    loadMoreMessages,
    hasMoreMessages,
    isLoadingMore,
    roomLastMessages,
    incomingSignal,
    sendSignal,
    editMessage,
    deleteMessage,
    addReaction,
    removeReaction,
    userProfiles,
    fetchProfile,
    updateProfile,
    uploadAvatar,
  };
}
