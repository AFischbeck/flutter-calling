import 'result.dart';
import '../helpers/stream_awaiter.dart';
import 'signaling_payload.dart';

class PendingAnswer {
  PendingAnswer({
    required this.peerId,
    required Stream<SignalingSdp> answerStream,
    required void Function(SignalingSdp answer) onAnswerReceived,
    required void Function(String peerId) onFinalTimeout,
    required Future<Result> Function() sendOffer,
    required void Function(PendingAnswer self) removeSelf,
    Duration timeout = const Duration(seconds: 30),
    int maxRetries = 3,
    void Function(String)? notifyWarning,
    void Function(String)? notifyError,
  }) {
    _awaiter = StreamAwaiter<SignalingSdp>(
      stream: answerStream.where((answer) => answer.from == peerId),
      onEvent: onAnswerReceived,
      onFinalTimeout: () => onFinalTimeout(peerId),
      initialOperation: sendOffer,
      timeout: timeout,
      maxRetries: maxRetries,
      onRetry: (attempt, max) => notifyWarning?.call(
        'Timed out waiting for answer from $peerId. Retry attempt $attempt/$max.',
      ),
      onOperationFailed: (message) =>
          notifyError?.call('Error: $message for $peerId'),
      onDispose: () => removeSelf(this),
    );
  }

  final String peerId;
  late final StreamAwaiter<SignalingSdp> _awaiter;

  void dispose() => _awaiter.dispose();
}
