import '../models/result.dart';
import 'logging.dart';

Future<Result<T>> withRetry<T>(
  Future<Result<T>> Function() operation,
  ErrorSource errorSource, {
  int maxRetries = 3,
  void Function(int attempt)? onRetry,
}) async {
  Object? lastError;
  StackTrace? lastStackTrace;
  String? lastFailureDetails;

  for (int i = 0; i <= maxRetries; i++) {
    if (i > 0) onRetry?.call(i);
    try {
      final result = await operation.call();
      if (result is Success) return result;
      if (result is Failure) {
        lastFailureDetails = (result as Failure).details;
      }
    } catch (e, st) {
      lastError = e;
      lastStackTrace = st;
      logError(
        "Operation failed (attempt ${i + 1}/${maxRetries + 1})",
        error: e,
        stackTrace: st,
      );
    }
  }

  final details = lastError != null ? lastError.toString() : lastFailureDetails;
  return Failure(
    CallError.unknown,
    errorSource,
    details: details,
    stackTrace: lastStackTrace,
  );
}
