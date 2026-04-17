import { useState, useEffect, useRef, useCallback } from 'react';

export type CallState = 'idle' | 'calling' | 'ringing' | 'connected';

export function useWebRTC(
  userId: string | null,
  incomingSignal: any,
  sendSignal: (targetId: string, payload: any) => void
) {
  const [callState, setCallState] = useState<CallState>('idle');
  const [remoteUserId, setRemoteUserId] = useState<string | null>(null);
  const [isVideo, setIsVideo] = useState(false);
  const [isMuted, setIsMuted] = useState(false);
  const [isVideoOff, setIsVideoOff] = useState(false);

  const peerConnection = useRef<RTCPeerConnection | null>(null);
  const localStream = useRef<MediaStream | null>(null);
  const remoteStream = useRef<MediaStream | null>(null);

  // Refs for <video> / <audio> elements
  const localVideoRef = useRef<HTMLVideoElement | null>(null);
  const remoteVideoRef = useRef<HTMLVideoElement | null>(null);
  const remoteAudioRef = useRef<HTMLAudioElement | null>(null);

  const initPeerConnection = useCallback((targetId: string) => {
    if (peerConnection.current) peerConnection.current.close();

    const pc = new RTCPeerConnection({
      iceServers: [
        { urls: 'stun:stun.l.google.com:19302' },
        { urls: 'stun:stun1.l.google.com:19302' },
      ]
    });

    pc.onicecandidate = (event) => {
      if (event.candidate) {
        sendSignal(targetId, { type: 'ice-candidate', candidate: event.candidate });
      }
    };

    pc.ontrack = (event) => {
      if (event.streams?.[0]) {
        remoteStream.current = event.streams[0];
        if (remoteVideoRef.current) {
          remoteVideoRef.current.srcObject = event.streams[0];
        } else if (remoteAudioRef.current) {
          remoteAudioRef.current.srcObject = event.streams[0];
        }
      }
    };

    if (localStream.current) {
      localStream.current.getTracks().forEach(track => {
        pc.addTrack(track, localStream.current!);
      });
    }

    pc.onconnectionstatechange = () => {
      if (pc.connectionState === 'connected') {
        setCallState('connected');
      } else if (['disconnected', 'failed', 'closed'].includes(pc.connectionState)) {
        endCallLocal();
      }
    };

    peerConnection.current = pc;
    return pc;
  }, [sendSignal]); // eslint-disable-line

  const endCallLocal = useCallback(() => {
    setCallState('idle');
    setRemoteUserId(null);
    setIsVideo(false);
    setIsMuted(false);
    setIsVideoOff(false);
    peerConnection.current?.close();
    peerConnection.current = null;
    localStream.current?.getTracks().forEach(t => t.stop());
    localStream.current = null;
    if (localVideoRef.current) localVideoRef.current.srcObject = null;
    if (remoteVideoRef.current) remoteVideoRef.current.srcObject = null;
    if (remoteAudioRef.current) remoteAudioRef.current.srcObject = null;
  }, []);

  const getLocalMedia = async (withVideo: boolean) => {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: true,
        video: withVideo
      });
      localStream.current = stream;
      if (withVideo && localVideoRef.current) {
        localVideoRef.current.srcObject = stream;
      }
      return true;
    } catch (err) {
      console.error('Failed to get media', err);
      return false;
    }
  };

  const startCall = async (targetId: string, withVideo = false) => {
    if (!await getLocalMedia(withVideo)) return;
    setRemoteUserId(targetId);
    setIsVideo(withVideo);
    setCallState('calling');

    const pc = initPeerConnection(targetId);
    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    sendSignal(targetId, { type: 'offer', offer, isVideo: withVideo });
  };

  const acceptCall = async () => {
    if (!remoteUserId || !peerConnection.current) return;
    if (!await getLocalMedia(isVideo)) {
      sendSignal(remoteUserId, { type: 'reject' });
      endCallLocal();
      return;
    }

    localStream.current?.getTracks().forEach(track => {
      peerConnection.current!.addTrack(track, localStream.current!);
    });

    const answer = await peerConnection.current.createAnswer();
    await peerConnection.current.setLocalDescription(answer);
    sendSignal(remoteUserId, { type: 'answer', answer });
    setCallState('connected');
  };

  const rejectCall = () => {
    if (remoteUserId) sendSignal(remoteUserId, { type: 'reject' });
    endCallLocal();
  };

  const endCall = () => {
    if (remoteUserId) sendSignal(remoteUserId, { type: 'end' });
    endCallLocal();
  };

  const toggleMute = useCallback(() => {
    if (!localStream.current) return;
    const audioTrack = localStream.current.getAudioTracks()[0];
    if (audioTrack) {
      audioTrack.enabled = !audioTrack.enabled;
      setIsMuted(!audioTrack.enabled);
    }
  }, []);

  const toggleVideo = useCallback(() => {
    if (!localStream.current) return;
    const videoTrack = localStream.current.getVideoTracks()[0];
    if (videoTrack) {
      videoTrack.enabled = !videoTrack.enabled;
      setIsVideoOff(!videoTrack.enabled);
    }
  }, []);

  useEffect(() => {
    if (!incomingSignal || !userId) return;
    const { sender_user_id, signal_payload } = incomingSignal;
    if (!sender_user_id) return;

    const handleSignal = async () => {
      const type = signal_payload.type;

      if (type === 'offer') {
        if (callState !== 'idle') {
          sendSignal(sender_user_id, { type: 'reject' });
          return;
        }
        setRemoteUserId(sender_user_id);
        setIsVideo(!!signal_payload.isVideo);
        setCallState('ringing');
        const pc = initPeerConnection(sender_user_id);
        await pc.setRemoteDescription(new RTCSessionDescription(signal_payload.offer));
      } else if (type === 'answer') {
        if (peerConnection.current) {
          await peerConnection.current.setRemoteDescription(
            new RTCSessionDescription(signal_payload.answer)
          );
        }
      } else if (type === 'ice-candidate') {
        if (peerConnection.current) {
          await peerConnection.current.addIceCandidate(
            new RTCIceCandidate(signal_payload.candidate)
          );
        }
      } else if (type === 'reject' || type === 'end') {
        endCallLocal();
      }
    };

    handleSignal().catch(console.error);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [incomingSignal, userId]);

  return {
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
  };
}
