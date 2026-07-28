// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Force-play the *remote* flutter_webrtc HTMLAudioElement only.
///
/// Never unmute the local renderer element — that echoes the mic and is the
/// wrong fix for call audio (see flutter-webrtc#1758).
Future<void> ensureRemoteCallAudioPlaying({
  RTCVideoRenderer? remoteRenderer,
}) async {
  if (remoteRenderer == null) return;
  final wantId = 'audio_RTCVideoRenderer-${remoteRenderer.textureId}';
  try {
    try {
      remoteRenderer.muted = false;
    } catch (_) {}
    final nodes = html.document.querySelectorAll('audio');
    for (final node in nodes) {
      final el = node;
      if (el is! html.AudioElement) continue;
      if (el.id != wantId) continue;
      el.muted = false;
      if (el.volume < 0.5) el.volume = 1;
      try {
        await el.play();
      } catch (_) {}
    }
  } catch (_) {}
}
