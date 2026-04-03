import 'package:flutter_webrtc/flutter_webrtc.dart';

abstract class SignalingPayload {
  final String from;
  final String to;

  Map<String, dynamic> toMap();

  const SignalingPayload({required this.from, required this.to});
}

class SignalingSdp extends SignalingPayload {
  final String sdp;

  const SignalingSdp({
    required this.sdp,
    required super.from,
    required super.to,
  });

  @override
  Map<String, dynamic> toMap() => {'sdp': sdp, 'from': from, 'to': to};

  factory SignalingSdp.fromMap(Map<String, dynamic> map) => SignalingSdp(
    sdp: map['sdp'] as String,
    from: map['from'] as String,
    to: map['to'] as String,
  );
}

class IceCandidatePayload extends SignalingPayload {
  final String? candidate;
  final String? sdpMid;
  final int? sdpMLineIndex;

  const IceCandidatePayload({
    required this.candidate,
    required this.sdpMid,
    required this.sdpMLineIndex,
    required super.from,
    required super.to,
  });

  @override
  Map<String, dynamic> toMap() => {
    'candidate': candidate,
    'sdpMid': sdpMid,
    'sdpMLineIndex': sdpMLineIndex,
    'from': from,
    'to': to,
  };

  factory IceCandidatePayload.fromMap(Map<String, dynamic> map) =>
      IceCandidatePayload(
        candidate: map['candidate'] as String?,
        sdpMid: map['sdpMid'] as String?,
        sdpMLineIndex: map['sdpMLineIndex'] as int?,
        from: map['from'] as String,
        to: map['to'] as String,
      );

  RTCIceCandidate toRTCIceCandidate() =>
      RTCIceCandidate(candidate, sdpMid, sdpMLineIndex);
}
