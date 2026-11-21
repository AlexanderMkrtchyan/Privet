import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

/// Top-left position for the floating mini-call bar, kept inside [screen].
///
/// Phones are narrower than the desktop bar (480px default). Subtraction can
/// go negative there, and `num.clamp(8, negative)` throws `ArgumentError` —
/// that exception blanked the call and froze the app when minimizing on
/// Android. The clamp range is therefore always valid, even when the bar is
/// larger than the screen (it simply pins to the top-left corner).
Offset miniCallDefaultOffset(Size screen, Size bar) {
  final maxX = math.max(0.0, screen.width - bar.width);
  final maxY = math.max(0.0, screen.height - bar.height);
  return Offset(
    (screen.width - bar.width - 16).clamp(0.0, maxX),
    (screen.height - bar.height - 16).clamp(0.0, maxY),
  );
}
