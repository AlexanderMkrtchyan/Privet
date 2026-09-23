import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../theme.dart';
import '../util/kolobok_images.dart';
import 'composer_autocorrect_controller.dart';
import 'selectable_markup_text.dart'
    show kolobokArtSlot, kolobokDestRect, kolobokPaintCenter, kolobokPaintScale;
import 'terminal_block_caret.dart'
    show composerOverlayFieldClip, findComposerEditable;

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

  @override
  void paint(Canvas canvas, Size size) {
    if (spans.isEmpty) return;
    final editable = findComposerEditable(fieldKey.currentContext);
    final paintBox = paintKey.currentContext?.findRenderObject();
    if (editable == null || !editable.hasSize) return;
    if (paintBox is! RenderBox || !paintBox.hasSize) return;

    final origin =
        editable.localToGlobal(Offset.zero) -
        paintBox.localToGlobal(Offset.zero);
    final clip = composerOverlayFieldClip(
      fieldOrigin: origin,
      fieldSize: editable.size,
      paintSize: size,
    );
    if (clip == null) return;
    canvas.save();
    canvas.clipRect(clip);
    final cache = KolobokImageCache.instance;
    final paint = Paint()..filterQuality = FilterQuality.high;
    final plainLen = editable.text?.toPlainText().length ?? 0;
    final fontSize = editable.textScaler.scale(
      editable.text?.style?.fontSize ?? 16.0,
    );

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
      final caret = editable
          .getLocalRectForCaret(TextPosition(offset: span.start))
          .shift(origin);
      for (final box in boxes) {
        final rect = box.toRect().shift(origin);
        final artSlot = kolobokArtSlot(rect, fontSize);
        final scale = kolobokPaintScale(
          slot: artSlot,
          imageWidth: image.width,
          imageHeight: image.height,
          fontSize: fontSize,
        );
        final destH = image.height * scale;
        final destW = image.width * scale;
        final dest = kolobokDestRect(
          artSlot: artSlot,
          center: kolobokPaintCenter(
            slot: artSlot,
            destHeight: destH,
            fontSize: fontSize,
            letterMidY: caret.center.dy,
          ),
          width: destW,
          height: destH,
        );
        // Inline with typed text — skip the dark-UI white halo.
        canvas.drawImageRect(image, source, dest, paint);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ComposerKolobokPainter oldDelegate) {
    return oldDelegate.spans != spans ||
        oldDelegate.light != light ||
        oldDelegate.generation != generation ||
        oldDelegate.clockMs != clockMs;
  }
}
