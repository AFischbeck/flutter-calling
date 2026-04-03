import 'dart:async';

import '../models/result.dart';
import 'timeout_handler.dart';

class StreamAwaiter<T> {
  StreamAwaiter({
    required Stream<T> stream,
    required this.onEvent,
    required this.onFinalTimeout,
    required this.initialOperation,
    this.timeout = const Duration(seconds: 30),
    this.maxRetries = 3,
    this.onRetry,
    this.onOperationFailed,
    this.onDispose,
  }) {
    _subscription = stream.listen(_handleEvent);

    _start();
  }

  final Duration timeout;
  final int maxRetries;
  final void Function(T event) onEvent;
  final void Function() onFinalTimeout;
  final Future<Result> Function() initialOperation;
  final void Function(int attempt, int maxRetries)? onRetry;
  final void Function(String message)? onOperationFailed;
  final void Function()? onDispose;

  int _retryCount = 0;
  bool _disposed = false;
  StreamSubscription<T>? _subscription;
  TimeoutHandler? _handler;

  Future<void> _start() async {
    final result = await initialOperation();
    if (_disposed) return;
    if (result is Failure) {
      onOperationFailed?.call('Stream awaiter operation failed.');
      dispose();
      return;
    }

    _startTimeout();
  }

  void _startTimeout() {
    _handler = TimeoutHandler(onTimeout: _onTimeout, timeout: timeout);
  }

  void _handleEvent(T event) {
    if (_disposed) return;
    onEvent(event);
    dispose();
  }

  Future<void> _onTimeout() async {
    if (_retryCount >= maxRetries) {
      onFinalTimeout();
      dispose();
      return;
    }

    _retryCount++;
    onRetry?.call(_retryCount, maxRetries);

    await _start();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _handler?.dispose();
    _handler = null;
    _subscription?.cancel();
    _subscription = null;
    onDispose?.call();
  }
}
