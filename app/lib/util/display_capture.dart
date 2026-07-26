import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'browser_kind.dart';
import 'display_capture_focus.dart';
import 'display_share_surface.dart';

export 'display_share_surface.dart';

const _screenCaptureChannel = MethodChannel('privet/screen_capture');

/// Last [sourceId] passed to [captureDisplayMedia] (native desktop).
String? lastDesktopCaptureSourceId;

/// Capture a display surface.
///
/// **Web:** Chromium on Ubuntu often throws `NotFoundError` when PipeWire /
/// xdg-desktop-portal is missing, or when overly strict constraints are
/// passed. We try several shapes and surface a clear fix hint.
///
/// **Native desktop (Linux/Windows/macOS):** flutter_webrtc requires a
/// [DesktopCapturer] source id — bare `getDisplayMedia` fails with
/// "source not found!". Pass [sourceId] from the picker, or we auto-pick
/// the first screen/window matching [prefer].
///
/// [prefer] is a soft hint (Chrome picker / desktop source type). The OS
/// still shows its own dialog on web. Firefox ignores [prefer] and rejects
/// Chromium-only constraints — we use a single plain `getDisplayMedia`
/// there so the native picker never opens twice.
Future<MediaStream> captureDisplayMedia({
  DisplayShareSurface? prefer,
  String? sourceId,
}) async {
  lastDesktopCaptureSourceId = sourceId;
  if (WebRTC.platformIsDesktop) {
    return _captureDesktop(prefer: prefer, sourceId: sourceId);
  }

  if (WebRTC.platformIsAndroid) {
    return _captureAndroid();
  }

  // Never let flutter_webrtc's web fallback turn "share screen" into camera.
  // When getDisplayMedia is missing (notably iOS/Android PWA browsers), the
  // package calls getUserMedia with a non-standard mediaSource constraint.
  // Mobile Chromium/WebKit may ignore it and return the front camera.
  if (!browserSupportsDisplayCapture) {
    throw StateError(
      'Screen sharing is not supported by this mobile browser. '
      'You can still watch a screen shared from the desktop or Android app.',
    );
  }

  // Firefox: one plain capture. Chromium-only constraints (displaySurface,
  // CaptureController, selfBrowserSurface) either no-op or fail and would
  // reopen the portal picker on each fallback attempt.
  if (isFirefoxBrowser) {
    try {
      final stream = await navigator.mediaDevices.getDisplayMedia({
        'video': true,
      });
      await stripDisplayAudioTracks(stream);
      return stream;
    } catch (e) {
      if (_isUserCancel(e)) {
        throw StateError('Screen share cancelled.');
      }
      throw StateError(_friendlyDisplayError(e));
    }
  }

  // Prefer CaptureController so Chrome/Edge don't steal focus to the shared
  // window/tab (Teams keeps the meeting UI usable; browsers default to focus).
  // User cancel is rethrown — never open a second native picker.
  final preferNoFocus = await tryCaptureDisplayNoFocusChange(prefer: prefer);
  if (preferNoFocus != null) {
    await stripDisplayAudioTracks(preferNoFocus);
    return preferNoFocus;
  }

  final attempts = <Map<String, dynamic>>[
    if (prefer != null) _constraintsFor(prefer),
    // Prefer video-only without an audio key — most reliable on Linux Chrome.
    {'video': true},
    {'video': true, 'audio': false},
    {
      'video': {'cursor': 'always'},
    },
    <String, dynamic>{},
  ];

  Object? last;
  for (final constraints in attempts) {
    try {
      final stream = await navigator.mediaDevices.getDisplayMedia(constraints);
      // Browsers may still attach tab/system audio (e.g. "Share tab audio").
      // That captures our call ringback into the stream and keeps playing it
      // through the local/remote video element after the HTML tone is stopped.
      await stripDisplayAudioTracks(stream);
      return stream;
    } catch (e) {
      last = e;
      if (_isUserCancel(e)) {
        // Stop retrying — each attempt would re-open the native picker.
        throw StateError('Screen share cancelled.');
      }
    }
  }

  throw StateError(_friendlyDisplayError(last));
}

/// Android requires a media-projection foreground service before the app is
/// backgrounded, otherwise switching to the shared app freezes the capture.
Future<MediaStream> _captureAndroid() async {
  var serviceStarted = false;
  try {
    final granted = await Helper.requestCapturePermission();
    if (!granted) throw StateError('Screen share cancelled.');
    await _screenCaptureChannel.invokeMethod<void>('start');
    serviceStarted = true;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final stream = await navigator.mediaDevices.getDisplayMedia({
      'video': true,
      'audio': false,
    });
    await stripDisplayAudioTracks(stream);
    return stream;
  } catch (e) {
    if (serviceStarted) {
      await stopDisplayCaptureService();
    }
    if (e is StateError) rethrow;
    if (_isUserCancel(e)) throw StateError('Screen share cancelled.');
    throw StateError(_friendlyDisplayError(e));
  }
}

/// Release Android's foreground screen-capture notification/service.
Future<void> stopDisplayCaptureService() async {
  if (!WebRTC.platformIsAndroid) return;
  try {
    await _screenCaptureChannel.invokeMethod<void>('stop');
  } catch (_) {}
}

