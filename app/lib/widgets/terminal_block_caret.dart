import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../theme.dart';

/// Hard on/off block caret timed like Ubuntu GNOME Terminal.
///
/// Blink: 600ms lit / 600ms dark ([gtk-cursor-blink-time] 1200ms).
/// While typing (and briefly after): locked to [PrivetTheme.signal] (user accent).
/// After [idleDelay] with no edits: each lit flash advances through
/// [PrivetTheme.accentOptions]. Ignores autocorrect/kolobok notify storms.
class TerminalBlockCaret extends StatefulWidget {
  const TerminalBlockCaret({
    super.key,
    required this.fieldKey,
    required this.focusNode,
    required this.controller,
    required this.height,
    required this.width,
  });

  final GlobalKey fieldKey;
  final FocusNode focusNode;
  final TextEditingController controller;
  final double height;
  final double width;

  /// Half of Ubuntu/GTK `cursor-blink-time` (1200ms).
  static const Duration blinkHalfPeriod = Duration(milliseconds: 600);

  /// How long after the last edit before accent color cycling starts.
  static const Duration idleDelay = Duration(seconds: 1);

  @override
  State<TerminalBlockCaret> createState() => _TerminalBlockCaretState();
}

class _TerminalBlockCaretState extends State<TerminalBlockCaret> {
  final GlobalKey _paintKey = GlobalKey();
  Timer? _blink;
  Timer? _idle;
  ViewportOffset? _boundOffset;
  bool _lit = true;
  bool _armed = false;

  /// False while typing — caret stays on the user's accent.
  bool _cycleColors = false;
  int _colorIndex = 0;
  String _lastText = '';
  TextSelection _lastSel = const TextSelection.collapsed(offset: -1);

  static List<Color> get _palette =>
      PrivetTheme.accentOptions.map((o) => o.seed).toList(growable: false);

  Color get _color {
    // Rainbow idle cycle is a flourish — skip under Low RAM & CPU / a11y.
    // Blink itself always runs (see [_ensureBlink]); a 600ms Timer is cheap.
    if (!_cycleColors || _animationsDisabled) return PrivetTheme.signal;
    final colors = _palette;
    if (colors.isEmpty) return PrivetTheme.signal;
    return colors[_colorIndex % colors.length];
  }

  @override
  void initState() {
    super.initState();
    _lastText = widget.controller.text;
    _lastSel = widget.controller.selection;
    _colorIndex = 0;
    widget.focusNode.addListener(_onFocusChanged);
    widget.controller.addListener(_onControllerTick);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _ensureBlink();
        _armIdleColorCycle();
      }
    });
  }

  @override
  void didUpdateWidget(covariant TerminalBlockCaret oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChanged);
      widget.focusNode.addListener(_onFocusChanged);
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerTick);
      widget.controller.addListener(_onControllerTick);
      _lastText = widget.controller.text;
      _lastSel = widget.controller.selection;
    }
  }

  @override
  void dispose() {
    _blink?.cancel();
    _idle?.cancel();
    _boundOffset?.removeListener(_onScroll);
    _boundOffset = null;
    widget.focusNode.removeListener(_onFocusChanged);
    widget.controller.removeListener(_onControllerTick);
    super.dispose();
  }

  void _onScroll() {
    if (mounted && _shouldShow) setState(() {});
  }

  void _syncScrollBinding() {
    final editable = findComposerEditable(widget.fieldKey.currentContext);
    final next = editable?.offset;
    if (identical(next, _boundOffset)) return;
    _boundOffset?.removeListener(_onScroll);
    _boundOffset = next;
    _boundOffset?.addListener(_onScroll);
  }

  void _onFocusChanged() {
    if (widget.focusNode.hasFocus) {
      _lit = true;
      _cycleColors = false;
      _ensureBlink();
      _armIdleColorCycle();
    } else {
      _stopBlink();
      _idle?.cancel();
      _idle = null;
      _cycleColors = false;
    }
    if (mounted) setState(() {});
  }

  void _onControllerTick() {
    final text = widget.controller.text;
    final sel = widget.controller.selection;
    // Autocorrect fade / kolobok cache notify without text or caret moves.
    if (text == _lastText && sel == _lastSel) {
      if (mounted && _shouldShow && _lit) setState(() {});
      return;
    }
    _lastText = text;
    _lastSel = sel;
    // Typing / caret move: lock to user accent, solid, then idle → rainbow.
    _lit = true;
    _cycleColors = false;
    _ensureBlink();
    _armIdleColorCycle();
    if (mounted) setState(() {});
  }

  void _armIdleColorCycle() {
    _idle?.cancel();
    if (!_shouldShow || _animationsDisabled) return;
    _idle = Timer(TerminalBlockCaret.idleDelay, () {
      if (!mounted || !_shouldShow) return;
      setState(() => _cycleColors = true);
    });
  }

  bool get _animationsDisabled {
    final mq = MediaQuery.maybeOf(context);
    return mq?.disableAnimations ?? false;
  }

  bool get _shouldShow {
    if (!widget.focusNode.hasFocus) return false;
    final sel = widget.controller.selection;
    return sel.isValid && sel.isCollapsed;
  }

  void _ensureBlink() {
    // Always blink when focused — do not gate on MediaQuery.disableAnimations
    // / Low RAM & CPU. A periodic Timer + one setState is negligible; freezing
    // the caret made the composer feel dead on weak GPUs.
    if (!_shouldShow) {
      _stopBlink();
      return;
    }
    if (_armed && _blink != null) return;
    _blink?.cancel();
    _armed = true;
    _blink = Timer.periodic(TerminalBlockCaret.blinkHalfPeriod, (_) {
      if (!mounted) return;
      if (!_shouldShow) {
        _stopBlink();
        setState(() {});
        return;
      }
      setState(() {
        _lit = !_lit;
        // Rainbow only after idle — each lit flash steps the accent list.
        if (_lit && _cycleColors && !_animationsDisabled) {
          final n = _palette.length;
          if (n > 0) _colorIndex = (_colorIndex + 1) % n;
        }
      });
    });
  }

  void _stopBlink() {
    _blink?.cancel();
    _blink = null;
    _armed = false;
    _lit = true;
  }

  @override
  Widget build(BuildContext context) {
    // Read so we rebuild when Low RAM & CPU flips (color cycle on/off).
    final _ = MediaQuery.disableAnimationsOf(context);
    final visible = _shouldShow && _lit;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncScrollBinding();
    });
    // ClipRect: CustomPaint + a non-overflowing Stack do not clip, so a
    // scrolled caret would blink over the thread or below the window.
    return ClipRect(
      child: CustomPaint(
        key: _paintKey,
        painter: _TerminalBlockCaretPainter(
          fieldKey: widget.fieldKey,
          paintKey: _paintKey,
          selection: widget.controller.selection,
          height: widget.height,
          width: widget.width,
          color: _color,
          visible: visible,
          scrollPixels: _boundOffset?.pixels ?? 0,
        ),
      ),
    );
  }
}

