// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;

import 'media_permissions.dart';

/// Sticky results from a real getUserMedia attempt (click-time only).
/// null = never tried; true/false = last attempt outcome for this session.
bool? _micWorks;
bool? _camWorks;

_ListenerHandle? _deviceChangeSub;

/// Browser aliases and software-only sources that must not count as a mic.
bool _labelLooksFake(String label) {
  final l = label.toLowerCase().trim();
  if (l.isEmpty) return false;
  // Chromium pseudo-devices — not proof of hardware.
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
      s.contains('devicesnotfound');
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
  /// audioinput entries with empty labels (typical before permission).
  final bool unlabeledMic;
  final bool unlabeledCam;
}

/// Passive detection only — never opens mic/camera (no permission prompt).
Future<_DevicePresence> _detectDevices() async {
  final media = html.window.navigator.mediaDevices;
  if (media == null) {
    return const _DevicePresence(hasMic: false, hasCam: false);
  }
  try {
    final devices = await media.enumerateDevices();
    var hasMic = false;
    var hasCam = false;
    var unlabeledMic = false;
    var unlabeledCam = false;
    for (final d in devices) {
      final kind = d.kind ?? '';
      final label = (d.label ?? '').trim();
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
  var canQuery = false;
  final hasDisplayCapture = html.window.navigator.mediaDevices != null;
  String micPerm = 'unknown';
  String camPerm = 'unknown';

  try {
    final perms = html.window.navigator.permissions;
    if (perms != null) {
      canQuery = true;
      try {
        micPerm = (await perms.query({'name': 'microphone'})).state ?? 'unknown';
      } catch (_) {}
      try {
        camPerm = (await perms.query({'name': 'camera'})).state ?? 'unknown';
      } catch (_) {}
    }
  } catch (_) {}

  final devices = await _detectDevices();

  // Presence: sticky failure wins; else a real (non-fake) labeled device;
  // else allow one click probe while labels are still hidden (pre-permission).
  var hasMic = _micWorks == false
      ? false
      : (_micWorks == true ||
          devices.hasMic ||
          (_micWorks == null &&
              devices.unlabeledMic &&
              micPerm != 'denied'));
  var hasCam = _camWorks == false
      ? false
      : (_camWorks == true ||
          devices.hasCam ||
          (_camWorks == null &&
              devices.unlabeledCam &&
              camPerm != 'denied'));

  // Sticky success from a real getUserMedia counts as granted even when the
  // Permissions API is missing or still reports "unknown".
  var micGranted = (micPerm == 'granted' || _micWorks == true) && hasMic;
  var camGranted = (camPerm == 'granted' || _camWorks == true) && hasCam;

  if (micPerm == 'denied') micGranted = false;
  if (camPerm == 'denied') camGranted = false;

  return MediaPermissionStatus(
    hasMicrophone: hasMic,
    hasCamera: hasCam,
    micGranted: micGranted,
    cameraGranted: camGranted,
    canQuery: canQuery,
    hasDisplayCapture: hasDisplayCapture,
  );
}

/// Soft-prompts only when called from a user gesture (call icon click).
/// Skips getUserMedia entirely when the needed device is not detected.
Future<MediaPermissionStatus> requestMediaPermissions({
  bool camera = false,
}) async {
  final devices = await _detectDevices();
  final micListed = devices.hasMic || devices.unlabeledMic;

  if (!micListed && _micWorks != true) {
    // No mic listed — do not open the permission dialog.
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
    final stream = await html.window.navigator.mediaDevices!.getUserMedia({
      'audio': true,
      'video': camera,
    });
    // Any live track means the device works — do not reject Chrome's
    // "Default"/"Communications" labels here (those filters are for
    // enumerateDevices only). Rejecting them made videoReady false after
    // Allow and broke the call-start path.
    _micWorks = stream.getAudioTracks().isNotEmpty;
    if (camera) {
      _camWorks = stream.getVideoTracks().isNotEmpty;
    }
    for (final track in stream.getTracks()) {
      track.stop();
    }
    // Give the browser a beat to release the device before a later open.
    await Future<void>.delayed(const Duration(milliseconds: 120));
  } catch (e) {
    if (_isNotFound(e)) {
      _micWorks = false;
      if (camera) _camWorks = false;
    }
    // Permission denied / other — leave sticky hardware flags as-is.
  }
  return queryMediaPermissions();
}

/// Sticky success after the call path kept a live MediaStream.
void markMediaGranted({required bool mic, required bool camera}) {
  if (mic) _micWorks = true;
  if (camera) _camWorks = true;
}

/// Refresh call-button state when devices are plugged/unplugged.
void listenMediaDeviceChanges(void Function() onChange) {
  cancelMediaDeviceChanges();
  final media = html.window.navigator.mediaDevices;
  if (media == null) return;
  // dart:html MediaDevices has no typed onDeviceChange; use the DOM event.
  void handler(html.Event _) {
    _micWorks = null;
    _camWorks = null;
    onChange();
  }

  media.addEventListener('devicechange', handler);
  _deviceChangeSub = _ListenerHandle(media, handler);
}

void cancelMediaDeviceChanges() {
  _deviceChangeSub?.cancel();
  _deviceChangeSub = null;
}

class _ListenerHandle {
  _ListenerHandle(this._media, this._handler);
  final html.MediaDevices _media;
  final void Function(html.Event) _handler;
  void cancel() => _media.removeEventListener('devicechange', _handler);
}
