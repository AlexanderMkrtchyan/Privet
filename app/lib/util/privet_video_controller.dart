import 'package:video_player/video_player.dart';

import 'privet_video_controller_stub.dart'
    if (dart.library.io) 'privet_video_controller_io.dart' as impl;

/// Opens a chat video: local file when cached (native), otherwise the
/// remote URL. Always call [tunePrivetVideoController] after [initialize].
VideoPlayerController createPrivetVideoController(String url) =>
    impl.createPrivetVideoController(url);

/// Desktop (fvp) only: enlarge the demux buffer so network VOD does not
/// underrun every few seconds. No-op on web.
void tunePrivetVideoController(VideoPlayerController controller) =>
    impl.tunePrivetVideoController(controller);
