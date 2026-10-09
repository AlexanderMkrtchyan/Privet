import 'dart:typed_data';

import 'pronunciation_result.dart';

/// Web build has no local pronunciation model.
Future<void> ensurePronunciationServer({
  Duration timeout = const Duration(seconds: 90),
}) async {
  throw StateError('Pronunciation check runs on the Linux desktop app');
}

Future<PronunciationAssessment> assessPronunciation(
  Uint8List wav,
  String text,
) async {
  throw StateError('Pronunciation check runs on the Linux desktop app');
}

Future<bool> pronunciationModelReady() async => false;
