import 'dart:async';

import '../models/result.dart';
import 'logging.dart';
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
    Result result;
    try {
      result = await initialOperation();
    } catch (e, st) {
      logError(
        "Stream awaiter initial operation failed",
        error: e,
        stackTrace: st,
      );
      onOperationFailed?.call(e.toString());
      await dispose();
      return;
    }
    if (_disposed) return;
    if (result is Failure) {
      logError(
        "Stream awaiter operation failed: ${result.error.name}",
        error: result.details,
        stackTrace: result.stackTrace,
      );
      onOperationFailed?.call(result.error.name);
      await dispose();
      return;
    }

    _startTimeout();
  }

  void _startTimeout() {
    _handler = TimeoutHandler(onTimeout: _onTimeout, timeout: timeout);
  }

  Future<void> _handleEvent(T event) async {
    if (_disposed) return;
    try {
      onEvent(event);
    } catch (e, st) {
      logError("Error handling awaited event", error: e, stackTrace: st);
    }
    await dispose();
  }

  Future<void> _onTimeout() async {
    if (_retryCount >= maxRetries) {
      try {
        onFinalTimeout();
      } catch (e, st) {
        logError("Error handling final timeout", error: e, stackTrace: st);
      }
      await dispose();
      return;
    }

    _retryCount++;
    onRetry?.call(_retryCount, maxRetries);

    await _start();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _handler?.dispose();
    _handler = null;
    await _subscription?.cancel();
    _subscription = null;
    onDispose?.call();
  }
}
