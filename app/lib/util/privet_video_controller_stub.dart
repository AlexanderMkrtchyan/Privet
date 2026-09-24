import 'package:video_player/video_player.dart';

final _options = VideoPlayerOptions(mixWithOthers: true);

VideoPlayerController createPrivetVideoController(String url) {
  return VideoPlayerController.networkUrl(
    Uri.parse(url),
    httpHeaders: const {'Accept': 'video/*,*/*;q=0.8'},
    videoPlayerOptions: _options,
  );
}

void tunePrivetVideoController(VideoPlayerController controller) {}