class _TerminalBlockCaretPainter extends CustomPainter {
  _TerminalBlockCaretPainter({
    required this.fieldKey,
    required this.paintKey,
    required this.selection,
    required this.height,
    required this.width,
    required this.color,
    required this.visible,
    required this.scrollPixels,
  });

  final GlobalKey fieldKey;
  final GlobalKey paintKey;
  final TextSelection selection;
  final double height;
  final double width;
  final Color color;
  final bool visible;
  final double scrollPixels;

  @override
  void paint(Canvas canvas, Size size) {
    if (!visible) return;
    final editable = findComposerEditable(fieldKey.currentContext);
    final paintBox = paintKey.currentContext?.findRenderObject();
    if (editable == null || !editable.hasSize) return;
    if (paintBox is! RenderBox || !paintBox.hasSize) return;
    if (!selection.isValid || !selection.isCollapsed) return;

    final origin =
        editable.localToGlobal(Offset.zero) -
        paintBox.localToGlobal(Offset.zero);
    final clip = composerOverlayFieldClip(
      fieldOrigin: origin,
      fieldSize: editable.size,
      paintSize: size,
    );
    if (clip == null) return;

    final anchor = editable
        .getLocalRectForCaret(selection.extent)
        .shift(origin);
    final rect = Rect.fromLTWH(
      anchor.left,
      anchor.top + (anchor.height - height) / 2,
      width,
      height,
    );
    if (!rect.overlaps(clip)) return;

    canvas.save();
    canvas.clipRect(clip);
    canvas.drawRect(rect, Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _TerminalBlockCaretPainter oldDelegate) {
    return oldDelegate.visible != visible ||
        oldDelegate.selection != selection ||
        oldDelegate.height != height ||
        oldDelegate.width != width ||
        oldDelegate.color != color ||
        oldDelegate.scrollPixels != scrollPixels;
  }
}

/// [RenderEditable] under a composer [TextField] key.
RenderEditable? findComposerEditable(BuildContext? ctx) {
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

/// Visible field box in the overlay's paint space, or null if nothing shows.
Rect? composerOverlayFieldClip({
  required Offset fieldOrigin,
  required Size fieldSize,
  required Size paintSize,
}) {
  final field = fieldOrigin & fieldSize;
  final clip = field.intersect(Offset.zero & paintSize);
  if (clip.isEmpty) return null;
  return clip;
}

/// Clip for the composer Kolobok overlay.
///
/// [composerOverlayFieldClip] is the [RenderEditable] line box. Oversized
/// pack art is taller than that box and was sheared at the chin / sprout.
/// Keep the editable's horizontal inset (do not paint over prefix/suffix
/// icons) but use the full field height so faces can sit in content padding.
Rect? composerKolobokOverlayClip({
  required Offset fieldOrigin,
  required Size fieldSize,
  required Size paintSize,
}) {
  final field = composerOverlayFieldClip(
    fieldOrigin: fieldOrigin,
    fieldSize: fieldSize,
    paintSize: paintSize,
  );
  if (field == null) return null;
  return Rect.fromLTRB(field.left, 0, field.right, paintSize.height);
}
