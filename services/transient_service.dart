import 'package:webrtc_flutter_demo/models/result.dart';
import 'package:webrtc_flutter_demo/services/transient/signaling_payload.dart';

class TransientConnectionInfo {
  const TransientConnectionInfo({required this.existingPeerIds});
  final List<String> existingPeerIds;
}

abstract class TransientService {
  String get id;
  Future<Result<TransientConnectionInfo>> connect();
  Future<Result<void>> sendPayload(String event, SignalingPayload payload);
  Stream<SignalingSdp> get offerStream;
  Stream<SignalingSdp> get answerStream;
  Stream<IceCandidatePayload> get iceCandidateStream;
  Stream<String> get peerDisconnectedStream;
  void dispose();
}
