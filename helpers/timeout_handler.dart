import 'dart:async';

class TimeoutHandler {
  TimeoutHandler({
    required this.onTimeout,
    this.timeout = const Duration(seconds: 30),
    this.onDispose,
  }) {
    _timer = Timer(timeout, _onTimeout);
  }

  final Duration timeout;
  final FutureOr<void> Function() onTimeout;
  final void Function()? onDispose;

  bool _disposed = false;
  Timer? _timer;

  Future<void> _onTimeout() async {
    await onTimeout();
    dispose();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    onDispose?.call();
  }
}
