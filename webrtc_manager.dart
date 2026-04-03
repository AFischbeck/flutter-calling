import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:webrtc_flutter_demo/helpers/retry_helper.dart';
import 'package:webrtc_flutter_demo/helpers/webrtc_helpers.dart';
import 'package:webrtc_flutter_demo/models/peer.dart';
import 'package:webrtc_flutter_demo/models/pending_answer.dart';
import 'package:webrtc_flutter_demo/models/result.dart';
import 'package:webrtc_flutter_demo/services/ice_candidate_manager.dart';
import 'package:webrtc_flutter_demo/services/transient/signaling_payload.dart';
import 'package:webrtc_flutter_demo/services/transient/transient_service.dart';

class WebRtcManager {
  WebRtcManager({this.notifyWarning, this.notifyError});

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

    final peerConnectionResult = await initializePeerConnection(localStream);
    if (peerConnectionResult is Failure) return peerConnectionResult;

    final RTCPeerConnection peerConnection =
        (peerConnectionResult as Success).value;

    peerConnection.onIceCandidate = _iceCandidateManager
        .createOnIceCandidateCallback(myId, peerId);

    final offerCreationResult = await createOffer(peerConnection);
    if (offerCreationResult is Failure) {
      peerConnection.dispose();
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
      peerConnection.dispose();
      return offerSendResult;
    }

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
    final peerConnectionResult = await initializePeerConnection(localStream);
    if (peerConnectionResult is Failure) return peerConnectionResult;

    final RTCPeerConnection peerConnection =
        (peerConnectionResult as Success).value;

    peerConnection.onIceCandidate = _iceCandidateManager
        .createOnIceCandidateCallback(transientService.id, offer.from);

    final peer = Peer(
      peerConnection: peerConnection,
      localStreamChanges: localStreamChanges,
      onDisconnected: () => _removePeer(offer.from),
    );
    await peer.peerConnection.setRemoteDescription(
      RTCSessionDescription(offer.sdp, 'offer'),
    );
    _peers[offer.from] = peer;
    _peersController.add(Map.unmodifiable(_peers));

    final createAnswerResult = await createAnswer(peerConnection);
    if (createAnswerResult is Failure) return createAnswerResult;
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
    if (sendAnswerResult is Failure) return sendAnswerResult;

    await _iceCandidateManager.flushPendingCandidates(
      peerConnection,
      offer.from,
    );

    return Success(null);
  }

  void _removePeer(String peerId) {
    final peer = _peers.remove(peerId);
    if (peer == null) return;

    peer.dispose();
    _peersController.add(Map.unmodifiable(_peers));
  }

  Future<void> _onAnswerReceived(SignalingSdp answer) async {
    final peer = _peers[answer.from];
    if (peer == null) return;

    await peer.peerConnection.setRemoteDescription(
      RTCSessionDescription(answer.sdp, 'answer'),
    );
    await _iceCandidateManager.flushPendingCandidates(
      peer.peerConnection,
      answer.from,
    );
  }

  void dispose() {
    for (final connectedPeer in _peers.values) {
      connectedPeer.dispose();
    }
    for (final pendingAnswer in _pendingAnswers.toList()) {
      pendingAnswer.dispose();
    }
    _offerSubscription?.cancel();
    _peerDisconnectedSubscription?.cancel();
    _iceCandidateManager.dispose();
    _peersController.close();
  }
}
