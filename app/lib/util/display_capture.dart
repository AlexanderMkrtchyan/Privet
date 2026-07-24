import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'browser_kind.dart';
import 'display_capture_focus.dart';
import 'display_share_surface.dart';

export 'display_share_surface.dart';

/// Capture a display surface with Linux/Ubuntu-friendly constraint fallbacks.
///
/// Chromium on Ubuntu often throws `NotFoundError` / "Requested device not found"
/// when PipeWire / xdg-desktop-portal is missing, or when overly strict
/// constraints (esp. `audio: false`) are passed. We try several shapes and
/// surface a clear fix hint.
///
/// [prefer] is a soft hint for Chrome's native picker (Entire screen /
/// Window / Tab). The browser still shows its own dialog — web apps cannot
/// replace that UI. Firefox ignores [prefer] and rejects Chromium-only
/// constraints — we use a single plain `getDisplayMedia` there so the native
/// picker never opens twice.
Future<MediaStream> captureDisplayMedia({
  DisplayShareSurface? prefer,
}) async {
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
      'video': {
        'cursor': 'always',
      },
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

Map<String, dynamic> _constraintsFor(DisplayShareSurface prefer) {
  switch (prefer) {
    case DisplayShareSurface.monitor:
      return {
        'video': {
          'displaySurface': 'monitor',
          'cursor': 'always',
        },
        'audio': false,
      };
    case DisplayShareSurface.window:
      return {
        'video': {
          'displaySurface': 'window',
          'cursor': 'always',
        },
        'audio': false,
      };
    case DisplayShareSurface.browser:
      return {
        'video': {
          'displaySurface': 'browser',
          'cursor': 'always',
        },
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
      s.contains('devicesnotfound');
}

String _friendlyDisplayError(Object? e) {
  if (_isNotFound(e)) {
    return 'Screen capture not available (device not found). '
        'On Ubuntu: install PipeWire + a desktop portal, then restart the browser — '
        'e.g. `sudo apt install pipewire wireplumber xdg-desktop-portal '
        'xdg-desktop-portal-gnome` (or `-kde`). '
        'If Chrome is a Snap, try the .deb build. ($e)';
  }
  return 'Screen share failed: $e';
}
