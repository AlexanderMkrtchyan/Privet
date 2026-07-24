import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'display_share_surface.dart';

/// Non-web: CaptureController is unavailable.
Future<MediaStream?> tryCaptureDisplayNoFocusChange({
  DisplayShareSurface? prefer,
}) async =>
    null;
