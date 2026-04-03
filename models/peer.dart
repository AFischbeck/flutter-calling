import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:webrtc_flutter_demo/helpers/webrtc_helpers.dart';

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

  void dispose() {
    peerConnection.close();
    _localStreamSubscription.cancel();
    _remoteStreamController.close();
  }
}
