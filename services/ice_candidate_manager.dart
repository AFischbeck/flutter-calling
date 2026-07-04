import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../models/result.dart';
import '../models/signaling_payload.dart';
import 'transient_service.dart';

class IceCandidateManager {
  IceCandidateManager({
    required TransientService transientService,
    required RTCPeerConnection? Function(String peerId) lookupPeerConnection,
  }) : _transientService = transientService,
       _lookupPeerConnection = lookupPeerConnection;

  final TransientService _transientService;
  final RTCPeerConnection? Function(String peerId) _lookupPeerConnection;

  StreamSubscription<IceCandidatePayload>? _inboundSubscription;
  final Map<String, Queue<IceCandidatePayload>> _pendingCandidates = {};

  void startListening() {
    _inboundSubscription = _transientService.iceCandidateStream.listen(
      _onRemoteIceCandidateReceived,
    );
  }

  void Function(RTCIceCandidate) createOnIceCandidateCallback(
    String myId,
    String peerId,
  ) {
    return (RTCIceCandidate candidate) async {
      if (candidate.candidate?.isNotEmpty != true) return;

      final result = await _transientService.sendPayload(
        'ice_candidate',
        IceCandidatePayload(
          candidate: candidate.candidate,
          sdpMid: candidate.sdpMid,
          sdpMLineIndex: candidate.sdpMLineIndex,
          from: myId,
          to: peerId,
        ),
      );
      if (result is Failure) {
        debugPrint('Failed to send ICE candidate: ${result.error.name}');
      }
    };
  }

  Future<void> _onRemoteIceCandidateReceived(
    IceCandidatePayload candidate,
  ) async {
    try {
      final peerConnection = _lookupPeerConnection(candidate.from);
      if (peerConnection != null) {
        await peerConnection.addCandidate(candidate.toRTCIceCandidate());
      } else {
        _pendingCandidates
            .putIfAbsent(candidate.from, () => Queue())
            .addLast(candidate);
      }
    } catch (e) {
      debugPrint('Error processing remote ICE candidate: $e');
    }
  }

  Future<void> flushPendingCandidates(
    RTCPeerConnection peerConnection,
    String remoteId,
  ) async {
    final queue = _pendingCandidates.remove(remoteId);
    if (queue == null) return;
    while (queue.isNotEmpty) {
      await peerConnection.addCandidate(
        queue.removeFirst().toRTCIceCandidate(),
      );
    }
  }

  void clearPendingCandidates(String peerId) {
    _pendingCandidates.remove(peerId);
  }

  Future<void> dispose() async {
    await _inboundSubscription?.cancel();
    _pendingCandidates.clear();
  }
}
