# flutter-calling

A transport-agnostic WebRTC calling library for Flutter. Drop it in as a git submodule, bring your own signaling, get multi-peer audio/video calls.

## Overview

`flutter-calling` manages the full WebRTC peer connection lifecycle — SDP offer/answer exchange, ICE candidate management, media device control, and multi-peer tracking — without coupling to any specific signaling transport. You implement a single interface; the library handles the rest.

Designed as a git submodule, it integrates into any Flutter project that needs real-time peer-to-peer calling.

## Design Philosophy

**Transport-agnostic signaling.** The `TransientService` abstract class defines the contract for any real-time backend — Supabase, Firebase, WebSocket, custom. The calling logic never changes when you swap transports.

**Sealed `Result<T>` over exceptions.** Every fallible operation returns `Result<T>` with typed `CallError` enums. No try-catch for control flow. Exhaustive pattern matching in Dart 3 makes error handling explicit.

**Composition over inheritance.** `Peer` wraps an `RTCPeerConnection` rather than extending it. `IceCandidateManager` is composed into the orchestrator. Each component owns a single responsibility.

**Reactive streams for state.** Peer changes, local stream updates, and remote stream events are all exposed as broadcast streams. The UI layer subscribes; it never polls.

**Automatic resource disposal.** Every `StreamController`, `StreamSubscription`, `Timer`, and `RTCPeerConnection` is tracked and disposed. No leaked listeners.

## Quick Start

```dart
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_calling/flutter_calling.dart';

// 1. Start media devices
final mediaService = MediaDeviceService();
final result = await mediaService.startMediaDevices(
  config: const MediaDeviceConfig(audio: true, video: true),
);
if (result is Failure) return;

// 2. Configure and initialize the WebRTC manager
final manager = WebRtcManager(
  turnServers: [
    IceServerConfig(
      urls: ['turn:your-server.com:3478'],
      username: 'user',
      credential: 'pass',
    ),
  ],
  notifyWarning: (msg) => log('Warning: $msg'),
  notifyError: (msg) => log('Error: $msg'),
);

final initResult = await manager.initialize(
  yourTransientService,         // implement TransientService
  mediaService.localStream!,
  mediaService.localStreamChanges,
);
if (initResult is Failure) return;

// 3. React to peers joining/leaving
manager.peersChanges.listen((peers) {
  for (final entry in peers.entries) {
    final peerId = entry.key;
    final peer = entry.value;

    peer.remoteStreamChanges.listen((stream) {
      // Update your UI with the remote video/audio stream
    });
  }
});

// 4. Clean up when done
await manager.dispose();
await mediaService.dispose();
```

## Custom Transport

Implement `TransientService` to plug in any signaling backend:

```dart
class YourTransientService extends TransientService {
  final _offerController = StreamController<SignalingSdp>.broadcast();
  final _answerController = StreamController<SignalingSdp>.broadcast();
  final _iceController = StreamController<IceCandidatePayload>.broadcast();
  final _disconnectController = StreamController<String>.broadcast();

  @override
  String get id => 'your-peer-id';

  @override
  Future<Result<TransientConnectionInfo>> connect() async {
    // Connect to your signaling channel
    // Return existing peer IDs already in the room
    return Success(TransientConnectionInfo(existingPeerIds: []));
  }

  @override
  Future<Result<void>> sendPayload(
    String event,
    SignalingPayload payload,
  ) async {
    // Send the payload to your signaling backend
    return const Success(null);
  }

  @override
  Stream<SignalingSdp> get offerStream => _offerController.stream;

  @override
  Stream<SignalingSdp> get answerStream => _answerController.stream;

  @override
  Stream<IceCandidatePayload> get iceCandidateStream => _iceController.stream;

  @override
  Stream<String> get peerDisconnectedStream => _disconnectController.stream;

  @override
  Future<void> dispose() async {
    await _offerController.close();
    await _answerController.close();
    await _iceController.close();
    await _disconnectController.close();
  }
}
```

Feed incoming signaling messages into the appropriate stream controllers. The library handles SDP negotiation, ICE candidate exchange, and retry logic automatically.

## Media Devices

`MediaDeviceService` manages camera and microphone lifecycle independently of the calling layer.

```dart
final service = MediaDeviceService();
await service.startMediaDevices(
  config: const MediaDeviceConfig(
    audio: true,
    video: true,
    preferFrontCamera: true,
  ),
);

// Toggle mute
service.setAudioEnabled(false);

// Toggle video
service.setVideoEnabled(false);

// Switch front/back camera
await service.switchCamera();

// Enumerate and select specific devices
final cameras = await service.getVideoInputDevices();
if (cameras.isNotEmpty) {
  await service.selectVideoDevice(cameras.first.deviceId);
}

// React to stream changes (e.g., after device swap)
service.localStreamChanges.listen((stream) {
  // Stream updated — re-render local preview if needed
});

await service.dispose();
```

## Error Handling

Every operation returns a sealed `Result<T>`. Pattern-match to handle errors explicitly:

```dart
final result = await service.startMediaDevices();
if (result is Failure) {
  switch (result.error) {
    case CallError.permissionDenied:
      // Show permission request UI
    case CallError.deviceNotFound:
      // Fallback to audio-only
    case CallError.deviceInUse:
      // Retry or notify user
    default:
      // Unexpected — log and recover
  }
}
```

### Error Taxonomy

