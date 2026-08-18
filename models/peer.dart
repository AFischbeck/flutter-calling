import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../helpers/logging.dart';
import '../helpers/webrtc_helpers.dart';

class Peer {
  Peer({
    required this.peerConnection,
    required Stream<MediaStream?> localStreamChanges,
    this.onDisconnected,
  }) {
    _localStreamSubscription = localStreamChanges.listen((stream) {
      if (_disposed) return;
      final previous = _inFlightLocalStreamUpdate ?? Future<void>.value();
      _inFlightLocalStreamUpdate =
          previous.then((_) => _syncLocalStream(stream));
    });

    peerConnection.onTrack = (event) {
      if (_disposed) return;
      try {
        remoteStream = event.streams.firstOrNull;
        _remoteStreamController.add(remoteStream);
      } catch (e, st) {
        logError("Failed to handle remote track", error: e, stackTrace: st);
      }
    };

    peerConnection.onConnectionState = (state) {
      try {
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
          onDisconnected?.call();
        }
      } catch (e, st) {
        logError("Failed to handle connection state", error: e, stackTrace: st);
      }
    };
  }

  final RTCPeerConnection peerConnection;
  final void Function()? onDisconnected;
  bool _disposed = false;
  Future<void>? _inFlightLocalStreamUpdate;
  late final StreamSubscription<MediaStream?> _localStreamSubscription;
  final _remoteStreamController = StreamController<MediaStream?>.broadcast();

  MediaStream? remoteStream;
  Stream<MediaStream?> get remoteStreamChanges =>
      _remoteStreamController.stream;

  Future<void> _syncLocalStream(MediaStream? stream) async {
    try {
      await updateLocalStream(stream, peerConnection);
    } catch (e, st) {
      logError("Failed to update local stream", error: e, stackTrace: st);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _localStreamSubscription.cancel();
    await _inFlightLocalStreamUpdate;
    await _remoteStreamController.close();
    await peerConnection.dispose();
  }
}
