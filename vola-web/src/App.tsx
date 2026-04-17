import React, { useState, useEffect, useRef } from 'react';
import { Briefcase, Gamepad2, User, Send, Mic, MicOff, Paperclip, MoreVertical, Search, Check, Image as ImageIcon, LogOut, Plus, Users, Phone, Video, VideoOff, CornerUpLeft, Edit2, Trash2, Smile, X } from 'lucide-react';
import { Blurhash } from 'react-blurhash';
import './index.css';
import { useVola } from './engine/useVola';
import { useWebRTC } from './engine/useWebRTC';

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

function ProfileModal({ 
  userId, 
  onClose, 
  onUpdate, 
  onUploadAvatar,
  currentName,
  currentBio,
  currentAvatar
}: { 
  userId: string, 
  onClose: () => void, 
  onUpdate: (data: { display_name?: string, bio?: string }) => void,
  onUploadAvatar: (f: File) => void,
  currentName?: string | null,
  currentBio?: string | null,
  currentAvatar?: string | null
}) {
  const [name, setName] = useState(currentName || '');
  const [bio, setBio] = useState(currentBio || '');

  return (
    <div style={{ position: 'fixed', top: 0, left: 0, right: 0, bottom: 0, backgroundColor: 'rgba(0,0,0,0.7)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 10000 }}>
      <div style={{ width: 400, backgroundColor: '#1e293b', borderRadius: 16, padding: 24, position: 'relative', boxShadow: '0 10px 40px rgba(0,0,0,0.5)' }}>
        <X size={20} style={{ position: 'absolute', top: 16, right: 16, cursor: 'pointer', color: '#94a3b8' }} onClick={onClose} />
        <h2 style={{ marginTop: 0, marginBottom: 20 }}>Edit Profile</h2>
        
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', marginBottom: 24 }}>
           <div style={{ width: 100, height: 100, borderRadius: 50, backgroundColor: '#334155', backgroundImage: currentAvatar ? `url(${currentAvatar})` : 'none', backgroundSize: 'cover', backgroundPosition: 'center', marginBottom: 12, display: 'flex', alignItems: 'center', justifyContent: 'center', overflow: 'hidden' }}>
              {!currentAvatar && <User size={40} color="#64748b" />}
           </div>
           <label style={{ cursor: 'pointer', color: 'var(--accent-color)', fontSize: 14, fontWeight: 500 }}>
             Change Avatar
             <input type="file" accept="image/*" style={{ display: 'none' }} onChange={e => {
               if (e.target.files && e.target.files[0]) onUploadAvatar(e.target.files[0]);
             }} />
           </label>
        </div>

        <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
          <div>
            <label style={{ display: 'block', marginBottom: 8, fontSize: 13, color: '#94a3b8' }}>Display Name</label>
            <input type="text" value={name} onChange={e => setName(e.target.value)} style={{ width: '100%', padding: '10px 14px', borderRadius: 8, border: '1px solid #334155', backgroundColor: '#0f172a', color: '#fff', boxSizing: 'border-box' }} />
          </div>
          <div>
            <label style={{ display: 'block', marginBottom: 8, fontSize: 13, color: '#94a3b8' }}>Bio</label>
            <textarea value={bio} onChange={e => setBio(e.target.value)} rows={3} style={{ width: '100%', padding: '10px 14px', borderRadius: 8, border: '1px solid #334155', backgroundColor: '#0f172a', color: '#fff', boxSizing: 'border-box', resize: 'none' }} />
          </div>
          <button 
            onClick={() => { onUpdate({ display_name: name, bio }); onClose(); }}
            style={{ marginTop: 12, padding: 12, borderRadius: 8, backgroundColor: 'var(--accent-color)', color: '#fff', fontWeight: 'bold', border: 'none', cursor: 'pointer' }}
          >
            Save Changes
          </button>
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
  
  const [replyingTo, setReplyingTo] = useState<any>(null);
  const [editingMessage, setEditingMessage] = useState<any>(null);
  const [showProfile, setShowProfile] = useState(false);

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
    onlineUsers,
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
  } = useVola();

  const {
    callState,
    remoteUserId,
    isVideo,
    isMuted,
    isVideoOff,
    localVideoRef,
    remoteVideoRef,
    remoteAudioRef,
    startCall,
    acceptCall,
    rejectCall,
    endCall,
    toggleMute,
    toggleVideo,
  } = useWebRTC(userId, incomingSignal, sendSignal);

  const isDM = activeRoomId?.startsWith('dm_');
  const targetUserIdForCall = isDM ? members.find(m => m.id !== userId)?.id : null;

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
            if (m.id && !userProfiles[m.id]) fetchProfile(m.id);
          });
          setReadReceipts(seeds);
        })
        .catch(console.error);
    }
  }, [activeRoomId]);

  useEffect(() => {
    if (Notification.permission === 'default') {
      Notification.requestPermission();
    }
  }, []);

  // Trigger desktop notification when window is blurred and new message arrives
  const prevMessagesLength = useRef(messages.length);
  useEffect(() => {
    if (messages.length > prevMessagesLength.current) {
      const latestMessage = messages[messages.length - 1];
      if (latestMessage.sender_id !== (userId || 'me') && !document.hasFocus()) {
        const sender = members.find(m => m.id === latestMessage.sender_id);
        const name = sender ? (sender.display_name || sender.username) : 'Someone';
        const body = latestMessage.msg_type === 'ImageBlurHash' ? '📷 Sent an image' : latestMessage.content;
        if (Notification.permission === 'granted') {
          new Notification(`Vola: ${name}`, { body });
        }
      }
    }
    prevMessagesLength.current = messages.length;
  }, [messages, members, userId]);

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
    if (editingMessage) {
      editMessage(editingMessage.id, inputText);
      setEditingMessage(null);
    } else {
      sendMessage(inputText, 'Text', replyingTo?.id);
      if (replyingTo) setReplyingTo(null);
    }
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
      {showProfile && userId && (
        <ProfileModal 
          userId={userId} 
          onClose={() => setShowProfile(false)} 
          onUpdate={updateProfile}
          onUploadAvatar={uploadAvatar}
          currentName={userProfiles[userId]?.display_name}
          currentBio={userProfiles[userId]?.bio}
          currentAvatar={userProfiles[userId]?.avatar_url}
        />
      )}
      
      <div className="sidebar-personas">
        <div 
           onClick={() => setShowProfile(true)}
           style={{ 
             width: 44, height: 44, borderRadius: 22, marginBottom: 20, cursor: 'pointer',
             background: userProfiles[userId || '']?.avatar_url ? `url(${userProfiles[userId || '']?.avatar_url})` : 'var(--accent-gradient)',
             backgroundSize: 'cover', backgroundPosition: 'center', border: '2px solid transparent'
           }}
           title="Edit Profile"
        ></div>
        
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
                : socketStatus === 'Connected' ? (isDM && targetUserIdForCall ? (onlineUsers[targetUserIdForCall] ? '🟢 Online' : (userProfiles[targetUserIdForCall]?.last_seen ? `Offline — Last seen ${new Date(userProfiles[targetUserIdForCall].last_seen! * 1000).toLocaleString()}` : '🔴 Offline')) : '🟢 Online — Live broadcast active')
                : socketStatus === 'Reconnecting' ? '🟡 Reconnecting...' 
                : '🔴 Disconnected'}
            </span>
          </div>
          <div style={{ marginLeft: 'auto', display: 'flex', gap: 20, color: 'var(--text-secondary)' }}>
            {isDM && targetUserIdForCall && (
               <>
                 <Phone size={20} cursor="pointer" onClick={() => startCall(targetUserIdForCall, false)} color="var(--accent-color)" title="Audio Call" />
                 <Video size={20} cursor="pointer" onClick={() => startCall(targetUserIdForCall, true)} color="var(--accent-color)" title="Video Call" />
               </>
            )}
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
              <div key={msg.id} className={`message ${isMe ? 'sent' : 'received'}`} ref={isLastMsg ? lastMsgRef : undefined} style={{ display: 'flex', flexDirection: 'column', position: 'relative' }}>
                {msg.reply_to_message_id && (
                  <div className="reply-preview-bubble" style={{ fontSize: 11, opacity: 0.7, padding: '4px 8px', background: 'rgba(0,0,0,0.2)', borderRadius: 6, marginBottom: 4, display: 'flex', alignItems: 'center', gap: 4 }}>
                    <CornerUpLeft size={12} />
                    {messages.find(m => m.id === msg.reply_to_message_id)?.content || 'Deleted message'}
                  </div>
                )}
                <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                  <div>
                    {msg.msg_type === 'ImageBlurHash' ? (
                      <ImageBubble content={msg.content} />
                    ) : (
                      <span className={msg.msg_type === 'System' ? 'system-msg' : ''}>{msg.content}</span>
                    )}
                  </div>
                  {/* Actions Tray */}
                  <div className="msg-actions" style={{ display: 'flex', gap: 6, opacity: 0.6 }}>
                     <Smile size={14} cursor="pointer" onClick={() => addReaction(msg.id, '👍')} />
                     <CornerUpLeft size={14} cursor="pointer" onClick={() => { setEditingMessage(null); setReplyingTo(msg); }} />
                     {isMe && msg.msg_type !== 'System' && (
                       <>
                         <Edit2 size={14} cursor="pointer" onClick={() => { setReplyingTo(null); setEditingMessage(msg); setInputText(msg.content); }} />
                         <Trash2 size={14} cursor="pointer" onClick={() => deleteMessage(msg.id)} color="#ef4444" />
                       </>
                     )}
                  </div>
                </div>

                <div style={{ fontSize: 11, color: 'rgba(255,255,255,0.7)', marginTop: 6, display: 'flex', alignItems: 'center', justifyContent: 'flex-end', gap: 4 }}>
                  {msg.is_edited && <span style={{ fontStyle: 'italic', marginRight: 4 }}>(edited)</span>}
                  {new Date(msg.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
                  {isMe && (
                    <span style={{ display: 'flex', color: isRead ? 'var(--accent-color)' : 'rgba(255,255,255,0.5)' }}>
                      <Check size={14} />
                      {isRead && <Check size={14} style={{ marginLeft: -8 }} />}
                    </span>
                  )}
                </div>

                {/* Reactions */}
                {msg.reactions && Object.keys(msg.reactions).length > 0 && (
                  <div style={{ display: 'flex', gap: 4, marginTop: 4, flexWrap: 'wrap' }}>
                    {Object.entries(msg.reactions).map(([emoji, users]) => {
                      const isReacted = Array.isArray(users) && users.includes(userId || 'me');
                      return (
                        <div 
                          key={emoji} 
                          onClick={() => {
                            if (isReacted) removeReaction(msg.id, emoji);
                            else addReaction(msg.id, emoji);
                          }}
                          style={{ fontSize: 12, background: isReacted ? 'rgba(59, 130, 246, 0.2)' : 'rgba(255,255,255,0.1)', padding: '2px 6px', borderRadius: 12, display: 'flex', alignItems: 'center', gap: 4, cursor: 'pointer', border: isReacted ? '1px solid var(--accent-color)' : '1px solid transparent' }}
                        >
                          {emoji} <span style={{ opacity: 0.7 }}>{(users as string[]).length}</span>
                        </div>
                      )
                    })}
                  </div>
                )}
              </div>
            );
          })}
          <div ref={messagesEndRef} />
        </div>

        <div className="chat-input-wrapper" style={{ position: 'relative' }}>
          {(replyingTo || editingMessage) && (
            <div style={{ position: 'absolute', top: -40, left: 0, right: 0, height: 40, background: '#1e293b', borderTopLeftRadius: 10, borderTopRightRadius: 10, padding: '0 16px', display: 'flex', alignItems: 'center', gap: 8, fontSize: 13, borderBottom: '1px solid #334155' }}>
              {replyingTo ? <CornerUpLeft size={14} color="var(--accent-color)" /> : <Edit2 size={14} color="var(--accent-color)" />}
              <span style={{ flex: 1, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', opacity: 0.8 }}>
                 {replyingTo ? 'Replying to: ' : 'Editing: '} 
                 <span style={{ fontStyle: 'italic' }}>{(replyingTo || editingMessage).content}</span>
              </span>
              <X size={16} cursor="pointer" onClick={() => { setReplyingTo(null); setEditingMessage(null); setInputText(''); }} opacity={0.6} />
            </div>
          )}
          <div className="chat-input-area" style={{ borderTopLeftRadius: (replyingTo || editingMessage) ? 0 : 10, borderTopRightRadius: (replyingTo || editingMessage) ? 0 : 10 }}>
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
      </div>

      {showMembers && (
        <div style={{ width: 260, backgroundColor: '#0f172a', borderLeft: '1px solid #1e293b', display: 'flex', flexDirection: 'column' }}>
          <div style={{ padding: 20, borderBottom: '1px solid #1e293b', fontWeight: 'bold' }}>Room Members</div>
          <div style={{ flex: 1, padding: 10, overflowY: 'auto' }}>
            {members.map(m => {
              const isOnline = onlineUsers[m.id] === true;
              return (
              <div 
                key={m.id} 
                style={{ display: 'flex', alignItems: 'center', gap: 12, padding: 10, borderRadius: 8, cursor: m.id === userId ? 'default' : 'pointer', opacity: m.id === userId ? 0.6 : 1 }} 
                className="member-item"
                onClick={() => {
                  if (m.id !== userId) createDM(m.id);
                }}
              >
                <div style={{ 
                  position: 'relative', width: 36, height: 36, borderRadius: 18, backgroundColor: '#334155', display: 'flex', alignItems: 'center', justifyContent: 'center',
                  backgroundImage: userProfiles[m.id]?.avatar_url ? `url(${userProfiles[m.id]?.avatar_url})` : 'none',
                  backgroundSize: 'cover', backgroundPosition: 'center', overflow: 'hidden'
                }}>
                  {!userProfiles[m.id]?.avatar_url && (m.display_name?.charAt(0) || m.username.charAt(0))}
                  {isOnline && <div style={{ position: 'absolute', bottom: 0, right: 0, width: 10, height: 10, borderRadius: 5, backgroundColor: '#22c55e', border: '2px solid #0f172a', zIndex: 2 }}></div>}
                </div>
                <div style={{ flex: 1 }}>
                  <div style={{ fontSize: 14, fontWeight: 500 }}>{userProfiles[m.id]?.display_name || m.display_name || m.username} {m.id === userId && '(You)'}</div>
                  <div style={{ fontSize: 12, color: 'var(--text-secondary)' }}>@{m.username} {userProfiles[m.id]?.bio ? `• ${userProfiles[m.id].bio}` : ''}</div>
                </div>
              </div>
            );
            })}
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

      {callState !== 'idle' && (
         <div style={{ position: 'fixed', top: 0, left: 0, right: 0, bottom: 0, backgroundColor: 'rgba(0,0,0,0.9)', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', zIndex: 9999 }}>
           {isVideo && (
              <>
                 <video ref={remoteVideoRef} autoPlay playsInline style={{ position: 'absolute', width: '100%', height: '100%', objectFit: 'cover', zIndex: -1 }} />
                 <video ref={localVideoRef} autoPlay playsInline muted style={{ position: 'absolute', bottom: 20, right: 20, width: 120, height: 160, backgroundColor: '#000', objectFit: 'cover', borderRadius: 12, border: '2px solid rgba(255,255,255,0.2)', zIndex: 1 }} />
              </>
           )}
           
           {(!isVideo || callState !== 'connected') && (
             <>
               <div style={{ width: 100, height: 100, borderRadius: 50, backgroundColor: '#334155', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 40, color: '#fff', marginBottom: 20 }}>
                 {remoteUserId ? remoteUserId.charAt(0).toUpperCase() : '?'}
               </div>
               <h2 style={{ color: '#fff', marginBottom: 10 }}>
                 {callState === 'calling' ? 'Calling...' : callState === 'ringing' ? (isVideo ? 'Incoming Video Call' : 'Incoming Audio Call') : 'Call Connected'}
               </h2>
               {remoteUserId && <div style={{ color: '#aaa', marginBottom: 40 }}>User: {remoteUserId}</div>}
             </>
           )}

           <div style={{ display: 'flex', gap: 20, position: 'absolute', bottom: 60, zIndex: 2 }}>
             {callState === 'ringing' && (
                <button onClick={acceptCall} style={{ width: 60, height: 60, borderRadius: 30, backgroundColor: '#22c55e', border: 'none', cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                   <Phone size={24} color="#fff" />
                </button>
             )}
             
             {callState === 'connected' && (
               <>
                 <button onClick={toggleMute} style={{ width: 60, height: 60, borderRadius: 30, backgroundColor: isMuted ? '#ef4444' : 'rgba(255,255,255,0.2)', border: 'none', cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center', backdropFilter: 'blur(10px)' }}>
                    {isMuted ? <MicOff size={24} color="#fff" /> : <Mic size={24} color="#fff" />}
                 </button>
                 {isVideo && (
                    <button onClick={toggleVideo} style={{ width: 60, height: 60, borderRadius: 30, backgroundColor: isVideoOff ? '#ef4444' : 'rgba(255,255,255,0.2)', border: 'none', cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center', backdropFilter: 'blur(10px)' }}>
                       {isVideoOff ? <VideoOff size={24} color="#fff" /> : <Video size={24} color="#fff" />}
                    </button>
                 )}
               </>
             )}
             
             <button onClick={callState === 'ringing' ? rejectCall : endCall} style={{ width: 60, height: 60, borderRadius: 30, backgroundColor: '#ef4444', border: 'none', cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                <Phone size={24} color="#fff" style={{ transform: 'rotate(135deg)' }} />
             </button>
           </div>
           
           {!isVideo && <audio ref={remoteAudioRef} autoPlay />}
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