/// Native desktop: list sources via DesktopCapturer, then capture by id.
Future<MediaStream> _captureDesktop({
  DisplayShareSurface? prefer,
  String? sourceId,
}) async {
  try {
    final types = _desktopTypesFor(prefer);
    // Populate the native plugin's source list — getDisplayMedia looks up
    // by id in that list and fails with "source not found!" otherwise.
    final sources = await desktopCapturer.getSources(
      types: types,
      thumbnailSize: ThumbnailSize(160, 90),
    );
    if (sources.isEmpty) {
      throw StateError(
        'No screens or windows available to share. '
        'On Wayland, grant screen sharing permission when prompted.',
      );
    }

    final id = sourceId ?? sources.first.id;
    if (sourceId != null && !sources.any((s) => s.id == sourceId)) {
      // Source may have closed; refresh both types once.
      final all = await desktopCapturer.getSources(
        types: [SourceType.Screen, SourceType.Window],
        thumbnailSize: ThumbnailSize(160, 90),
      );
      if (!all.any((s) => s.id == sourceId)) {
        throw StateError(
          'That screen or window is no longer available. Pick again.',
        );
      }
    }

    final stream = await navigator.mediaDevices.getDisplayMedia({
      'video': {
        'deviceId': {'exact': id},
        'mandatory': {'frameRate': 30.0},
      },
    });
    await stripDisplayAudioTracks(stream);
    return stream;
  } catch (e) {
    if (e is StateError) rethrow;
    if (_isUserCancel(e)) {
      throw StateError('Screen share cancelled.');
    }
    throw StateError(_friendlyDisplayError(e));
  }
}

List<SourceType> _desktopTypesFor(DisplayShareSurface? prefer) {
  switch (prefer) {
    case DisplayShareSurface.window:
      return [SourceType.Window];
    case DisplayShareSurface.browser:
      // Native apps cannot capture browser tabs — fall back to windows.
      return [SourceType.Window];
    case DisplayShareSurface.monitor:
    case null:
      return [SourceType.Screen];
  }
}

/// Enumerate desktop screens for remote-control display switching.
Future<List<DesktopCapturerSource>> listDesktopScreens() async {
  if (!WebRTC.platformIsDesktop) return const [];
  try {
    return await desktopCapturer.getSources(
      types: [SourceType.Screen],
      thumbnailSize: ThumbnailSize(160, 90),
    );
  } catch (_) {
    return const [];
  }
}

Map<String, dynamic> _constraintsFor(DisplayShareSurface prefer) {
  switch (prefer) {
    case DisplayShareSurface.monitor:
      return {
        'video': {'displaySurface': 'monitor', 'cursor': 'always'},
        'audio': false,
      };
    case DisplayShareSurface.window:
      return {
        'video': {'displaySurface': 'window', 'cursor': 'always'},
        'audio': false,
      };
    case DisplayShareSurface.browser:
      return {
        'video': {'displaySurface': 'browser', 'cursor': 'always'},
        'audio': false,
        // Include this tab among options; do not force "current tab only".
        'selfBrowserSurface': 'include',
      };
  }
}

/// Drop any audio tracks from a display capture — Privet screen share is video-only.
///
/// Also seals the stream so a late browser-added audio track (tab/system audio)
/// is stopped immediately — otherwise ringback can loop through the call
/// video/audio element after the HTML tone is stopped.
Future<void> stripDisplayAudioTracks(MediaStream stream) async {
  Future<void> drop(MediaStreamTrack track) async {
    try {
      await stream.removeTrack(track);
    } catch (_) {}
    try {
      await track.stop();
    } catch (_) {}
  }

  for (final track in List<MediaStreamTrack>.from(stream.getAudioTracks())) {
    await drop(track);
  }

  // Replace any prior handler — one seal per display stream is enough.
  stream.onAddTrack = (MediaStreamTrack track) {
    if (track.kind == 'audio') {
      unawaited(drop(track));
    }
  };
}

bool _isUserCancel(Object e) {
  final s = '$e'.toLowerCase();
  return s.contains('notallowed') ||
      s.contains('not allowed') ||
      s.contains('permission denied') ||
      s.contains('abort') ||
      s.contains('cancelled') ||
      s.contains('canceled');
}

bool _isNotFound(Object? e) {
  if (e == null) return false;
  final s = '$e'.toLowerCase();
  return s.contains('notfound') ||
      s.contains('not found') ||
      s.contains('requested device not found') ||
      s.contains('devicesnotfound') ||
      s.contains('source not found');
}

String _friendlyDisplayError(Object? e) {
  if (_isNotFound(e)) {
    if (WebRTC.platformIsDesktop) {
      return 'Screen capture failed (source not found). '
          'Pick a screen or window from the Share dialog and try again. ($e)';
    }
    return 'Screen capture not available (device not found). '
        'On Ubuntu: install PipeWire + a desktop portal, then restart the browser — '
        'e.g. `sudo apt install pipewire wireplumber xdg-desktop-portal '
        'xdg-desktop-portal-gnome` (or `-kde`). '
        'If Chrome is a Snap, try the .deb build. ($e)';
  }
  return 'Screen share failed: $e';
}
