import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme.dart';
import '../util/app_clipboard.dart';
import '../util/rich_text_markup.dart';
import '../util/web_select_cursor.dart';
import 'message_font_picker.dart';

/// Shared, host-agnostic selection state for [SelectableMarkupText].
///
/// Messages (chat list) and tasks (task pane) both render through
/// [SelectableMarkupText], and only one surface is mounted at a time (the task
/// pane replaces the chat list), so a single scope is safe. Hosts wire the
/// scope to their own "tap empty space clears selection" listener.
class MarkupTextSelectionScope {
  MarkupTextSelectionScope._();

  /// Non-empty while the user has selected text — used so drag selection can
  /// show the Copy / format bar without also triggering host tap handlers.
  static String? activeText;

  /// Dismisses any floating selection action bar (one surface at a time).
  static VoidCallback? dismissUi;

  /// True while a drag-select is in progress (after slop).
  static bool dragging = false;

  /// Set on pointer-down when the text body claims the hit; the host surface
  /// uses this so text taps are not treated as outside clicks.
  static bool bodyClaimedPointer = false;

  /// Bumped when a primary pointer hits selectable text body.
  static int pointerEpoch = 0;

  /// Clears the active text selection + floating bar.
  static void clearSelection() {
    dismissUi?.call();
    dismissUi = null;
    activeText = null;
  }
}

final _urlPattern = RegExp(
  r'''https?:\/\/[^\s<>"'\)\]]+''',
  caseSensitive: false,
);

