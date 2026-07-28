import 'package:flutter_webrtc/flutter_webrtc.dart';

Future<MediaStream> createRecvMediaStream(String label) =>
    createLocalMediaStream(label);
