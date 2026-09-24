import 'dart:io';

import 'package:fvp/fvp.dart';
import 'package:video_player/video_player.dart';

import 'video_cache.dart';

final _options = VideoPlayerOptions(mixWithOthers: true);

VideoPlayerController createPrivetVideoController(String url) {
  final path = videoCachePathSync(url);
  if (path != null) {
    return VideoPlayerController.file(File(path), videoPlayerOptions: _options);
  }
  // Do not start a second full GET here — that races the player's Range
  // requests through Cloudflare and makes first play slower, not faster.
  return VideoPlayerController.networkUrl(
    Uri.parse(url),
    httpHeaders: const {'Accept': 'video/*,*/*;q=0.8'},
    videoPlayerOptions: _options,
  );
}

void tunePrivetVideoController(VideoPlayerController controller) {
  try {
    // Start as soon as ~400ms is buffered. Keep a longer tail so a blip
    // does not stall, but do not wait seconds before the first frame.
    controller.setBufferRange(min: 400, max: 20000);
  } catch (_) {}
}
