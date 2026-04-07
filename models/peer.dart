import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../helpers/webrtc_helpers.dart';

class Peer {
  Peer({
    required this.peerConnection,
    required Stream<MediaStream?> localStreamChanges,
    this.onDisconnected,
  }) {
    _localStreamSubscription = localStreamChanges.listen((stream) async {
      await updateLocalStream(stream, peerConnection);
    });

    peerConnection.onTrack = (event) {
      remoteStream = event.streams.firstOrNull;
      _remoteStreamController.add(event.streams.firstOrNull);
    };

    peerConnection.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        onDisconnected?.call();
      }
    };
  }

  final RTCPeerConnection peerConnection;
  final void Function()? onDisconnected;
  late final StreamSubscription<MediaStream?> _localStreamSubscription;
  final _remoteStreamController = StreamController<MediaStream?>.broadcast();

  MediaStream? remoteStream;
  Stream<MediaStream?> get remoteStreamChanges =>
      _remoteStreamController.stream;

  Future<void> dispose() async {
    await remoteStream?.dispose();
    await peerConnection.close();
    await peerConnection.dispose();
    await _localStreamSubscription.cancel();
    await _remoteStreamController.close();
  }
}
