import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Draws [controller] into the available box at the video's aspect ratio.
///
/// The [VideoPlayer] is passed as [ValueListenableBuilder.child] so position
/// ticks do not rebuild the texture. Layout uses the *display* box — never the
/// source pixel size — so a 1080p clip in a chat bubble is not composited as
/// a 1920×1080 layer every frame.
class PrivetVideoSurface extends StatelessWidget {
  const PrivetVideoSurface({super.key, required this.controller});

  final VideoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, child) {
        final ar = value.aspectRatio <= 0 ? 16 / 9 : value.aspectRatio;
        return ColoredBox(
          color: Colors.black,
          child: Center(
            child: AspectRatio(
              aspectRatio: ar,
              child: child,
            ),
          ),
        );
      },
      child: VideoPlayer(controller),
    );
  }
}
