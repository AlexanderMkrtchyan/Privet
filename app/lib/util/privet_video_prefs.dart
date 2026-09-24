import 'package:video_player/video_player.dart';

/// Session-wide volume / mute / speed so opening the next clip feels the same.
class PrivetVideoPrefs {
  static double volume = 1.0;
  static bool muted = false;
  static double speed = 1.0;

  static double get effectiveVolume => muted ? 0 : volume;

  static Future<void> apply(VideoPlayerController controller) async {
    await controller.setVolume(effectiveVolume);
    await controller.setPlaybackSpeed(speed);
  }
}