Future<void> _openExternal(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// Rich text with drag-to-select highlighting and a floating action bar
/// (Copy · Reply · Forward · Bold · Italic · Highlight · Font), shared by
/// message bubbles and task rows.
///
/// The body is [text] in Privet markup (`[b]`/`[i]`/`[bg]`/`[font=…]`, see
/// [parseMarkup]); URLs are clickable. On compact layouts selection is
/// tap-only (links still open); on desktop / wide web a drag selects text and
/// [onFormat] applies bold/italic/highlight/font over the plain-text
/// [TextSelection].
class SelectableMarkupText extends StatefulWidget {
  const SelectableMarkupText({
    super.key,
    required this.text,
    this.fontScale = 1.0,
    this.defaultFont = '',
    this.onReply,
    this.onForward,
    this.onFormat,
    this.onSetDefaultFont,
    this.baseStyle,
    this.hoverStyle,
    this.selectable,
    this.maxWidth,
    this.toolbarSuppressed,
    this.dragging,
  });

  final String text;

  /// Multiplier around the 15px default body size (see [PrivetState.chatFontSize]).
  final double fontScale;

  /// App-wide default font ('' = app default) — the base font every segment
  /// inherits unless it carries an explicit `[font=…]` run.
  final String defaultFont;

  /// Reply / Forward with the selected plain text (toolbar shows the item
  /// only when the callback is non-null).
  final ValueChanged<String>? onReply;
  final ValueChanged<String>? onForward;

  /// Applies bold / italic / highlight / font to the current selection. The
  /// selection is in plain-text coordinates (markup already stripped); the
  /// host re-serializes the markup.
  final void Function(TextSelection selection, TextFormat format)? onFormat;

  /// Persists a font picked in the "Aa" menu as the app-wide default font.
  final ValueChanged<String>? onSetDefaultFont;

  /// Base text style. Defaults to the message body style
  /// (15 × [fontScale], paper). [hoverStyle] replaces it while hovering.
  final TextStyle? baseStyle;
  final TextStyle? hoverStyle;

  /// Drag-selection enabled. Defaults to `!PrivetTheme.isCompact(context)`.
  final bool? selectable;

  /// Layout width for text wrapping; defaults to the chat-bubble max width.
  final double? maxWidth;

  /// True while the host wants the toolbar suppressed (e.g. a reaction menu is
  /// open) — the selection highlight stays but the bar is not shown.
  final bool Function()? toolbarSuppressed;

  /// True while the host surface is being dragged (swipe-to-reply etc.) so the
  /// text cursor defers to the grab cursor.
  final bool Function()? dragging;

  @override
  State<SelectableMarkupText> createState() => _SelectableMarkupTextState();
}

class _SelectableMarkupTextState extends State<SelectableMarkupText> {
  final GlobalKey _hostKey = GlobalKey();
  OverlayEntry? _toolbar;
  String _selected = '';
  bool _blockToolbarForSecondary = false;
  final List<TapGestureRecognizer> _linkRecognizers = [];
  TextSpan? _cachedSpan;
  String? _cachedSpanText;
  bool _cachedWithRecognizers = false;
  double? _cachedSpanScale;
  String _cachedSpanFont = '';

  /// Visible text with markup stripped — selection offsets live in this space.
  String _plainText = '';

  // Web: TextPainter-owned selection (never SelectableText).
  TextSelection _webSel = const TextSelection.collapsed(offset: -1);
  TextPainter? _webPainter;
  double _webMaxWidth = 0;
  double _webPainterScale = 1.0;
  String _webPainterFont = '';
  final _WebSelRepaint _webSelRepaint = _WebSelRepaint();

  // Web pointer-driven select (Listener — does not fight ListView pan arena).
  int? _webSelectPointer;
  int _webSelectBase = 0;
  Offset? _webSelectOrigin;
  bool _webSelectMoved = false;
  // Double-click → word; triple-click → whole message (SelectableText elsewhere).
  int _webTapCount = 0;
  DateTime? _webLastTapDownAt;
  Offset? _webLastTapDownOffset;
  bool _webMultiTapSelect = false;
  ScrollHoldController? _webScrollHold;
  bool _hoveringLink = false;
  bool _webPainterHover = false;

  @override
  void dispose() {
    setPrivetMessageLinkHover(false);
    setPrivetMessageSelectHover(false);
    _releaseWebScrollHold();
    _removeToolbar();
    if (MarkupTextSelectionScope.activeText == _selected) {
      MarkupTextSelectionScope.activeText = null;
    }
    if (MarkupTextSelectionScope.dismissUi == _clearSelectionTracking) {
      MarkupTextSelectionScope.dismissUi = null;
    }
    MarkupTextSelectionScope.dragging = false;
    _webSelRepaint.dispose();
    _webPainter?.dispose();
    for (final r in _linkRecognizers) {
      r.dispose();
    }
    _linkRecognizers.clear();
    super.dispose();
  }

  void _releaseWebScrollHold() {
    _webScrollHold?.cancel();
    _webScrollHold = null;
  }

  void _removeToolbar() {
    _toolbar?.remove();
    _toolbar = null;
  }

  void _clearSelectionTracking() {
    _selected = '';
    _webSel = const TextSelection.collapsed(offset: -1);
    _webSelectMoved = false;
    _webMultiTapSelect = false;
    if (MarkupTextSelectionScope.activeText != null) {
      MarkupTextSelectionScope.activeText = null;
    }
    if (MarkupTextSelectionScope.dismissUi == _clearSelectionTracking) {
      MarkupTextSelectionScope.dismissUi = null;
    }
    _removeToolbar();
    _webSelRepaint.tick();
    if (mounted) setState(() {});
  }

  void _updateWebTapCount(Offset local) {
    final now = DateTime.now();
    final lastAt = _webLastTapDownAt;
    final lastPos = _webLastTapDownOffset;
    final withinTime =
        lastAt != null && now.difference(lastAt) < kDoubleTapTimeout;
    final withinSlop =
        lastPos != null && (local - lastPos).distance < kDoubleTapSlop;
    if (withinTime && withinSlop) {
      _webTapCount += 1;
    } else {
      _webTapCount = 1;
    }
    _webLastTapDownAt = now;
    _webLastTapDownOffset = local;
  }

  void _selectWebWordAt(int offset) {
    final painter = _webPainter;
    if (painter == null || _plainText.isEmpty) return;
    final clamped = offset.clamp(0, _plainText.length);
    final range = painter.getWordBoundary(TextPosition(offset: clamped));
    if (range.start >= range.end) return;
    _setWebSelection(
      TextSelection(baseOffset: range.start, extentOffset: range.end),
    );
    _webMultiTapSelect = true;
  }

  void _selectWebAll() {
    if (_plainText.isEmpty) return;
    _setWebSelection(
      TextSelection(baseOffset: 0, extentOffset: _plainText.length),
    );
    _webMultiTapSelect = true;
  }

  void _claimSelectionDismiss() {
    if (MarkupTextSelectionScope.dismissUi != null &&
        MarkupTextSelectionScope.dismissUi != _clearSelectionTracking) {
      MarkupTextSelectionScope.dismissUi!();
    }
    MarkupTextSelectionScope.dismissUi = _clearSelectionTracking;
  }

  void _showToolbar() {
    if (_blockToolbarForSecondary ||
        (widget.toolbarSuppressed?.call() ?? false)) {
      return;
    }
    _removeToolbar();
    final overlay = Overlay.maybeOf(context);
    final box = _hostKey.currentContext?.findRenderObject() as RenderBox?;
    if (overlay == null || box == null || !box.hasSize) return;

    final origin = box.localToGlobal(Offset.zero);
    final size = MediaQuery.sizeOf(context);
    const barWidth = 372.0;
    // The bar is ~40px tall; budget a bit more so its material shadow also
    // stays clear of the text — a highlight must never slide under the bar.
    const barHeight = 52.0;
    const gap = 8.0;

    // Anchor to the selected range's own box so the bar hugs the selection
    // (and the highlight being applied) instead of floating over the whole
    // message or being clamped onto it near the top of the chat.
    final painter = _webPainter;
    final selection = _webSel;
    Rect? selRect;
    if (painter != null && selection.isValid && !selection.isCollapsed) {
      final boxes = painter.getBoxesForSelection(selection);
      if (boxes.isNotEmpty) {
        var r = boxes.first.toRect();
        for (final b in boxes.skip(1)) {
          r = r.expandToInclude(b.toRect());
        }
        selRect = r.shift(origin);
      }
    }
    final anchorTop = selRect?.top ?? origin.dy;
    final anchorBottom = selRect?.bottom ?? origin.dy + box.size.height;

    // Prefer the bar above the selection; if it would not fit on screen
    // (message near the top), flip it below so it never covers the text.
    double top;
    if (anchorTop - barHeight - gap >= 8.0) {
      top = anchorTop - barHeight - gap;
    } else {
      top = anchorBottom + gap;
    }
    top = top.clamp(8.0, size.height - barHeight - 8.0);

    final centerX = selRect?.center.dx ?? origin.dx + box.size.width / 2;
    final left = (centerX - barWidth / 2).clamp(
      8.0,
      size.width - barWidth - 8,
    );

    _claimSelectionDismiss();
    final String? currentFont;
    final sel = _webSel;
    if (widget.onFormat != null && sel.isValid && !sel.isCollapsed) {
      final parsed = parseMarkup(widget.text);
      final start = sel.start.clamp(0, parsed.plainText.length);
      final end = sel.end.clamp(0, parsed.plainText.length);
      final selFont = end > start
          ? selectionFormat(parsed.runs, start, end).fontFamily
          : null;
      // Prefer the selection's own font, else fall back to the app-wide
      // default so the active row reflects what will be used/persisted.
      currentFont = (selFont != null && selFont.isNotEmpty)
          ? selFont
          : widget.defaultFont;
    } else {
      currentFont = null;
    }
    _toolbar = OverlayEntry(
      builder: (ctx) => Positioned(
        left: left,
        top: top,
        child: MarkupSelectionBar(
          onCopy: () {
            final text = _selected;
            _clearSelectionTracking();
            if (text.isNotEmpty) {
              AppClipboard.setText(text);
            }
          },
          onReply: widget.onReply == null
              ? null
              : () {
                  final text = _selected;
                  _clearSelectionTracking();
                  if (text.isNotEmpty) widget.onReply!(text);
                },
          onForward: widget.onForward == null
              ? null
              : () {
                  final text = _selected;
                  _clearSelectionTracking();
                  if (text.isNotEmpty) widget.onForward!(text);
                },
          onFormat: widget.onFormat == null ? null : _applyFormatToSelection,
          onSetDefaultFont: widget.onSetDefaultFont,
          currentFont: currentFont,
        ),
      ),
    );
    overlay.insert(_toolbar!);
  }

  TextStyle _baseStyleFor({required bool hovering}) {
    final base = widget.baseStyle ??
        TextStyle(
          height: 1.35,
          fontSize: 15 * widget.fontScale,
          color: PrivetTheme.paper,
        );
    final s =
        (hovering && widget.hoverStyle != null) ? widget.hoverStyle! : base;
    if (widget.defaultFont.isEmpty) return s;
    return messageFontStyle(widget.defaultFont, s);
  }

  TextSpan _spanFor(
    String text, {
    required bool withRecognizers,
    bool hovering = false,
  }) {
    // Hover recolors — don't use the recognizer cache for hover frames.
    if (!hovering &&
        _cachedSpanText == text &&
        _cachedSpanScale == widget.fontScale &&
        _cachedSpanFont == widget.defaultFont &&
        _cachedSpan != null &&
        _cachedWithRecognizers == withRecognizers) {
      return _cachedSpan!;
    }
    for (final r in _linkRecognizers) {
      r.dispose();
    }
    _linkRecognizers.clear();

    final base = _baseStyleFor(hovering: hovering);
    final parsed = parseMarkup(text);
    _plainText = parsed.plainText;
    final spans = <InlineSpan>[];

    for (final seg in styledSegments(parsed)) {
      final segBase = seg.format.toTextStyle(base);
      final segText = seg.text;
      final matches = _urlPattern.allMatches(segText).toList();
      if (matches.isEmpty) {
        spans.add(TextSpan(text: segText, style: segBase));
        continue;
      }
      var cursor = 0;
      for (final m in matches) {
        if (m.start > cursor) {
          spans.add(
            TextSpan(text: segText.substring(cursor, m.start), style: segBase),
          );
        }
        var raw = m.group(0)!;
        raw = raw.replaceFirst(RegExp(r'''[.,;:!?)\]>'"]+$'''), '');
        TapGestureRecognizer? recognizer;
        if (withRecognizers) {
          recognizer = TapGestureRecognizer()..onTap = () => _openExternal(raw);
          _linkRecognizers.add(recognizer);
        }
        spans.add(
          TextSpan(
            text: raw,
            style: segBase.copyWith(
              color: PrivetTheme.signal,
              decoration: TextDecoration.underline,
              decorationColor: PrivetTheme.signal.withValues(alpha: 0.7),
            ),
            recognizer: recognizer,
          ),
        );
        cursor = m.start + raw.length;
        if (cursor < m.end) {
          spans.add(
            TextSpan(text: segText.substring(cursor, m.end), style: segBase),
          );
          cursor = m.end;
        }
      }
      if (cursor < segText.length) {
        spans.add(TextSpan(text: segText.substring(cursor), style: segBase));
      }
    }

    final span = TextSpan(style: base, children: spans);
    if (!hovering) {
      _cachedSpanText = text;
      _cachedSpanScale = widget.fontScale;
      _cachedSpanFont = widget.defaultFont;
      _cachedWithRecognizers = withRecognizers;
      _cachedSpan = span;
    }
    return span;
  }

  /// Applies [request] to the current web selection and hands the full desired
  /// format + plain-text selection to the parent (which edits the message).
  void _applyFormatToSelection({
    bool? bold,
    bool? italic,
    Color? background,
    String? fontFamily,
  }) {
    final sel = _webSel;
    final cb = widget.onFormat;
    if (cb == null || !sel.isValid || sel.isCollapsed) return;
    final parsed = parseMarkup(widget.text);
    final start = sel.start.clamp(0, parsed.plainText.length);
    final end = sel.end.clamp(0, parsed.plainText.length);
    if (end <= start) return;
    final cur = selectionFormat(parsed.runs, start, end);
    // Colors.transparent means "remove the highlight".
    final bg = background == Colors.transparent
        ? null
        : (background ?? cur.background);
    final desired = TextFormat(
      bold: bold == null ? cur.bold : (bold ? true : cur.bold),
      italic: italic == null ? cur.italic : (italic ? true : cur.italic),
      background: bg,
      fontFamily: fontFamily == null
          ? cur.fontFamily
          : (fontFamily.isEmpty ? null : fontFamily),
    );
    cb(TextSelection(baseOffset: start, extentOffset: end), desired);
    _clearSelectionTracking();
  }

  void _ensureWebPainter(double maxWidth, {required bool hovering}) {
    if (_webPainter != null &&
        _webMaxWidth == maxWidth &&
        _cachedSpanText == widget.text &&
        _cachedSpanScale == widget.fontScale &&
        _cachedSpanFont == widget.defaultFont &&
        _webPainterScale == widget.fontScale &&
        _webPainterFont == widget.defaultFont &&
        !_cachedWithRecognizers &&
        _webPainterHover == hovering) {
      return;
    }
    _webPainter?.dispose();
    _webMaxWidth = maxWidth;
    _webPainterHover = hovering;
    _webPainterScale = widget.fontScale;
    _webPainterFont = widget.defaultFont;
    _webPainter = TextPainter(
      text: _spanFor(widget.text, withRecognizers: false, hovering: hovering),
      textDirection: ui.TextDirection.ltr,
      ellipsis: null,
    )..layout(maxWidth: maxWidth);
  }

  int _webOffsetAt(Offset local) {
    final painter = _webPainter;
    if (painter == null) return 0;
    final pos = Offset(
      local.dx.clamp(0.0, painter.width),
      local.dy.clamp(0.0, painter.height),
    );
    return painter
        .getPositionForOffset(pos)
        .offset
        .clamp(0, _plainText.length);
  }

  void _setWebSelection(TextSelection next) {
    final selected = next.isValid && !next.isCollapsed
        ? next.textInside(_plainText)
        : '';
    _webSel = next;
    _selected = selected;
    MarkupTextSelectionScope.activeText = selected.isEmpty ? null : selected;
    if (selected.isEmpty) {
      if (MarkupTextSelectionScope.dismissUi == _clearSelectionTracking) {
        MarkupTextSelectionScope.dismissUi = null;
      }
    } else {
      _claimSelectionDismiss();
    }
    _webSelRepaint.tick();
  }

  String? _linkAt(Offset local) {
    final offset = _webOffsetAt(local);
    for (final m in _urlPattern.allMatches(_plainText)) {
      var raw = m.group(0)!;
      raw = raw.replaceFirst(RegExp(r'''[.,;:!?)\]>'"]+$'''), '');
      final end = m.start + raw.length;
      if (offset >= m.start && offset < end) return raw;
    }
    return null;
  }

  void _openLinkAt(Offset local) {
    final url = _linkAt(local);
    if (url != null) _openExternal(url);
  }

  void _setHoveringLink(bool overLink) {
    if (_hoveringLink == overLink) return;
    _hoveringLink = overLink;
    setPrivetMessageLinkHover(overLink);
    if (mounted) setState(() {});
  }

  Widget _buildWebBody({required bool selectable}) {
    // Hug content: layout at bubble max without LayoutBuilder (IntrinsicWidth
    // used to need that; Column hug no longer does, but this stays cheap).
    final maxW = widget.maxWidth ??
        (MediaQuery.sizeOf(context).width * 0.68 - 24).clamp(
          64.0,
          10000.0,
        );
    // Never rebuild glyphs for hover tint — that relayout felt like low CPU on
    // Linux. The real system I-beam shows on hover; web paints its accent I-beam
    // via CSS (web_select_cursor), so no glyph rebuild is needed anywhere.
    _ensureWebPainter(maxW, hovering: false);
    final painter = _webPainter!;
    final size = Size(painter.width, painter.height);

    final dragging = widget.dragging?.call() ?? false;
    return MouseRegion(
      cursor: dragging
          ? MouseCursor.defer
          : _hoveringLink
          ? SystemMouseCursors.click
          : !selectable
          ? SystemMouseCursors.basic
          : SystemMouseCursors.text,
      onEnter: (event) {
        if (selectable) {
          setPrivetMessageSelectHover(true);
        }
        _setHoveringLink(_linkAt(event.localPosition) != null);
      },
      onExit: (_) {
        _setHoveringLink(false);
        if (selectable) {
          setPrivetMessageSelectHover(false);
        }
      },
      onHover: (event) {
        _setHoveringLink(_linkAt(event.localPosition) != null);
      },
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            if (event.buttons == kSecondaryMouseButton) {
              _blockToolbarForSecondary = true;
              _removeToolbar();
              return;
            }
            if (event.buttons != kPrimaryMouseButton) return;

            FocusManager.instance.primaryFocus?.unfocus();

            MarkupTextSelectionScope.pointerEpoch++;
            MarkupTextSelectionScope.bodyClaimedPointer = true;
            _webSelectPointer = event.pointer;
            _webSelectOrigin = event.localPosition;
            _webSelectBase = _webOffsetAt(event.localPosition);
            _webSelectMoved = false;
            _webMultiTapSelect = false;
            MarkupTextSelectionScope.dragging = false;
            _removeToolbar();

            // Mobile: tap only (links / long-press menu). No drag-select.
            if (!selectable) return;

            _updateWebTapCount(event.localPosition);
            if (_webTapCount == 2) {
              _selectWebWordAt(_webSelectBase);
              setState(() {});
            } else if (_webTapCount >= 3) {
              _selectWebAll();
              _webTapCount = 0;
              setState(() {});
            }

            if (event.kind == PointerDeviceKind.mouse) {
              _releaseWebScrollHold();
              _webScrollHold =
                  Scrollable.maybeOf(context)?.position.hold(() {});
            }
          },
          onPointerMove: (event) {
            if (!selectable) return;
            if (_webSelectPointer != event.pointer) return;
            if (_blockToolbarForSecondary) return;
            final origin = _webSelectOrigin;
            if (origin == null) return;

            final delta = event.localPosition - origin;
            if (!_webSelectMoved) {
              if (delta.distance < 2) return;
              _webSelectMoved = true;
              _webMultiTapSelect = false;
              MarkupTextSelectionScope.dragging = true;
            }

            final extent = _webOffsetAt(event.localPosition);
            _setWebSelection(
              TextSelection(baseOffset: _webSelectBase, extentOffset: extent),
            );
          },
          onPointerUp: (event) {
            if (_webSelectPointer != event.pointer) return;
            if (!selectable) {
              _webSelectPointer = null;
              final origin = _webSelectOrigin;
              _webSelectOrigin = null;
              if (_blockToolbarForSecondary) {
                _blockToolbarForSecondary = false;
                return;
              }
              // Tap (no drag): open link under finger when present.
              if (origin != null &&
                  (event.localPosition - origin).distance < kTouchSlop) {
                _openLinkAt(event.localPosition);
              }
              return;
            }
            _finishWebPointer(event.localPosition);
          },
          onPointerCancel: (event) {
            if (_webSelectPointer != event.pointer) return;
            if (!selectable) {
              _webSelectPointer = null;
              _webSelectOrigin = null;
              _blockToolbarForSecondary = false;
              return;
            }
            _finishWebPointer(null);
          },
          child: CustomPaint(
            key: _hostKey,
            size: size,
            painter: _WebMessageTextPainter(
              textPainter: painter,
              getSelection: () => _webSel,
              repaint: _webSelRepaint,
            ),
          ),
        ),
      ),
    );
  }

  void _finishWebPointer(Offset? local) {
    _webSelectPointer = null;
    _webSelectOrigin = null;
    _releaseWebScrollHold();
    MarkupTextSelectionScope.dragging = false;

    if (_blockToolbarForSecondary) {
      _blockToolbarForSecondary = false;
      _webMultiTapSelect = false;
      return;
    }

    if (!_webSelectMoved) {
      if (_webMultiTapSelect) {
        _webMultiTapSelect = false;
        if (_selected.isEmpty ||
            (widget.toolbarSuppressed?.call() ?? false)) {
          _removeToolbar();
          if (mounted) setState(() {});
          return;
        }
        if (mounted) setState(() {});
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted ||
              _selected.isEmpty ||
              (widget.toolbarSuppressed?.call() ?? false)) {
            return;
          }
          _showToolbar();
        });
        return;
      }
      // Click on this surface's text: clear selection if any, else open link.
      if (_webSel.isValid && !_webSel.isCollapsed) {
        _clearSelectionTracking();
        return;
      }
      if (local != null) _openLinkAt(local);
      return;
    }

    _webMultiTapSelect = false;
    if (_selected.isEmpty ||
        (widget.toolbarSuppressed?.call() ?? false)) {
      _webSelectMoved = false;
      _removeToolbar();
      if (mounted) setState(() {});
      return;
    }

    // Mouseup: force a frame so the green highlight is visible immediately
    // (without needing to leave the text / end hover).
    if (mounted) setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _selected.isEmpty ||
          (widget.toolbarSuppressed?.call() ?? false)) {
        return;
      }
      _showToolbar();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Desktop / wide web: custom TextPainter selection (green highlight).
    // Mobile / compact: tap only — no drag-select (matches typical mobile
    // messengers).
    return _buildWebBody(
      selectable: widget.selectable ?? !PrivetTheme.isCompact(context),
    );
  }
}

