import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../models/result.dart';

const List<Map<String, dynamic>> kDefaultIceServers = [
  {'urls': 'stun:stun1.l.google.com:19302'},
  {'urls': 'stun:stun2.l.google.com:19302'},
];

const _errorMap = {
  'iceconnectionfailed': CallError.iceFailed,
  'signalingerror': CallError.signalingFailed,
  'invalidstate': CallError.peerConnectionFailed,
};

Failure<T> _mapError<T>(Object e) {
  final message = e.toString().toLowerCase();
  final error = _errorMap.entries
      .firstWhere(
        (entry) => message.contains(entry.key),
        orElse: () => MapEntry('', CallError.unknown),
      )
      .value;
  return Failure<T>(error, ErrorSource.webRtc);
}

Future<Result<RTCPeerConnection>> initializePeerConnection(
  MediaStream localStream,
) async {
  try {
    final peerConnection = await createPeerConnection({
      'iceServers': kDefaultIceServers,
    });
    await updateLocalStream(localStream, peerConnection);

    return Success(peerConnection);
  } catch (e) {
    return _mapError(e);
  }
}

Future<Result<RTCSessionDescription>> createOffer(
  RTCPeerConnection peerConnection,
) async {
  try {
    final offer = await peerConnection.createOffer();
    await peerConnection.setLocalDescription(offer);

    return Success(offer);
  } catch (e) {
    return _mapError(e);
  }
}

Future<Result<RTCSessionDescription>> createAnswer(
  RTCPeerConnection peerConnection,
) async {
  try {
    final answer = await peerConnection.createAnswer();
    await peerConnection.setLocalDescription(answer);

    return Success(answer);
  } catch (e) {
    return _mapError(e);
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
