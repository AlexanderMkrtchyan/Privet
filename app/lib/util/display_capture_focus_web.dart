// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web/web.dart' as web;

import 'display_share_surface.dart';

/// Whether this browser exposes the real Screen Capture API.
///
/// flutter_webrtc falls back to getUserMedia when getDisplayMedia is absent.
/// Mobile browsers can ignore that fallback's `mediaSource: screen` hint and
/// return the selfie camera, so callers must gate capture on this check.
bool get browserSupportsDisplayCapture {
  try {
    return web.window.navigator.mediaDevices
        .getProperty('getDisplayMedia'.toJS)
        .isDefinedAndNotNull;
  } catch (_) {
    return false;
  }
}

/// Chrome/Edge: share without bringing the picked window/tab to the front.
/// Full-monitor shares still show the browser "sharing" chip (platform limit).
///
/// Returns `null` when CaptureController is unavailable or constraints are
/// unsupported (caller should fall back). **Rethrows** user cancel so we never
/// open a second native picker after the user already dismissed one.
Future<MediaStream?> tryCaptureDisplayNoFocusChange({
  DisplayShareSurface? prefer,
}) async =>
    // CaptureController is not exposed by package:web yet. The caller's
    // capability-gated getDisplayMedia path remains safe and never falls back
    // to a mobile camera.
    null;
