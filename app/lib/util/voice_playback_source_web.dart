import 'dart:html' as html;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';

String? _activeBlobUrl;

Future<Source> voicePlaybackSource(Uint8List bytes, String mimeType) async {
  disposeVoicePlaybackSource(null);
  final blob = html.Blob([bytes], mimeType);
  _activeBlobUrl = html.Url.createObjectUrlFromBlob(blob);
  return UrlSource(_activeBlobUrl!);
}

void disposeVoicePlaybackSource(Source? source) {
  final url = _activeBlobUrl;
  if (url != null) {
    html.Url.revokeObjectUrl(url);
    _activeBlobUrl = null;
  }
}