class _WebSelRepaint extends ChangeNotifier {
  void tick() => notifyListeners();
}

class _WebMessageTextPainter extends CustomPainter {
  _WebMessageTextPainter({
    required this.textPainter,
    required this.getSelection,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final TextPainter textPainter;
  final ValueGetter<TextSelection> getSelection;

  @override
  void paint(Canvas canvas, Size size) {
    final selection = getSelection();
    if (selection.isValid && !selection.isCollapsed) {
      final boxes = textPainter.getBoxesForSelection(selection);
      final paint = Paint()..color = PrivetTheme.signal.withValues(alpha: 0.45);
      for (final box in boxes) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(box.toRect(), const Radius.circular(2)),
          paint,
        );
      }
    }
    textPainter.paint(canvas, Offset.zero);
  }

  @override
  bool shouldRepaint(covariant _WebMessageTextPainter oldDelegate) {
    return oldDelegate.textPainter != textPainter;
  }
}

/// Floating selection bar: Copy · Reply · Forward · B · I · Highlight · Font.
class MarkupSelectionBar extends StatelessWidget {
  const MarkupSelectionBar({
    super.key,
    required this.onCopy,
    this.onReply,
    this.onForward,
    this.onFormat,
    this.onSetDefaultFont,
    this.currentFont,
  });

