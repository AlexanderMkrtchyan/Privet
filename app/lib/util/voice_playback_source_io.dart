import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';

Future<Source> voicePlaybackSource(Uint8List bytes, String mimeType) async {
  return BytesSource(bytes, mimeType: mimeType);
}

void disposeVoicePlaybackSource(Source? source) {}
