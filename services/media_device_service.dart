import 'dart:async';
import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/result.dart';

class MediaDeviceConfig {
  final bool audio;
  final bool video;
  final bool preferFrontCamera;
  final String? audioDeviceId;
  final String? videoDeviceId;
  final int? width;
  final int? height;
  final int? frameRate;

  const MediaDeviceConfig({
    this.audio = true,
    this.video = true,
    this.preferFrontCamera = true,
    this.audioDeviceId,
    this.videoDeviceId,
    this.width,
    this.height,
    this.frameRate,
  });

  MediaDeviceConfig copyWith({
    bool? audio,
    bool? video,
    bool? preferFrontCamera,
    String? audioDeviceId,
    String? videoDeviceId,
    int? width,
    int? height,
    int? frameRate,
  }) {
    return MediaDeviceConfig(
      audio: audio ?? this.audio,
      video: video ?? this.video,
      preferFrontCamera: preferFrontCamera ?? this.preferFrontCamera,
      audioDeviceId: audioDeviceId ?? this.audioDeviceId,
      videoDeviceId: videoDeviceId ?? this.videoDeviceId,
      width: width ?? this.width,
      height: height ?? this.height,
      frameRate: frameRate ?? this.frameRate,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'audio': audio
          ? {if (audioDeviceId != null) 'deviceId': audioDeviceId}
          : false,
      'video': video
          ? {
              if (videoDeviceId != null)
                'deviceId': videoDeviceId
              else
                'facingMode': preferFrontCamera ? 'user' : 'environment',
              if (width != null) 'width': {'ideal': width},
              if (height != null) 'height': {'ideal': height},
              if (frameRate != null) 'frameRate': {'ideal': frameRate},
            }
          : false,
    };
  }
}

enum MediaDeviceState { idle, running, stopped }

class MediaDeviceService {
  MediaStream? _localStream;
  MediaDeviceState _state = MediaDeviceState.idle;
  MediaDeviceConfig _config = const MediaDeviceConfig();

  final _streamController = StreamController<MediaStream?>.broadcast();

  MediaStream? get localStream => _localStream;
  Stream<MediaStream?> get localStreamChanges => _streamController.stream;
  bool get isRunning => _state == MediaDeviceState.running;
  MediaDeviceState get state => _state;

  static const _errorMap = {
    'notallowed': CallError.permissionDenied,
    'permissiondenied': CallError.permissionDenied,
    'notfound': CallError.deviceNotFound,
    'overconstrained': CallError.deviceNotFound,
    'notreadable': CallError.deviceInUse,
    'trackstart': CallError.deviceInUse,
    'abort': CallError.aborted,
    'security': CallError.securityError,
    'type': CallError.invalidConfig,
  };

  Future<Result> startMediaDevices({MediaDeviceConfig? config}) async {
    if (_state == MediaDeviceState.running) {
      return const Failure(CallError.alreadyRunning, ErrorSource.mediaDevice);
    }

    if (config != null) _config = config;

    if (Platform.isAndroid) {
      final permissionResult = await _requestPermissions();
      if (permissionResult != null) {
        return Failure(permissionResult, ErrorSource.mediaDevice);
      }
    }

    try {
      _localStream = await navigator.mediaDevices.getUserMedia(_config.toMap());
      _state = MediaDeviceState.running;
      _streamController.add(_localStream);
      return Success(null);
    } catch (e) {
      final message = e.toString().toLowerCase();
      final error = _errorMap.entries
          .firstWhere(
            (entry) => message.contains(entry.key),
            orElse: () => MapEntry('', CallError.unknown),
          )
          .value;
      return Failure(error, ErrorSource.mediaDevice);
    }
  }

  Result stopMediaDevices() {
    if (_state != MediaDeviceState.running) {
      return const Failure(CallError.notRunning, ErrorSource.mediaDevice);
    }
    _stopTracks();
    _localStream?.dispose();
    _localStream = null;
    _state = MediaDeviceState.stopped;
    _streamController.add(null);
    return const Success(null);
  }

  Future<Result> restartMediaDevices({MediaDeviceConfig? config}) async {
    if (_state == MediaDeviceState.running) stopMediaDevices();
    return startMediaDevices(config: config);
  }

  void dispose() {
    _stopTracks();
    _localStream?.dispose();
    _localStream = null;
    _state = MediaDeviceState.idle;
    _streamController.close();
  }