| Category | Error | Description |
|----------|-------|-------------|
| **Media** | `permissionDenied` | Camera or microphone permission denied |
| | `deviceNotFound` | Requested device unavailable or overconstrained |
| | `deviceInUse` | Device already claimed by another process |
| | `aborted` | Operation aborted by the system |
| | `securityError` | Security policy violation |
| | `invalidConfig` | Invalid media constraints |
| | `alreadyRunning` | Tried to start devices that are already running |
| | `notRunning` | Tried to operate on stopped devices |
| **WebRTC** | `peerConnectionFailed` | Failed to create or configure peer connection |
| | `noLocalStream` | No local stream available when required |
| | `noRemoteStream` | No remote stream received from peer |
| | `signalingFailed` | SDP offer/answer creation failed |
| | `iceFailed` | ICE connectivity check failed |
| **Transient** | `notConnected` | Signaling channel not connected |
| | `channelError` | Error in signaling transport |
| | `timeout` | Operation timed out (e.g., pending SDP answer) |
| **General** | `unknown` | Unrecognized error |

## API Reference

### `WebRtcManager`

| Member | Type | Description |
|--------|------|-------------|
| `WebRtcManager({stunServers, turnServers, notifyWarning, notifyError})` | Constructor | Configure ICE servers and optional notification callbacks |
| `peersChanges` | `Stream<Map<String, Peer>>` | Reactive stream emitting the full peer map on any change |
| `initialize(transientService, localStream, localStreamChanges)` | `Future<Result>` | Connect to signaling, discover peers, and begin SDP negotiation |
| `dispose()` | `Future<void>` | Tear down all peer connections, subscriptions, and controllers |

### `Peer`

| Member | Type | Description |
|--------|------|-------------|
| `peerConnection` | `RTCPeerConnection` | The underlying WebRTC connection |
| `remoteStream` | `MediaStream?` | Current remote media stream (may be null before tracks arrive) |
| `remoteStreamChanges` | `Stream<MediaStream?>` | Stream of remote stream updates as tracks are added/removed |

### `MediaDeviceService`

| Member | Type | Description |
|--------|------|-------------|
| `startMediaDevices({config})` | `Future<Result>` | Acquire camera/microphone with the given constraints |
| `stopMediaDevices()` | `Future<Result>` | Release media tracks and dispose the stream |
| `restartMediaDevices({config})` | `Future<Result>` | Stop then start with new or existing config |
| `setAudioEnabled(bool)` | `Result` | Mute/unmute the microphone |
| `setVideoEnabled(bool)` | `Result` | Enable/disable the camera |
| `switchCamera()` | `Future<Result>` | Toggle between front and back camera |
| `enumerateDevices()` | `Future<List<MediaDeviceInfo>>` | List all available media devices |
| `getAudioInputDevices()` | `Future<List<MediaDeviceInfo>>` | Filter to audio input devices only |
| `getVideoInputDevices()` | `Future<List<MediaDeviceInfo>>` | Filter to video input devices only |
| `selectAudioDevice(String deviceId)` | `Future<Result>` | Hot-swap the active audio input device |
| `selectVideoDevice(String deviceId)` | `Future<Result>` | Hot-swap the active video input device |
| `localStream` | `MediaStream?` | Current local media stream |
| `localStreamChanges` | `Stream<MediaStream?>` | Stream emitted when the local stream changes |
| `isRunning` | `bool` | Whether media devices are currently active |
| `isAudioEnabled` | `bool` | Whether the microphone track is enabled |
| `isVideoEnabled` | `bool` | Whether the camera track is enabled |

### `TransientService` (interface)

| Member | Type | Description |
|--------|------|-------------|
| `id` | `String` | Unique identifier for this peer |
| `connect()` | `Future<Result<TransientConnectionInfo>>` | Establish signaling connection; return existing peer IDs |
| `sendPayload(event, payload)` | `Future<Result<void>>` | Send a signaling payload (offer, answer, or ICE candidate) |
| `offerStream` | `Stream<SignalingSdp>` | Incoming SDP offers |
| `answerStream` | `Stream<SignalingSdp>` | Incoming SDP answers |
| `iceCandidateStream` | `Stream<IceCandidatePayload>` | Incoming ICE candidates |
| `peerDisconnectedStream` | `Stream<String>` | Peer IDs of disconnected peers |
| `dispose()` | `Future<void>` | Clean up signaling resources |

## Architecture

```
flutter-calling/
├── webrtc_manager.dart          Orchestrator — full call lifecycle, peer tracking
├── models/
│   ├── result.dart              Sealed Result<T> type, CallError enum, ErrorSource enum
│   ├── peer.dart                Peer — wraps RTCPeerConnection + remote stream
│   ├── pending_answer.dart      PendingAnswer — awaits SDP answer with retry/timeout
│   ├── signaling_payload.dart   SDP and ICE candidate payload models
│   └── ice_server_config.dart   STUN/TURN server configuration
├── services/
│   ├── transient_service.dart   Abstract signaling interface (the extension point)
│   ├── ice_candidate_manager.dart   ICE candidate send/receive + buffering
│   └── media_device_service.dart    Camera/mic lifecycle, device enumeration/selection
└── helpers/
    ├── retry_helper.dart        Generic retry wrapper for Result-returning operations
    ├── stream_awaiter.dart      Wait-for-stream-event with timeout and retry
    ├── timeout_handler.dart     Disposable timer wrapper
    └── webrtc_helpers.dart      Low-level WebRTC utilities (createPeerConnection, createOffer, etc.)
```

## Dependencies

Your host Flutter project needs:

```yaml
dependencies:
  flutter_webrtc: ^1.4.1
  permission_handler: ^12.0.1
```

No additional dependencies are required inside the submodule — it uses only `dart:async`, `dart:io`, and `package:flutter/foundation.dart` from the Dart/Flutter SDKs.

## License

AGPL-3.0 — see [LICENSE](LICENSE).
