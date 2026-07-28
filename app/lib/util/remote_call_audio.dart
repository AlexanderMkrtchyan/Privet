import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'remote_call_audio_stub.dart'
    if (dart.library.html) 'remote_call_audio_web.dart'
    as impl;

/// Ensure remote WebRTC audio is audible (web autoplay / element mute).
Future<void> ensureRemoteCallAudioPlaying({
  RTCVideoRenderer? remoteRenderer,
}) =>
    impl.ensureRemoteCallAudioPlaying(remoteRenderer: remoteRenderer);
