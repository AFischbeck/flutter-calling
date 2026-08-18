import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'helpers/logging.dart';
import 'helpers/retry_helper.dart';
import 'helpers/webrtc_helpers.dart';
import 'models/ice_server_config.dart';
import 'models/peer.dart';
import 'models/pending_answer.dart';
import 'models/result.dart';
import 'services/ice_candidate_manager.dart';
import 'models/signaling_payload.dart';
import 'services/transient_service.dart';

class WebRtcManager {
  WebRtcManager({
    List<IceServerConfig>? stunServers,
    List<IceServerConfig>? turnServers,
    this.notifyWarning,
    this.notifyError,
  }) : _iceServers = [
         ...(stunServers != null && stunServers.isNotEmpty
                 ? stunServers
                 : kDefaultStunServers)
             .map((s) => s.toMap()),
         if (turnServers != null) ...turnServers.map((s) => s.toMap()),
       ];

  final List<Map<String, dynamic>> _iceServers;
  final void Function(String)? notifyWarning;
  final void Function(String)? notifyError;

  StreamSubscription<SignalingSdp>? _offerSubscription;
  late final IceCandidateManager _iceCandidateManager;

  final Set<PendingAnswer> _pendingAnswers = {};

  final Map<String, Peer> _peers = {};
  final Set<RTCPeerConnection> _inFlightConnections = {};
  bool _disposed = false;
  final _peersController = StreamController<Map<String, Peer>>.broadcast();
  StreamSubscription<String>? _peerDisconnectedSubscription;

  Stream<Map<String, Peer>> get peersChanges => _peersController.stream;

  Future<Result> initialize(
    TransientService transientService,
    MediaStream localStream,
    Stream<MediaStream?> localStreamChanges,
  ) async {
    final connectResult = await withRetry(
      () => transientService.connect(),
      ErrorSource.transient,
    );
    if (connectResult is Failure) return connectResult;
    final connectionInfo = (connectResult as Success).value;

    _iceCandidateManager = IceCandidateManager(
      transientService: transientService,
      lookupPeerConnection: (peerId) => _peers[peerId]?.peerConnection,
    );
    _iceCandidateManager.startListening();

    _offerSubscription = transientService.offerStream.listen((offer) async {
      try {
        final result = await _onOfferReceived(
          transientService,
          offer,
          localStream,
          localStreamChanges,
        );
        if (result is Failure) {
          logError(
            "Failed to process offer from ${offer.from}: ${result.error.name}",
            error: result.details,
            stackTrace: result.stackTrace,
          );
          notifyError?.call(
            "Failed to process offer from ${offer.from}: ${result.error.name}",
          );
        }
      } catch (e, st) {
        logError("Failed to process offer", error: e, stackTrace: st);
        notifyError?.call("Failed to process offer from ${offer.from}.");
      }
    });

    _peerDisconnectedSubscription = transientService.peerDisconnectedStream
        .listen(_removePeer);

    final sendOffersResult = await _sendOffers(
      transientService,
      localStream,
      localStreamChanges,
      connectionInfo.existingPeerIds,
    );
    if (sendOffersResult is Failure) return sendOffersResult;

    return Success(null);
  }

  Future<Result> _sendOffers(
    TransientService transientService,
    MediaStream localStream,
    Stream<MediaStream?> localStreamChanges,
    Iterable<String> peerIds,
  ) async {
    for (final peerId in peerIds) {
      Future<Result> sendOfferWithRetries() async {
        return withRetry(() async {
          return await _tryCreateAndSendOffer(
            transientService,
            localStream,
            localStreamChanges,
            peerId,
          );
        }, ErrorSource.webRtc);
      }

      final pendingAnswer = PendingAnswer(
        peerId: peerId,
        answerStream: transientService.answerStream,
        onAnswerReceived: _onAnswerReceived,
        onFinalTimeout: (id) {
          debugPrint('Timed out while waiting for answer from: $id');
          _removePeer(id);
        },
        sendOffer: sendOfferWithRetries,

        removeSelf: _pendingAnswers.remove,
        notifyWarning: notifyWarning,
        notifyError: notifyError,
      );

      _pendingAnswers.add(pendingAnswer);
    }

    return Success(null);
  }

  Future<Result> _tryCreateAndSendOffer(
    TransientService transientService,
    MediaStream localStream,
    Stream<MediaStream?> localStreamChanges,
    String peerId,
  ) async {
    final String myId = transientService.id;

    final peerConnectionResult = await initializePeerConnection(
      localStream,
      iceServers: _iceServers,
    );
    if (peerConnectionResult is Failure) return peerConnectionResult;

    final RTCPeerConnection peerConnection =
        (peerConnectionResult as Success).value;
    _inFlightConnections.add(peerConnection);

    if (_disposed) {
      await _releaseInFlightConnection(peerConnection);
      return Failure(CallError.aborted, ErrorSource.webRtc);
    }

    peerConnection.onIceCandidate = _iceCandidateManager
        .createOnIceCandidateCallback(myId, peerId);

    final offerCreationResult = await createOffer(peerConnection);
    if (offerCreationResult is Failure) {
      await _releaseInFlightConnection(peerConnection);
      return offerCreationResult;
    }

    final rtcSessionDescription = (offerCreationResult as Success).value;
    final SignalingSdp offer = SignalingSdp(
      sdp: rtcSessionDescription.sdp!,
      from: myId,
      to: peerId,
    );

    final offerSendResult = await transientService.sendPayload('offer', offer);
    if (offerSendResult is Failure) {
      await _releaseInFlightConnection(peerConnection);
      return offerSendResult;
    }

    if (!_inFlightConnections.remove(peerConnection)) {
      return Failure(CallError.aborted, ErrorSource.webRtc);
    }

    await _removePeer(peerId);
    _peers[peerId] = Peer(
      peerConnection: peerConnection,
      localStreamChanges: localStreamChanges,
      onDisconnected: () => _removePeer(peerId),
    );
    _peersController.add(Map.unmodifiable(_peers));
    return Success(null);
  }

