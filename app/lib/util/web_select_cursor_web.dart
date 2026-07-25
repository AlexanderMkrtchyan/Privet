// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;
import 'dart:ui' show Color;

/// Current accent used for painted text/move cursors (defaults to signal lime).
Color _accent = const Color(0xFFB6F24A);
bool _messageSelectHovering = false;
bool _dragHovering = false;
bool _stylesInstalled = false;

String _cssHex(Color c) =>
    (c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0');

String _ibeamCursor(Color c) {
  final hex = _cssHex(c);
  return "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' "
      "width='16' height='20' viewBox='0 0 16 20'%3E%3Cpath fill='%23$hex' "
      "d='M3 0h10v2H9v16h4v2H3v-2h4V2H3V0z'/%3E%3C/svg%3E\") 7 10, text";
}

String _moveCursor(Color c) {
  final hex = _cssHex(c);
  return "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' "
      "width='32' height='32' viewBox='0 0 32 32'%3E"
      "%3Cpath fill='%23$hex' d='M16 2l5 7h-3v5h5V11l7 5-7 5v-3h-5v5h3l-5 7-5-7h3v-5H9v3L2 16l7-5v3h5V9H9l7-7z'/%3E"
      "%3C/svg%3E\") 16 16, move";
}

/// Keep painted web cursors in sync with the user-picked accent.
void syncPrivetAccentCursors(Color accent) {
  _accent = accent;
  _rewriteStyles();
  if (_messageSelectHovering) {
    _setBodyCursor(_ibeamCursor(_accent));
  } else if (_dragHovering) {
    _setBodyCursor(_moveCursor(_accent));
  }
}

/// CSS so Flutter's own `cursor: move|text` on the glass pane uses the accent
/// (body.style alone loses to the view's inline cursor).
///
/// Do NOT remap `grab` / `grabbing` — message swipe paints its own hand.
void installPrivetPaintedCursors() {
  if (_stylesInstalled) return;
  _stylesInstalled = true;
  _rewriteStyles();
}

void _rewriteStyles() {
  final existing = html.document.getElementById('privet-painted-cursors');
  final css = '''
/* Painted accent cursors — override Flutter's system move/text on the view */
[style*="cursor: move"],
[style*="cursor: all-scroll"],
flt-semantics[style*="cursor: move"],
flt-semantics[style*="cursor: all-scroll"] {
  cursor: ${_moveCursor(_accent)} !important;
}
.flt-text-editing,
[style*="cursor: text"],
flt-semantics[style*="cursor: text"] {
  cursor: ${_ibeamCursor(_accent)} !important;
}
''';
  if (existing is html.StyleElement) {
    existing.text = css;
    return;
  }
  final style = html.StyleElement()
    ..id = 'privet-painted-cursors'
    ..text = css;
  html.document.head?.append(style);
}

void setPrivetMessageSelectHover(bool hovering) {
  installPrivetPaintedCursors();
  _messageSelectHovering = hovering;
  if (hovering) {
    _dragHovering = false;
    _setBodyCursor(_ibeamCursor(_accent));
  } else if (!_dragHovering) {
    _setBodyCursor(null);
  }
}

void setPrivetDragHover(bool hovering) {
  installPrivetPaintedCursors();
  _dragHovering = hovering;
  if (hovering) {
    _messageSelectHovering = false;
    _setBodyCursor(_moveCursor(_accent));
  } else if (!_messageSelectHovering) {
    _setBodyCursor(null);
  }
}

void _setBodyCursor(String? value) {
  final body = html.document.body;
  if (body == null) return;
  if (value != null) {
    body.style.setProperty('cursor', value, 'important');
  } else {
    body.style.removeProperty('cursor');
  }
}
