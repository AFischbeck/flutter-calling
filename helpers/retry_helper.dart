import '../models/result.dart';

Future<Result<T>> withRetry<T>(
  Future<Result<T>> Function() operation,
  ErrorSource errorSource, {
  int maxRetries = 3,
  void Function(int attempt)? onRetry,
}) async {
  for (int i = 0; i <= maxRetries; i++) {
    if (i > 0) onRetry?.call(i);
    try {
      final result = await operation.call();
      if (result is Success) return result;
    } on Exception {
      continue;
    }
  }
  return Failure(CallError.unknown, errorSource);
}
