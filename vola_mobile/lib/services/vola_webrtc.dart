import 'dart:async';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'vola_engine.dart';

enum CallState { idle, calling, ringing, connected }

class VolaWebRTC {
  final VolaEngine engine;

  CallState callState = CallState.idle;
  String? remoteUserId;
  bool isVideo = false;
  bool isMuted = false;
  bool isVideoOff = false;

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  MediaStream? _remoteStream;

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();

  // Notify UI of state changes
  final _callStateController = StreamController<CallState>.broadcast();
  Stream<CallState> get callStateStream => _callStateController.stream;

  StreamSubscription? _signalSub;

  VolaWebRTC(this.engine) {
    _signalSub = engine.incomingSignalStream.listen(_handleIncomingSignal);
  }

  Future<void> initializeRenderers() async {
    await localRenderer.initialize();
    await remoteRenderer.initialize();
  }

  Future<void> _createPeerConnection(String targetId) async {
    _pc?.close();
    final config = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
      ]
    };
    _pc = await createPeerConnection(config);

    _pc!.onIceCandidate = (candidate) {
      engine.sendSignal(targetId, {
        'type': 'ice-candidate',
        'candidate': candidate.toMap(),
      });
    };

    _pc!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams[0];
        remoteRenderer.srcObject = _remoteStream;
        _callStateController.add(callState); // Trigger UI update to render video
      }
    };

    _pc!.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        callState = CallState.connected;
        _callStateController.add(callState);
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _endCallLocal();
      }
    };

    if (_localStream != null) {
      for (final track in _localStream!.getTracks()) {
        await _pc!.addTrack(track, _localStream!);
      }
    }
  }

  Future<bool> _getLocalMedia(bool withVideo) async {
    try {
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': withVideo ? {'facingMode': 'user'} : false,
      });
      if (withVideo) {
        localRenderer.srcObject = _localStream;
      }
      return true;
    } catch (e) {
      print('[WebRTC] Failed to get media: $e');
      return false;
    }
  }

  Future<void> startCall(String targetId, {bool withVideo = false}) async {
    if (!await _getLocalMedia(withVideo)) return;
    remoteUserId = targetId;
    isVideo = withVideo;
    callState = CallState.calling;
    _callStateController.add(callState);

    await _createPeerConnection(targetId);
    final offer = await _pc!.createOffer({});
    await _pc!.setLocalDescription(offer);
    engine.sendSignal(targetId, {'type': 'offer', 'offer': offer.toMap(), 'isVideo': isVideo});
  }

  Future<void> acceptCall() async {
    if (remoteUserId == null || _pc == null) return;
    if (!await _getLocalMedia(isVideo)) {
      engine.sendSignal(remoteUserId!, {'type': 'reject'});
      _endCallLocal();
      return;
    }

    // Re-add local tracks after getting stream
    for (final track in _localStream!.getTracks()) {
      await _pc!.addTrack(track, _localStream!);
    }

    final answer = await _pc!.createAnswer({});
    await _pc!.setLocalDescription(answer);
    engine.sendSignal(remoteUserId!, {'type': 'answer', 'answer': answer.toMap()});
    callState = CallState.connected;
    _callStateController.add(callState);
  }

  void rejectCall() {
    if (remoteUserId != null) engine.sendSignal(remoteUserId!, {'type': 'reject'});
    _endCallLocal();
  }

  void endCall() {
    if (remoteUserId != null) engine.sendSignal(remoteUserId!, {'type': 'end'});
    _endCallLocal();
  }

  void toggleMute() {
    if (_localStream != null) {
      final audioTracks = _localStream!.getAudioTracks();
      if (audioTracks.isNotEmpty) {
        audioTracks[0].enabled = !audioTracks[0].enabled;
        isMuted = !audioTracks[0].enabled;
        _callStateController.add(callState); // Update UI
      }
    }
  }

  void toggleVideo() {
    if (_localStream != null) {
      final videoTracks = _localStream!.getVideoTracks();
      if (videoTracks.isNotEmpty) {
        videoTracks[0].enabled = !videoTracks[0].enabled;
        isVideoOff = !videoTracks[0].enabled;
        _callStateController.add(callState); // Update UI
      }
    }
  }

  void _endCallLocal() {
    _pc?.close();
    _pc = null;
    
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream = null;
    localRenderer.srcObject = null;
    
    _remoteStream?.getTracks().forEach((t) => t.stop());
    _remoteStream = null;
    remoteRenderer.srcObject = null;
    
    remoteUserId = null;
    isVideo = false;
    isMuted = false;
    isVideoOff = false;
    callState = CallState.idle;
    _callStateController.add(callState);
  }

  Future<void> _handleIncomingSignal(Map<String, dynamic> payload) async {
    final senderUserId = payload['sender_user_id'] as String?;
    final signalPayload = payload['signal_payload'] as Map<String, dynamic>?;
    if (senderUserId == null || signalPayload == null) return;

    final type = signalPayload['type'];

    if (type == 'offer') {
      if (callState != CallState.idle) {
        engine.sendSignal(senderUserId, {'type': 'reject'});
        return;
      }
      remoteUserId = senderUserId;
      isVideo = signalPayload['isVideo'] == true;
      await _createPeerConnection(senderUserId);
      await _pc!.setRemoteDescription(
        RTCSessionDescription(signalPayload['offer']['sdp'], signalPayload['offer']['type']),
      );
      callState = CallState.ringing;
      _callStateController.add(callState);
    } else if (type == 'answer') {
      await _pc?.setRemoteDescription(
        RTCSessionDescription(signalPayload['answer']['sdp'], signalPayload['answer']['type']),
      );
    } else if (type == 'ice-candidate') {
      final c = signalPayload['candidate'];
      await _pc?.addCandidate(RTCIceCandidate(
        c['candidate'], c['sdpMid'], c['sdpMLineIndex'],
      ));
    } else if (type == 'reject' || type == 'end') {
      _endCallLocal();
    }
  }

  void dispose() {
    _signalSub?.cancel();
    _endCallLocal();
    localRenderer.dispose();
    remoteRenderer.dispose();
    _callStateController.close();
  }
}
