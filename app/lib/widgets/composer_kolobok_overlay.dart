import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../theme.dart';
import '../util/kolobok_images.dart';
import '../util/low_resource.dart';
import 'composer_autocorrect_controller.dart';

/// Paints Kolobok art over hidden composer glyphs (same trick as message bodies).
///
/// Sit in a [Stack] above the [TextField] under [IgnorePointer] so clicks still
/// reach the editable.
class ComposerKolobokOverlay extends StatefulWidget {
  const ComposerKolobokOverlay({
    super.key,
    required this.fieldKey,
    required this.controller,
  });

  final GlobalKey fieldKey;
  final ComposerAutocorrectController controller;

  @override
  State<ComposerKolobokOverlay> createState() => _ComposerKolobokOverlayState();
}

class _ComposerKolobokOverlayState extends State<ComposerKolobokOverlay> {
  final GlobalKey _paintKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    if (privetLowResource) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.controller,
        KolobokImageCache.instance,
      ]),
      builder: (context, _) {
        return CustomPaint(
          key: _paintKey,
          painter: _ComposerKolobokPainter(
            fieldKey: widget.fieldKey,
            paintKey: _paintKey,
            spans: widget.controller.kolobokSpans,
            light: PrivetTheme.isLight,
            generation: KolobokImageCache.instance.generation,
            clockMs: KolobokImageCache.instance.clockMs,
          ),
        );
      },
    );
  }
}

class _ComposerKolobokPainter extends CustomPainter {
  _ComposerKolobokPainter({
    required this.fieldKey,
    required this.paintKey,
    required this.spans,
    required this.light,
    required this.generation,
    required this.clockMs,
  });

  final GlobalKey fieldKey;
  final GlobalKey paintKey;
  final List<ComposerKolobokSpan> spans;
  final bool light;
  final int generation;
  final int clockMs;

  /// Match chat body: no overshoot on Android/Linux (avoids covering typed text).
  static double get _overshoot {
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.linux)) {
      return 1.0;
    }
    return 1.4;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (spans.isEmpty) return;
    final editable = _findEditable(fieldKey.currentContext);
    final paintBox = paintKey.currentContext?.findRenderObject();
    if (editable == null || !editable.hasSize) return;
    if (paintBox is! RenderBox || !paintBox.hasSize) return;

    final origin =
        editable.localToGlobal(Offset.zero) - paintBox.localToGlobal(Offset.zero);
    final cache = KolobokImageCache.instance;
    final paint = Paint()..filterQuality = FilterQuality.high;
    final plainLen = editable.text?.toPlainText().length ?? 0;
    final overshoot = _overshoot;

    for (final span in spans) {
      if (span.end > plainLen) continue;
      final image = cache.frameFor(span.file, light: light);
      if (image == null) continue;
      final boxes = editable.getBoxesForSelection(
        TextSelection(baseOffset: span.start, extentOffset: span.end),
      );
      if (boxes.isEmpty) continue;
      final source = Rect.fromLTWH(
        0,
        0,
        image.width.toDouble(),
        image.height.toDouble(),
      );
      for (final box in boxes) {
        final rect = box.toRect().shift(origin);
        final scale = (rect.width / image.width < rect.height / image.height
                ? rect.width / image.width
                : rect.height / image.height) *
            overshoot;
        final dest = Rect.fromCenter(
          center: rect.center,
          width: image.width * scale,
          height: image.height * scale,
        );
        // Inline with typed text — skip the dark-UI white halo.
        canvas.drawImageRect(image, source, dest, paint);
      }
    }
  }

  static RenderEditable? _findEditable(BuildContext? ctx) {
    if (ctx == null) return null;
    RenderEditable? editable;
    void visitor(Element el) {
      if (editable != null) return;
      final ro = el.renderObject;
      if (ro is RenderEditable) {
        editable = ro;
        return;
      }
      el.visitChildren(visitor);
    }

    final root = ctx.findRenderObject();
    if (root is RenderEditable) return root;
    ctx.visitChildElements(visitor);
    return editable;
  }

  @override
  bool shouldRepaint(covariant _ComposerKolobokPainter oldDelegate) {
    return oldDelegate.spans != spans ||
        oldDelegate.light != light ||
        oldDelegate.generation != generation ||
        oldDelegate.clockMs != clockMs;
  }
}