  Result setAudioEnabled(bool enabled) {
    if (_state != MediaDeviceState.running) {
      return const Failure(CallError.notRunning, ErrorSource.mediaDevice);
    }
    for (final track in _localStream!.getAudioTracks()) {
      track.enabled = enabled;
    }
    return const Success(null);
  }

  Result setVideoEnabled(bool enabled) {
    if (_state != MediaDeviceState.running) {
      return const Failure(CallError.notRunning, ErrorSource.mediaDevice);
    }
    for (final track in _localStream!.getVideoTracks()) {
      track.enabled = enabled;
    }
    return const Success(null);
  }

  bool get isAudioEnabled =>
      _localStream?.getAudioTracks().any((t) => t.enabled) ?? false;

  bool get isVideoEnabled =>
      _localStream?.getVideoTracks().any((t) => t.enabled) ?? false;

  Future<Result> switchCamera() async {
    if (_state != MediaDeviceState.running) {
      return const Failure(CallError.notRunning, ErrorSource.mediaDevice);
    }
    try {
      final videoTrack = _localStream?.getVideoTracks().firstOrNull;
      if (videoTrack == null) {
        return const Failure(CallError.deviceNotFound, ErrorSource.mediaDevice);
      }
      await Helper.switchCamera(videoTrack);
      return const Success(null);
    } catch (e) {
      final message = e.toString().toLowerCase();
      final error = _errorMap.entries
          .firstWhere(
            (entry) => message.contains(entry.key),
            orElse: () => MapEntry('', CallError.unknown),
          )
          .value;
      return Failure(error, ErrorSource.mediaDevice);
    }
  }

  Future<CallError?> _requestPermissions() async {
    if (_config.video) {
      final camera = await Permission.camera.request();
      if (camera != PermissionStatus.granted) {
        return CallError.permissionDenied;
      }
    }
    if (_config.audio) {
      final microphone = await Permission.microphone.request();
      if (microphone != PermissionStatus.granted) {
        return CallError.permissionDenied;
      }
    }
    return null;
  }

  Future<List<MediaDeviceInfo>> enumerateDevices() async {
    return navigator.mediaDevices.enumerateDevices();
  }

  Future<List<MediaDeviceInfo>> getAudioInputDevices() async {
    final devices = await enumerateDevices();
    return devices.where((d) => d.kind == 'audioinput').toList();
  }

  Future<List<MediaDeviceInfo>> getVideoInputDevices() async {
    final devices = await enumerateDevices();
    return devices.where((d) => d.kind == 'videoinput').toList();
  }

  Future<Result> selectAudioDevice(String deviceId) async {
    if (_state != MediaDeviceState.running) {
      return const Failure(CallError.notRunning, ErrorSource.mediaDevice);
    }

    _config = _config.copyWith(audioDeviceId: deviceId);

    return _replaceTrack({
      'audio': {'deviceId': deviceId},
      'video': false,
    }, 'audio');
  }

  Future<Result> selectVideoDevice(String deviceId) async {
    if (_state != MediaDeviceState.running) {
      return const Failure(CallError.notRunning, ErrorSource.mediaDevice);
    }

    _config = _config.copyWith(videoDeviceId: deviceId);

    return _replaceTrack({
      'video': {'deviceId': deviceId},
      'audio': false,
    }, 'video');
  }

  Future<Result> _replaceTrack(
    Map<String, dynamic> constraints,
    String kind,
  ) async {
    MediaStream? tempStream;
    try {
      tempStream = await navigator.mediaDevices.getUserMedia(constraints);
      final newTrack = tempStream.getTracks().first;

      final oldTrack = _localStream!
          .getTracks()
          .where((t) => t.kind == kind)
          .firstOrNull;

      if (oldTrack != null) {
        await _localStream!.removeTrack(oldTrack);
        oldTrack.stop();
      }

      await _localStream!.addTrack(newTrack);
      _streamController.add(_localStream);

      tempStream.dispose();
      return const Success(null);
    } catch (e) {
      tempStream?.dispose();
      final message = e.toString().toLowerCase();
      final error =
          _errorMap.entries
              .where((entry) => message.contains(entry.key))
              .firstOrNull
              ?.value ??
          CallError.unknown;
      return Failure(error, ErrorSource.mediaDevice);
    }
  }

  void _stopTracks() {
    _localStream?.getTracks().forEach((t) => t.stop());
  }
}
