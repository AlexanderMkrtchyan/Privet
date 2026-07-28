import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'recv_media_stream_stub.dart'
    if (dart.library.html) 'recv_media_stream_web.dart'
    as impl;

/// MediaStream for remote tracks. On web, must NOT use ownerTag `local` —
/// flutter_webrtc HTML-mutes audio elements when ownerTag == 'local'.
Future<MediaStream> createRecvMediaStream(String label) =>
    impl.createRecvMediaStream(label);
