/// "m:ss" clock for voice-note / audio players. Chat clips are short, so hours
/// are intentionally not handled.
String formatVoiceDuration(Duration duration) {
  final totalSeconds = duration.inSeconds;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '${minutes.toString()}:${seconds.toString().padLeft(2, '0')}';
}
