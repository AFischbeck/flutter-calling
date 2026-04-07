import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
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
      //TODO: this returns an result, needs error handling
      await _onOfferReceived(
        transientService,
        offer,
        localStream,
        localStreamChanges,
      );
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

    peerConnection.onIceCandidate = _iceCandidateManager
        .createOnIceCandidateCallback(myId, peerId);

    final offerCreationResult = await createOffer(peerConnection);
    if (offerCreationResult is Failure) {
      await peerConnection.close();
      await peerConnection.dispose();
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
      await peerConnection.close();
      await peerConnection.dispose();
      return offerSendResult;
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
        await peer.dispose();
      } else {
        await peerConnection.close();
        await peerConnection.dispose();
      }
      return Failure(CallError.peerConnectionFailed, ErrorSource.webRtc);
    }

    final createAnswerResult = await createAnswer(peerConnection);
    if (createAnswerResult is Failure) {
      await peer.dispose();
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
      await peer.dispose();
      return sendAnswerResult;
    }

    try {
      await _iceCandidateManager.flushPendingCandidates(
        peerConnection,
        offer.from,
      );
    } catch (e) {
      await peer.dispose();
      return Failure(CallError.peerConnectionFailed, ErrorSource.webRtc);
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
    await peer.dispose();
    _peersController.add(Map.unmodifiable(_peers));
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
    } catch (e) {
      await _removePeer(answer.from);
    }
  }

  Future<void> dispose() async {
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
    await _iceCandidateManager.dispose();
    await _peersController.close();
  }
}
