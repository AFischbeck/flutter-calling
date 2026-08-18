import 'dart:developer';
import 'dart:io';

/// Writes an error with its details and stack trace to stderr (unbuffered,
/// survives native crashes) and forwards it to `dart:developer` for DevTools.
void logError(String message, {Object? error, StackTrace? stackTrace}) {
  final details = error ?? "unknown";
  final stack = stackTrace?.toString().trim() ?? "";
  stderr.writeln("[TaskTogether] $message\n  Error: $details\n$stack");
  log(message, error: error, stackTrace: stackTrace);
}
