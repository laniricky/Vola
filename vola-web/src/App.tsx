import React, { useState, useEffect, useRef } from 'react';
import { Briefcase, Gamepad2, User, Send, Mic, Paperclip, MoreVertical, Search, Check, Image as ImageIcon, LogOut, Plus, Users } from 'lucide-react';
import { Blurhash } from 'react-blurhash';
import './index.css';
import { useVola } from './engine/useVola';

function ImageBubble({ content }: { content: string }) {
  let hash = content;
  let hdUrl = '';
  try {
    const data = JSON.parse(content);
    hash = data.hash || content;
    hdUrl = data.hd_url || '';
  } catch (e) {
    // Fallback: assume plain hash content
  }

  const [loaded, setLoaded] = useState(false);

  return (
    <div style={{ position: 'relative', borderRadius: 8, overflow: 'hidden', width: 250, height: 250, marginBottom: 4 }}>
      <Blurhash
        hash={hash}
        width={250}
        height={250}
        resolutionX={32}
        resolutionY={32}
        punch={1}
      />
      {hdUrl && (
        <img 
          src={hdUrl} 
          alt="Upload"
          onLoad={() => setLoaded(true)}
          style={{
            position: 'absolute',
            top: 0, 
            left: 0, 
            width: '100%', 
            height: '100%', 
            objectFit: 'cover',
            opacity: loaded ? 1 : 0,
            transition: 'opacity 0.4s ease-in-out'
          }}
        />
      )}
    </div>
  );
}

