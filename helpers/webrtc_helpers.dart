import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../models/ice_server_config.dart';
import '../models/result.dart';
import 'logging.dart';

const List<IceServerConfig> kDefaultStunServers = [
  IceServerConfig(urls: ['stun:stun1.l.google.com:19302']),
  IceServerConfig(urls: ['stun:stun2.l.google.com:19302']),
];

const _errorMap = {
  'iceconnectionfailed': CallError.iceFailed,
  'signalingerror': CallError.signalingFailed,
  'invalidstate': CallError.peerConnectionFailed,
};

Failure<T> _mapError<T>(Object e, [StackTrace? st]) {
  final message = e.toString().toLowerCase();
  final error = _errorMap.entries
      .firstWhere(
        (entry) => message.contains(entry.key),
        orElse: () => MapEntry('', CallError.unknown),
      )
      .value;
  return Failure<T>(
    error,
    ErrorSource.webRtc,
    details: e.toString(),
    stackTrace: st,
  );
}

Future<Result<RTCPeerConnection>> initializePeerConnection(
  MediaStream localStream, {
  required List<Map<String, dynamic>> iceServers,
}) async {
  RTCPeerConnection? peerConnection;
  try {
    peerConnection = await createPeerConnection({'iceServers': iceServers});
    await updateLocalStream(localStream, peerConnection);

    return Success(peerConnection);
  } catch (e, st) {
    logError("Failed to initialize peer connection", error: e, stackTrace: st);
    await peerConnection?.dispose();
    return _mapError(e, st);
  }
}

Future<Result<RTCSessionDescription>> createOffer(
  RTCPeerConnection peerConnection,
) async {
  try {
    final offer = await peerConnection.createOffer();
    await peerConnection.setLocalDescription(offer);

    return Success(offer);
  } catch (e, st) {
    logError("Failed to create offer", error: e, stackTrace: st);
    return _mapError(e, st);
  }
}

Future<Result<RTCSessionDescription>> createAnswer(
  RTCPeerConnection peerConnection,
) async {
  try {
    final answer = await peerConnection.createAnswer();
    await peerConnection.setLocalDescription(answer);

    return Success(answer);
  } catch (e, st) {
    logError("Failed to create answer", error: e, stackTrace: st);
    return _mapError(e, st);
  }
}

Future<void> updateLocalStream(
  MediaStream? stream,
  RTCPeerConnection peerConnection,
) async {
  final senders = await peerConnection.getSenders();

  if (stream == null) {
    for (final sender in senders) {
      await peerConnection.removeTrack(sender);
    }
    return;
  }

  for (final track in stream.getTracks()) {
    final existingSender = senders
        .where((s) => s.track?.kind == track.kind)
        .firstOrNull;

    if (existingSender != null) {
      await existingSender.replaceTrack(track);
    } else {
      await peerConnection.addTrack(track, stream);
    }
  }
}
