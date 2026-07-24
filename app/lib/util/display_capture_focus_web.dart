// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:js_util' as js_util;

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'display_share_surface.dart';

/// Chrome/Edge: share without bringing the picked window/tab to the front.
/// Full-monitor shares still show the browser "sharing" chip (platform limit).
///
/// Returns `null` when CaptureController is unavailable or constraints are
/// unsupported (caller should fall back). **Rethrows** user cancel so we never
/// open a second native picker after the user already dismissed one.
Future<MediaStream?> tryCaptureDisplayNoFocusChange({
  DisplayShareSurface? prefer,
}) async {
  try {
    final ctor = js_util.getProperty(js_util.globalThis, 'CaptureController');
    if (ctor == null) return null;
    final controller = js_util.callConstructor(ctor, []);
    js_util.callMethod(controller, 'setFocusBehavior', ['no-focus-change']);

    final constraints = <String, dynamic>{
      'controller': controller,
      'audio': false,
    };
    switch (prefer) {
      case DisplayShareSurface.monitor:
        constraints['video'] = {
          'displaySurface': 'monitor',
          'cursor': 'always',
        };
      case DisplayShareSurface.window:
        constraints['video'] = {
          'displaySurface': 'window',
          'cursor': 'always',
        };
      case DisplayShareSurface.browser:
        constraints['video'] = {
          'displaySurface': 'browser',
          'cursor': 'always',
        };
        // Let the user pick any tab (not only this one).
        constraints['selfBrowserSurface'] = 'include';
      case null:
        constraints['video'] = true;
    }

    return await navigator.mediaDevices.getDisplayMedia(constraints);
  } catch (e) {
    if (_isUserCancel(e)) {
      // Do not fall back — that would show the native picker a second time.
      throw StateError('Screen share cancelled.');
    }
    return null;
  }
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