function AuthScreen({ onAuthSuccess }: { onAuthSuccess: (token: string, userId: string) => void }) {
  const [isLogin, setIsLogin] = useState(true);
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');
    try {
      const endpoint = isLogin ? '/api/login' : '/api/register';
      const res = await fetch(`http://127.0.0.1:3000${endpoint}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username, password })
      });
      const data = await res.json();
      if (!res.ok) {
        throw new Error(data || 'Authentication failed');
      }
      onAuthSuccess(data.token, data.id);
    } catch (err: any) {
      setError(err.message || 'An error occurred');
    }
  };

  return (
    <div style={{ height: '100vh', display: 'flex', alignItems: 'center', justifyContent: 'center', backgroundColor: '#0f172a' }}>
      <div style={{ width: 360, padding: 32, backgroundColor: '#1e293b', borderRadius: 16, boxShadow: '0 10px 25px rgba(0,0,0,0.5)' }}>
        <h2 style={{ textAlign: 'center', marginBottom: 24, fontSize: 24, fontWeight: 'bold' }}>
          {isLogin ? 'Welcome Back' : 'Create Account'}
        </h2>
        {error && <div style={{ color: '#ef4444', marginBottom: 16, fontSize: 14, textAlign: 'center' }}>{error}</div>}
        <form onSubmit={handleSubmit} style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
          <input
            type="text"
            placeholder="Username"
            value={username}
            onChange={e => setUsername(e.target.value)}
            style={{ padding: '12px 16px', borderRadius: 8, backgroundColor: '#0f172a', border: '1px solid #334155', color: '#fff', fontSize: 15 }}
            required
          />
          <input
            type="password"
            placeholder="Password"
            value={password}
            onChange={e => setPassword(e.target.value)}
            style={{ padding: '12px 16px', borderRadius: 8, backgroundColor: '#0f172a', border: '1px solid #334155', color: '#fff', fontSize: 15 }}
            required
            minLength={4}
          />
          <button
            type="submit"
            style={{ padding: 14, borderRadius: 8, backgroundColor: 'var(--accent-color)', color: '#fff', fontWeight: 'bold', border: 'none', cursor: 'pointer', marginTop: 8 }}
          >
            {isLogin ? 'Login' : 'Register'}
          </button>
        </form>
        <div style={{ textAlign: 'center', marginTop: 20, fontSize: 14, color: '#94a3b8' }}>
          {isLogin ? "Don't have an account? " : "Already have an account? "}
          <span
            style={{ color: 'var(--accent-color)', cursor: 'pointer', fontWeight: 500 }}
            onClick={() => setIsLogin(!isLogin)}
          >
            {isLogin ? 'Register' : 'Login'}
          </span>
        </div>
      </div>
    </div>
  );
}

export default function App() {
  const [activePersona, setActivePersona] = useState('work');
  const [inputText, setInputText] = useState('');
  const [showCreateRoom, setShowCreateRoom] = useState(false);
  const [newRoomName, setNewRoomName] = useState('');
  const [showMembers, setShowMembers] = useState(true);
  const [members, setMembers] = useState<any[]>([]);
  const messagesEndRef = useRef<HTMLDivElement>(null);

  const {
    userId,
    token,
    setToken,
    setUserId,
    logout,
    socketStatus,
    rooms,
    activeRoomId,
    setActiveRoomId,
    messages,
    typingUsers,
    sendMessage,
    emitTyping,
    stopTyping,
    uploadImage,
    createRoom,
    createDM,
    markRead,
    readReceipts,
    setReadReceipts,
    loadMoreMessages,
    hasMoreMessages,
    isLoadingMore,
    roomLastMessages,
  } = useVola();

  useEffect(() => {
    if (activeRoomId) {
      fetch(`http://127.0.0.1:3000/api/rooms/${activeRoomId}/members`)
        .then(res => res.json())
        .then(data => {
          setMembers(data);
          // Seed readReceipts watermarks from the initial members snapshot
          const seeds: Record<string, string> = {};
          data.forEach((m: any) => {
            if (m.last_read_message_id) seeds[m.id] = m.last_read_message_id;
          });
          setReadReceipts(seeds);
        })
        .catch(console.error);
    }
  }, [activeRoomId]);

  // Auto-fire markRead when newest message scrolls into view
  const lastMsgRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!lastMsgRef.current || messages.length === 0) return;
    const obs = new IntersectionObserver(([entry]) => {
      if (entry.isIntersecting) {
        const lastMsg = messages[messages.length - 1];
        markRead(lastMsg.id);
      }
    }, { threshold: 1.0 });
    obs.observe(lastMsgRef.current);
    return () => obs.disconnect();
  }, [messages, markRead]);

  // Infinite scroll — load older messages when top sentinel becomes visible
  const topSentinelRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!topSentinelRef.current) return;
    const obs = new IntersectionObserver(([entry]) => {
      if (entry.isIntersecting) loadMoreMessages();
    }, { threshold: 1.0 });
    obs.observe(topSentinelRef.current);
    return () => obs.disconnect();
  }, [loadMoreMessages]);

  const handleCreateRoom = async () => {
    if (newRoomName.trim()) {
      await createRoom(newRoomName);
      setNewRoomName('');
      setShowCreateRoom(false);
    }
  };

  const scrollToBottom = () => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  };

  useEffect(() => {
    scrollToBottom();
  }, [messages]);

  const handleSendText = () => {
    sendMessage(inputText, 'Text');
    setInputText('');
    stopTyping();
  };

  if (!token) {
    return <AuthScreen onAuthSuccess={(t, id) => {
      localStorage.setItem('vola_token', t);
      localStorage.setItem('vola_user_id', id);
      setToken(t);
      setUserId(id);
    }} />
  }

  return (
    <div className="app-container">
      <div className="sidebar-personas">
        <div style={{ width: 44, height: 44, borderRadius: 22, background: 'var(--accent-gradient)', marginBottom: 20 }}></div>
        
        <div className={`persona-icon ${activePersona === 'work' ? 'active' : ''}`} onClick={() => setActivePersona('work')}>
          <Briefcase size={22} />
        </div>
        <div className={`persona-icon ${activePersona === 'social' ? 'active' : ''}`} onClick={() => setActivePersona('social')}>
          <User size={22} />
        </div>
        <div className={`persona-icon ${activePersona === 'gaming' ? 'active' : ''}`} onClick={() => setActivePersona('gaming')}>
          <Gamepad2 size={22} />
        </div>

        <div style={{ flex: 1 }} />
        <div className="persona-icon" onClick={logout} title="Log Out">
          <LogOut size={22} />
        </div>
      </div>

      <div className="sidebar-chats">
        <div className="chats-header" style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <div style={{ position: 'relative', flex: 1 }}>
            <Search size={16} color="var(--text-secondary)" style={{ position: 'absolute', left: 12, top: 11 }} />
            <input type="text" className="search-bar" placeholder="Search" style={{ paddingLeft: 38 }} />
          </div>
          <div 
            style={{ width: 32, height: 32, borderRadius: '50%', backgroundColor: '#1e293b', display: 'flex', alignItems: 'center', justifyContent: 'center', cursor: 'pointer' }}
            onClick={() => setShowCreateRoom(true)}
            title="Create Room"
          >
            <Plus size={18} color="var(--text-secondary)" />
          </div>
        </div>
        <div className="chat-list">
          {rooms.map(room => {
            const lastMsg = roomLastMessages[room.id];
            const isDM = room.id.startsWith('dm_');
            return (
              <div 
                key={room.id} 
                className={`chat-item ${room.id === activeRoomId ? 'active' : ''}`}
                onClick={() => setActiveRoomId(room.id)}
              >
                <div className="avatar" style={{ backgroundColor: isDM ? '#4f46e5' : '#334155', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                  {isDM ? <User size={20} color="#fff" /> : <Users size={20} color="#fff" />}
                </div>
                <div className="chat-preview">
                  <div className="chat-name">{room.name}</div>
                  <div className="chat-last-msg">
                    {lastMsg 
                      ? (lastMsg.msg_type === 'ImageBlurHash' ? '📷 Image' : lastMsg.content)
                      : 'Tap to view chat...'}
                  </div>
                </div>
              </div>
            );
          })}
        </div>
      </div>

      <div className="chat-area">
        {socketStatus === 'Reconnecting' && (
          <div className="reconnect-banner">
            Reconnecting to server...
          </div>
        )}
        <div className="chat-header">
          <div>
            <h3 style={{ fontSize: 16, fontWeight: 600 }}>{rooms.find(r => r.id === activeRoomId)?.name || 'Loading...'}</h3>
            <span style={{ fontSize: 13, color: 'var(--text-secondary)' }}>
              {typingUsers.length > 0 
                ? <span style={{ color: 'var(--accent-color)', fontStyle: 'italic', animation: 'pulse 1.5s infinite' }}>{typingUsers.length > 1 ? 'Several people are typing...' : 'Someone is typing...'}</span> 
                : socketStatus === 'Connected' ? '🟢 Online — Live broadcast active' 
                : socketStatus === 'Reconnecting' ? '🟡 Reconnecting...' 
                : '🔴 Disconnected'}
            </span>
          </div>
          <div style={{ marginLeft: 'auto', display: 'flex', gap: 20, color: 'var(--text-secondary)' }}>
            <Search size={20} cursor="pointer" />
            <Users size={20} cursor="pointer" onClick={() => setShowMembers(!showMembers)} color={showMembers ? 'var(--accent-color)' : 'var(--text-secondary)'} />
            <MoreVertical size={20} cursor="pointer" />
          </div>
        </div>

        <div className="chat-messages">
          {/* ── Infinite Scroll Top Sentinel ─────────────── */}
          <div ref={topSentinelRef} style={{ height: 1 }} />
          {isLoadingMore && (
            <div style={{ textAlign: 'center', padding: '12px 0', color: 'var(--text-secondary)', fontSize: 13 }}>
              Loading older messages...
            </div>
          )}
          {!hasMoreMessages && messages.length > 0 && (
            <div style={{ textAlign: 'center', padding: '12px 0', color: 'var(--text-secondary)', fontSize: 12, opacity: 0.5 }}>
              ─── Beginning of conversation ───
            </div>
          )}
          {messages.map((msg, idx) => {
            const isMe = msg.sender_id === (userId || 'me');
            // Check if ANY other user has read at least this message
            const isRead = isMe && Object.entries(readReceipts).some(([uid, msgId]) => {
              if (uid === userId) return false;
              // Find all messages; if another user's watermark is at or after this one in chat_room order
              const watermarkIdx = messages.findIndex(m => m.id === msgId);
              return watermarkIdx >= idx;
            });
            const isLastMsg = idx === messages.length - 1;
            return (
              <div key={msg.id} className={`message ${isMe ? 'sent' : 'received'}`} ref={isLastMsg ? lastMsgRef : undefined}>
                {msg.msg_type === 'ImageBlurHash' ? (
                  <ImageBubble content={msg.content} />
                ) : (
                  msg.content
                )}
                
                <div style={{ fontSize: 11, color: 'rgba(255,255,255,0.7)', marginTop: 6, display: 'flex', alignItems: 'center', justifyContent: 'flex-end', gap: 4 }}>
                  {new Date(msg.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
                  {isMe && (
                    <span style={{ display: 'flex', color: isRead ? 'var(--accent-color)' : 'rgba(255,255,255,0.5)' }}>
                      <Check size={14} />
                      {isRead && <Check size={14} style={{ marginLeft: -8 }} />}
                    </span>
                  )}
                </div>
              </div>
            );
          })}
          <div ref={messagesEndRef} />
        </div>

        <div className="chat-input-area">
          <Paperclip size={22} color="var(--text-secondary)" cursor="pointer" />
          <input 
            type="file" 
            id="file-upload" 
            style={{ display: 'none' }} 
            onChange={(e) => {
              if (e.target.files && e.target.files[0]) {
                uploadImage(e.target.files[0]);
              }
            }}
          />
          <CameraIconLabel />
          
          <input 
            type="text" 
            className="message-input" 
            placeholder="Write a message..." 
            value={inputText}
            onChange={(e) => {
              setInputText(e.target.value);
              emitTyping();
            }}
            onKeyDown={(e) => e.key === 'Enter' && handleSendText()}
          />
          {inputText ? (
            <div className="send-btn" onClick={handleSendText}>
              <Send size={18} color="#fff" />
            </div>
          ) : (
            <Mic size={22} color="var(--text-secondary)" cursor="pointer" />
          )}
        </div>
      </div>

      {showMembers && (
        <div style={{ width: 260, backgroundColor: '#0f172a', borderLeft: '1px solid #1e293b', display: 'flex', flexDirection: 'column' }}>
          <div style={{ padding: 20, borderBottom: '1px solid #1e293b', fontWeight: 'bold' }}>Room Members</div>
          <div style={{ flex: 1, padding: 10, overflowY: 'auto' }}>
            {members.map(m => (
              <div 
                key={m.id} 
                style={{ display: 'flex', alignItems: 'center', gap: 12, padding: 10, borderRadius: 8, cursor: m.id === userId ? 'default' : 'pointer', opacity: m.id === userId ? 0.6 : 1 }} 
                className="member-item"
                onClick={() => {
                  if (m.id !== userId) createDM(m.id);
                }}
              >
                <div style={{ width: 36, height: 36, borderRadius: 18, backgroundColor: '#334155', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                  {m.display_name?.charAt(0) || m.username.charAt(0)}
                </div>
                <div style={{ flex: 1 }}>
                  <div style={{ fontSize: 14, fontWeight: 500 }}>{m.display_name || m.username} {m.id === userId && '(You)'}</div>
                  <div style={{ fontSize: 12, color: 'var(--text-secondary)' }}>@{m.username}</div>
                </div>
              </div>
            ))}
            {members.length === 0 && <div style={{ padding: 10, color: 'var(--text-secondary)', fontSize: 13 }}>No active members mapping found.</div>}
          </div>
        </div>
      )}

      {showCreateRoom && (
        <div style={{ position: 'fixed', top: 0, left: 0, right: 0, bottom: 0, backgroundColor: 'rgba(0,0,0,0.5)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 1000 }}>
          <div style={{ width: 320, backgroundColor: '#1e293b', borderRadius: 12, padding: 24 }}>
            <h3 style={{ marginTop: 0, marginBottom: 20 }}>Create New Room</h3>
            <input 
              type="text" 
              placeholder="Room Name" 
              value={newRoomName}
              onChange={e => setNewRoomName(e.target.value)}
              style={{ width: '100%', padding: '10px 14px', borderRadius: 8, border: '1px solid #334155', backgroundColor: '#0f172a', color: '#fff', marginBottom: 20, boxSizing: 'border-box' }}
              autoFocus
            />
            <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 12 }}>
              <button 
                onClick={() => setShowCreateRoom(false)}
                style={{ padding: '8px 16px', borderRadius: 6, border: 'none', backgroundColor: '#334155', color: '#fff', cursor: 'pointer' }}
              >
                Cancel
              </button>
              <button 
                onClick={handleCreateRoom}
                style={{ padding: '8px 16px', borderRadius: 6, border: 'none', backgroundColor: 'var(--accent-color)', color: '#fff', cursor: 'pointer', fontWeight: 'bold' }}
              >
                Create
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

function CameraIconLabel() {
  return (
    <label htmlFor="file-upload" style={{ cursor: 'pointer', display: 'flex', alignItems: 'center' }}>
      <ImageIcon size={22} color="var(--text-secondary)" />
    </label>
  );
}
