sealed class Result<T> {
  const Result();
}

final class Success<T> extends Result<T> {
  final T value;
  const Success(this.value);
}

final class Failure<T> extends Result<T> {
  final CallError error;
  final ErrorSource source;
  final String? details;
  final StackTrace? stackTrace;
  const Failure(this.error, this.source, {this.details, this.stackTrace});
}

enum ErrorSource { mediaDevice, transient, webRtc }

enum CallError {
  // Media
  permissionDenied,
  deviceNotFound,
  deviceInUse,
  aborted,
  securityError,
  invalidConfig,
  alreadyRunning,
  notRunning,
  // WebRTC
  peerConnectionFailed,
  noLocalStream,
  noRemoteStream,
  signalingFailed,
  iceFailed,
  // Transient
  notConnected,
  channelError,
  timeout,
  // General
  unknown,
}