  final VoidCallback onCopy;
  final VoidCallback? onReply;
  final VoidCallback? onForward;

  /// Applies bold / italic / highlight / font to the current selection.
  final void Function({
    bool? bold,
    bool? italic,
    Color? background,
    String? fontFamily,
  })?
      onFormat;

  /// Persists a font picked in this menu as the app-wide default message font.
  final ValueChanged<String>? onSetDefaultFont;

  /// Font family of the current selection ('' or null = default), used to
  /// highlight the active row in the font picker.
  final String? currentFont;

  @override
  Widget build(BuildContext context) {
    Widget action({
      required Widget child,
      required VoidCallback onTap,
      String? tooltip,
    }) {
      return Tooltip(
        message: tooltip ?? '',
        waitDuration: const Duration(milliseconds: 400),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          mouseCursor: SystemMouseCursors.click,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: child,
          ),
        ),
      );
    }

    Widget textAction({
      required String label,
      required VoidCallback onTap,
      String? tooltip,
    }) {
      return action(
        tooltip: tooltip ?? label,
        onTap: onTap,
        child: Text(
          label,
          style: GoogleFonts.ibmPlexSans(
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }

    void pickHighlight() {
      final box = context.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize || onFormat == null) return;
      showMessageHighlightPicker(
        context,
        anchor: box.localToGlobal(Offset.zero) & box.size,
      ).then((color) {
        if (color == null || onFormat == null) return;
        onFormat!(background: color);
      });
    }

    void pickFont() {
      final overlay = Overlay.maybeOf(context);
      if (overlay == null || onFormat == null) return;
      final box = context.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      showMessageFontPicker(
        context,
        anchor: box.localToGlobal(Offset.zero) & box.size,
        current: currentFont,
      ).then((value) {
        if (value == null) return;
        // Redact the selection and keep the choice as the app-wide default
        // message font for every chat.
        onFormat!(fontFamily: value);
        onSetDefaultFont?.call(value);
      });
    }

    final hasFormat = onFormat != null;

    return Material(
      color: PrivetTheme.panelElevated,
      elevation: 12,
      shadowColor: Colors.black54,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: PrivetTheme.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            action(
              tooltip: 'Copy',
              onTap: onCopy,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.copy_rounded, size: 16, color: PrivetTheme.signal),
                  const SizedBox(width: 6),
                  Text(
                    'Copy',
                    style: GoogleFonts.ibmPlexSans(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            if (onReply != null)
              action(
                tooltip: 'Reply',
                onTap: onReply!,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.reply_rounded,
                        size: 16, color: PrivetTheme.signal),
                    const SizedBox(width: 6),
                    Text(
                      'Reply',
                      style: GoogleFonts.ibmPlexSans(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            if (onForward != null)
              action(
                tooltip: 'Forward',
                onTap: onForward!,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.shortcut_rounded,
                        size: 16, color: PrivetTheme.signal),
                    const SizedBox(width: 6),
                    Text(
                      'Forward',
                      style: GoogleFonts.ibmPlexSans(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            if (hasFormat) ...[
              Container(
                width: 1,
                height: 22,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                color: PrivetTheme.line,
              ),
              textAction(
                label: 'B',
                tooltip: 'Bold',
                onTap: () => onFormat!(bold: true),
              ),
              textAction(
                label: 'I',
                tooltip: 'Italic',
                onTap: () => onFormat!(italic: true),
              ),
              action(
                tooltip: 'Highlight',
                onTap: pickHighlight,
                child: Icon(
                  Icons.border_color_rounded,
                  size: 18,
                  color: PrivetTheme.signal,
                ),
              ),
              action(
                tooltip: 'Font family',
                onTap: pickFont,
                child: Text(
                  'Aa',
                  style: currentFont == null || currentFont!.isEmpty
                      ? GoogleFonts.ibmPlexSans(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        )
                      : messageFontStyle(
                          currentFont!,
                          GoogleFonts.ibmPlexSans(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ).copyWith(color: PrivetTheme.signal),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
