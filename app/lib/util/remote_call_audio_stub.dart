import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Native: playout is via the WebRTC ADM, not HTML audio elements.
Future<void> ensureRemoteCallAudioPlaying({
  RTCVideoRenderer? remoteRenderer,
}) async {}
