import 'dart:async';
import 'dart:collection';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:webrtc_flutter_demo/services/transient/signaling_payload.dart';
import 'package:webrtc_flutter_demo/services/transient/transient_service.dart';

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
    // TODO: Error handling
    return (RTCIceCandidate candidate) async {
      if (candidate.candidate?.isNotEmpty != true) return;

      await _transientService.sendPayload(
        'ice_candidate',
        IceCandidatePayload(
          candidate: candidate.candidate,
          sdpMid: candidate.sdpMid,
          sdpMLineIndex: candidate.sdpMLineIndex,
          from: myId,
          to: peerId,
        ),
      );
    };
  }

  Future<void> _onRemoteIceCandidateReceived(
    IceCandidatePayload candidate,
  ) async {
    final peerConnection = _lookupPeerConnection(candidate.from);
    if (peerConnection != null) {
      await peerConnection.addCandidate(candidate.toRTCIceCandidate());
    } else {
      _pendingCandidates
          .putIfAbsent(candidate.from, () => Queue())
          .addLast(candidate);
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

  void dispose() {
    _inboundSubscription?.cancel();
    _pendingCandidates.clear();
  }
}
