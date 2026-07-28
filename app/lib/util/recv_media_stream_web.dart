import 'package:dart_webrtc/dart_webrtc.dart' show MediaStreamWeb;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web/web.dart' as web;

Future<MediaStream> createRecvMediaStream(String label) async {
  // Any ownerTag other than 'local' leaves the HTMLAudioElement unmuted.
  return MediaStreamWeb(web.MediaStream(), 'remote-$label');
}
