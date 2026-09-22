import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../theme.dart';
import 'composer_autocorrect_controller.dart';
import 'selectable_markup_text.dart' show privetTightInkRect;

/// Paints the composer range-selection tint above the [TextField].
///
/// Uses tight, slightly inset boxes so the tint hugs the glyphs. The field
/// keeps a transparent [selectionColor] so this overlay is the only tint
/// (avoids double-painting with EditableText's built-in layer).
class ComposerSelectionOverlay extends StatefulWidget {
  const ComposerSelectionOverlay({
    super.key,
    required this.fieldKey,
    required this.controller,
  });

  final GlobalKey fieldKey;
  final ComposerAutocorrectController controller;

  @override
  State<ComposerSelectionOverlay> createState() =>
      _ComposerSelectionOverlayState();
}

class _ComposerSelectionOverlayState extends State<ComposerSelectionOverlay> {
  final GlobalKey _paintKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        return CustomPaint(
          key: _paintKey,
          painter: _ComposerSelectionPainter(
            fieldKey: widget.fieldKey,
            paintKey: _paintKey,
            selection: widget.controller.selection,
            textLength: widget.controller.text.length,
            signal: PrivetTheme.signal,
          ),
        );
      },
    );
  }
}

class _ComposerSelectionPainter extends CustomPainter {
  _ComposerSelectionPainter({
    required this.fieldKey,
    required this.paintKey,
    required this.selection,
    required this.textLength,
    required this.signal,
  });

  final GlobalKey fieldKey;
  final GlobalKey paintKey;
  final TextSelection selection;
  final int textLength;
  final Color signal;

  @override
  void paint(Canvas canvas, Size size) {
    if (!selection.isValid || selection.isCollapsed) return;
    final start = selection.start.clamp(0, textLength);
    final end = selection.end.clamp(0, textLength);
    if (end <= start) return;

    final editable = _findEditable(fieldKey.currentContext);
    final paintBox = paintKey.currentContext?.findRenderObject();
    if (editable == null || !editable.hasSize) return;
    if (paintBox is! RenderBox || !paintBox.hasSize) return;

    final origin = editable.localToGlobal(Offset.zero) -
        paintBox.localToGlobal(Offset.zero);

    final boxes = editable.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: end),
    );
    if (boxes.isEmpty) return;

    final paint = Paint()..color = signal.withValues(alpha: 0.45);
    for (final box in boxes) {
      final rect = privetTightInkRect(box.toRect().shift(origin));
      if (rect.width <= 0 || rect.height <= 0) continue;
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        paint,
      );
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
  bool shouldRepaint(covariant _ComposerSelectionPainter oldDelegate) {
    return oldDelegate.selection != selection ||
        oldDelegate.textLength != textLength ||
        oldDelegate.signal != signal;
  }
}