  Future<Result> _onOfferReceived(
    TransientService transientService,
    SignalingSdp offer,
    MediaStream localStream,
    Stream<MediaStream?> localStreamChanges,
  ) async {
    final peerConnectionResult = await initializePeerConnection(
      localStream,
      iceServers: _iceServers,
    );
    if (peerConnectionResult is Failure) return peerConnectionResult;

    final RTCPeerConnection peerConnection =
        (peerConnectionResult as Success).value;
    _inFlightConnections.add(peerConnection);

    if (_disposed) {
      await _releaseInFlightConnection(peerConnection);
      return Failure(CallError.aborted, ErrorSource.webRtc);
    }

    peerConnection.onIceCandidate = _iceCandidateManager
        .createOnIceCandidateCallback(transientService.id, offer.from);

    Peer? peer;
    try {
      peer = Peer(
        peerConnection: peerConnection,
        localStreamChanges: localStreamChanges,
        onDisconnected: () => _removePeer(offer.from),
      );
      await peer.peerConnection.setRemoteDescription(
        RTCSessionDescription(offer.sdp, 'offer'),
      );
    } catch (e) {
      if (peer != null) {
        await _releaseInFlightPeer(peer);
      } else {
        await _releaseInFlightConnection(peerConnection);
      }
      return Failure(CallError.peerConnectionFailed, ErrorSource.webRtc);
    }

    final createAnswerResult = await createAnswer(peerConnection);
    if (createAnswerResult is Failure) {
      await _releaseInFlightPeer(peer);
      return createAnswerResult;
    }

    final RTCSessionDescription rtcSessionDescription =
        (createAnswerResult as Success).value;

    final SignalingSdp answer = SignalingSdp(
      sdp: rtcSessionDescription.sdp!,
      from: offer.to,
      to: offer.from,
    );

    final sendAnswerResult = await transientService.sendPayload(
      'answer',
      answer,
    );
    if (sendAnswerResult is Failure) {
      await _releaseInFlightPeer(peer);
      return sendAnswerResult;
    }

    try {
      await _iceCandidateManager.flushPendingCandidates(
        peerConnection,
        offer.from,
      );
    } catch (e) {
      await _releaseInFlightPeer(peer);
      return Failure(CallError.peerConnectionFailed, ErrorSource.webRtc);
    }

    if (!_inFlightConnections.remove(peerConnection)) {
      await _releaseInFlightPeer(peer);
      return Failure(CallError.aborted, ErrorSource.webRtc);
    }

    await _removePeer(offer.from);
    _peers[offer.from] = peer;
    _peersController.add(Map.unmodifiable(_peers));

    return Success(null);
  }

  Future<void> _removePeer(String peerId) async {
    final peer = _peers.remove(peerId);
    if (peer == null) return;

    _iceCandidateManager.clearPendingCandidates(peerId);
    try {
      await peer.dispose();
    } catch (e, st) {
      logError("Failed to dispose peer $peerId", error: e, stackTrace: st);
    }
    try {
      _peersController.add(Map.unmodifiable(_peers));
    } catch (e, st) {
      logError("Failed to emit peers update", error: e, stackTrace: st);
    }
  }

  Future<void> _releaseInFlightConnection(RTCPeerConnection connection) async {
    if (!_inFlightConnections.remove(connection)) return;
    try {
      await connection.dispose();
    } catch (e, st) {
      logError(
        "Failed to dispose in-flight connection",
        error: e,
        stackTrace: st,
      );
    }
  }

  Future<void> _releaseInFlightPeer(Peer peer) async {
    _inFlightConnections.remove(peer.peerConnection);
    try {
      await peer.dispose();
    } catch (e, st) {
      logError("Failed to dispose in-flight peer", error: e, stackTrace: st);
    }
  }

  Future<void> _onAnswerReceived(SignalingSdp answer) async {
    final peer = _peers[answer.from];
    if (peer == null) return;

    try {
      await peer.peerConnection.setRemoteDescription(
        RTCSessionDescription(answer.sdp, 'answer'),
      );
      await _iceCandidateManager.flushPendingCandidates(
        peer.peerConnection,
        answer.from,
      );
    } catch (e, st) {
      logError(
        "Failed to process answer from ${answer.from}",
        error: e,
        stackTrace: st,
      );
      await _removePeer(answer.from);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      final peerIds = _peers.keys.toList();
      for (final peerId in peerIds) {
        await _removePeer(peerId);
      }
      for (final pendingAnswer in _pendingAnswers.toList()) {
        await pendingAnswer.dispose();
      }
      _pendingAnswers.clear();
      await _offerSubscription?.cancel();
      await _peerDisconnectedSubscription?.cancel();
      for (final connection in _inFlightConnections.toList()) {
        await _releaseInFlightConnection(connection);
      }
      await _iceCandidateManager.dispose();
      await _peersController.close();
    } catch (e, st) {
      logError("Failed to dispose WebRTC manager", error: e, stackTrace: st);
    }
  }
}
