import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'dart:async';

import 'agent_debug_log.dart';
import 'media_permissions.dart';

/// Sticky results from a real getUserMedia attempt.
/// null = never tried; true/false = last attempt outcome for this session.
bool? _micWorks;
bool? _camWorks;

void Function(dynamic)? _deviceChangeHandler;

/// Aliases and software-only sources that must not count as a mic/camera.
bool _labelLooksFake(String label) {
  final l = label.toLowerCase().trim();
  if (l.isEmpty) return false;
  if (l == 'default' || l == 'communications') return true;
  return l.contains('dummy') ||
      l.contains('null') ||
      l.contains('monitor of') ||
      l.contains('virtual') ||
      l.contains('echo-cancel') ||
      l.contains('echo cancel') ||
      l.contains('echo_cancel') ||
      l.contains('echo enhancer') ||
      l.contains('echo-enhancer') ||
      l.contains('noise cancellation source');
}

bool _isNotFound(Object e) {
  final s = '$e'.toLowerCase();
  return s.contains('notfound') ||
      s.contains('not found') ||
      s.contains('requested device not found') ||
      s.contains('devicesnotfound') ||
      s.contains('notreadable') ||
      s.contains('device in use');
}

class _DevicePresence {
  const _DevicePresence({
    required this.hasMic,
    required this.hasCam,
    this.unlabeledMic = false,
    this.unlabeledCam = false,
  });
  final bool hasMic;
  final bool hasCam;
  final bool unlabeledMic;
  final bool unlabeledCam;
}

Future<_DevicePresence> _detectDevices() async {
  try {
    final devices = await navigator.mediaDevices.enumerateDevices();
    var hasMic = false;
    var hasCam = false;
    var unlabeledMic = false;
    var unlabeledCam = false;
    for (final d in devices) {
      final kind = d.kind ?? '';
      final label = (d.label).trim();
      if (kind == 'audioinput') {
        if (label.isEmpty) {
          unlabeledMic = true;
        } else if (!_labelLooksFake(label)) {
          hasMic = true;
        }
      } else if (kind == 'videoinput') {
        if (label.isEmpty) {
          unlabeledCam = true;
        } else if (!_labelLooksFake(label)) {
          hasCam = true;
        }
      }
    }
    return _DevicePresence(
      hasMic: hasMic,
      hasCam: hasCam,
      unlabeledMic: unlabeledMic,
      unlabeledCam: unlabeledCam,
    );
  } catch (_) {
    return const _DevicePresence(hasMic: false, hasCam: false);
  }
}

Future<MediaPermissionStatus> queryMediaPermissions() async {
  // #region agent log
  final sw = Stopwatch()..start();
  // #endregion
  final devices = await _detectDevices();
  // #region agent log
  agentDebugLog(
    hypothesisId: 'H8',
    location: 'media_permissions_native.dart:queryMediaPermissions',
    message: 'enumerateDevices done',
    data: {
      'elapsedMs': sw.elapsedMilliseconds,
      'hasMic': devices.hasMic,
      'hasCam': devices.hasCam,
    },
  );
  // #endregion

  // Presence: sticky failure wins; else a real labeled device; else allow
  // one click probe while labels are still empty.
  final hasMic = _micWorks == false
      ? false
      : (_micWorks == true ||
          devices.hasMic ||
          (_micWorks == null && devices.unlabeledMic));
  final hasCam = _camWorks == false
      ? false
      : (_camWorks == true ||
          devices.hasCam ||
          (_camWorks == null && devices.unlabeledCam));

  // Native desktop has no Permissions API — treat a present device as granted
  // until a sticky getUserMedia failure says otherwise.
  final micGranted = hasMic && _micWorks != false;
  final camGranted = hasCam && _camWorks != false;

  return MediaPermissionStatus(
    hasMicrophone: hasMic,
    hasCamera: hasCam,
    micGranted: micGranted,
    cameraGranted: camGranted,
    canQuery: true,
    hasDisplayCapture: true,
  );
}

Future<MediaPermissionStatus> requestMediaPermissions({
  bool camera = false,
}) async {
  final devices = await _detectDevices();
  final micListed = devices.hasMic || devices.unlabeledMic;

  if (!micListed && _micWorks != true) {
    if (_micWorks == null) _micWorks = false;
    if (camera &&
        !devices.hasCam &&
        !devices.unlabeledCam &&
        _camWorks == null) {
      _camWorks = false;
    }
    return queryMediaPermissions();
  }
  if (camera &&
      !devices.hasCam &&
      !devices.unlabeledCam &&
      _camWorks != true) {
    if (_camWorks == null) _camWorks = false;
    return queryMediaPermissions();
  }

  try {
    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': camera,
    });
    _micWorks = stream.getAudioTracks().isNotEmpty;
    if (camera) {
      _camWorks = stream.getVideoTracks().isNotEmpty;
    }
    for (final track in stream.getTracks()) {
      await track.stop();
    }
    await Future<void>.delayed(const Duration(milliseconds: 120));
  } catch (e) {
    if (_isNotFound(e)) {
      _micWorks = false;
      if (camera) _camWorks = false;
    }
  }
  return queryMediaPermissions();
}

void markMediaGranted({required bool mic, required bool camera}) {
  if (mic) _micWorks = true;
  if (camera) _camWorks = true;
}

void listenMediaDeviceChanges(void Function() onChange) {
  cancelMediaDeviceChanges();
  Timer? debounce;
  void handler(dynamic _) {
    _micWorks = null;
    _camWorks = null;
    debounce?.cancel();
    // PipeWire can spam devicechange while probing — coalesce.
    debounce = Timer(const Duration(seconds: 2), onChange);
  }

  _deviceChangeHandler = handler;
  navigator.mediaDevices.ondevicechange = handler;
}

void cancelMediaDeviceChanges() {
  if (_deviceChangeHandler != null &&
      identical(navigator.mediaDevices.ondevicechange, _deviceChangeHandler)) {
    navigator.mediaDevices.ondevicechange = null;
  }
  _deviceChangeHandler = null;
}
