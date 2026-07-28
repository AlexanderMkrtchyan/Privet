import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Ensure local-preview playback does not echo, without muting the capture track.
///
/// Do **not** call [Helper.setMicrophoneMute] / `renderer.muted = true` here:
/// both set `track.enabled = false` on the shared mic track, which silences
/// outbound call audio while the UI still shows unmuted. Mute/unmute then
/// appears to "fix" the call by flipping `enabled` back on.
///
/// Web: flutter_webrtc already HTML-mutes local preview (`ownerTag == 'local'`).
/// Native: local capture is not looped to speakers by the embedder.
Future<void> muteLocalRenderer(RTCVideoRenderer renderer) async {
  // Intentionally a no-op — see doc comment above.
}
