/// Clock label for video chrome (`m:ss` or `h:mm:ss`).
String formatVideoClock(Duration duration) {
  final total = duration.inSeconds;
  final safe = total < 0 ? 0 : total;
  final h = safe ~/ 3600;
  final m = (safe % 3600) ~/ 60;
  final s = safe % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

/// Playback speeds offered by the player chrome.
const List<double> kPrivetVideoSpeeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

double nextPrivetVideoSpeed(double current) {
  final i = kPrivetVideoSpeeds.indexWhere((s) => (s - current).abs() < 0.01);
  if (i < 0) return 1.0;
  return kPrivetVideoSpeeds[(i + 1) % kPrivetVideoSpeeds.length];
}
