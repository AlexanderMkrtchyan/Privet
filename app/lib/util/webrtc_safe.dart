import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Mute local-preview playback without crashing on platforms where
/// `FlutterWebRTC.setMicrophoneMute` is unimplemented (Linux GTK).
///
/// Prefer this over `renderer.muted = true`: that setter fires an unawaited
/// Future, so a surrounding try/catch never sees [MissingPluginException].
Future<void> muteLocalRenderer(RTCVideoRenderer renderer) async {
  // Linux GTK build of flutter_webrtc has no setMicrophoneMute channel.
  // Capture is not looped to speakers by the embedder, so a no-op is fine.
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux) return;
  try {
    final stream = renderer.srcObject;
    if (stream == null) return;
    final tracks = stream.getAudioTracks();
    if (tracks.isEmpty) return;
    await Helper.setMicrophoneMute(true, tracks.first);
  } on MissingPluginException {
    // Other desktop targets may also lack the method — swallow quietly.
  } catch (_) {}
}
