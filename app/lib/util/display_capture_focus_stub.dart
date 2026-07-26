import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'display_share_surface.dart';

/// Native platforms do not use the browser capability gate.
bool get browserSupportsDisplayCapture => true;

/// Non-web: CaptureController is unavailable.
Future<MediaStream?> tryCaptureDisplayNoFocusChange({
  DisplayShareSurface? prefer,
}) async => null;
