// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;

/// Signal green (#B6F24A) I-beam — selectable message text.
const greenIBeamCursor = "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' "
    "width='16' height='20' viewBox='0 0 16 20'%3E%3Cpath fill='%23B6F24A' "
    "d='M3 0h10v2H9v16h4v2H3v-2h4V2H3V0z'/%3E%3C/svg%3E\") 7 10, text";

/// Signal green four-way move — floating / draggable chrome (mini call bar).
/// Thick arrows so the paint reads clearly on dark UI.
const greenMoveCursor = "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' "
    "width='32' height='32' viewBox='0 0 32 32'%3E"
    "%3Cpath fill='%23B6F24A' d='M16 2l5 7h-3v5h5V11l7 5-7 5v-3h-5v5h3l-5 7-5-7h3v-5H9v3L2 16l7-5v3h5V9H9l7-7z'/%3E"
    "%3C/svg%3E\") 16 16, move";

bool _stylesInstalled = false;

/// CSS so Flutter's own `cursor: move|text` on the glass pane paints green
/// (body.style alone loses to the view's inline cursor).
void installPrivetPaintedCursors() {
  if (_stylesInstalled) return;
  _stylesInstalled = true;
  if (html.document.getElementById('privet-painted-cursors') != null) return;
  final style = html.StyleElement()
    ..id = 'privet-painted-cursors'
    ..text = '''
/* Painted green cursors — override Flutter's system move/text on the view */
[style*="cursor: move"],
[style*="cursor: all-scroll"],
[style*="cursor: grab"],
[style*="cursor: grabbing"],
flt-semantics[style*="cursor: move"],
flt-semantics[style*="cursor: all-scroll"],
flt-semantics[style*="cursor: grab"] {
  cursor: $greenMoveCursor !important;
}
.flt-text-editing,
[style*="cursor: text"],
flt-semantics[style*="cursor: text"] {
  cursor: $greenIBeamCursor !important;
}
''';
  html.document.head?.append(style);
}

void setPrivetMessageSelectHover(bool hovering) {
  installPrivetPaintedCursors();
  _setBodyCursor(hovering ? greenIBeamCursor : null);
}

void setPrivetDragHover(bool hovering) {
  installPrivetPaintedCursors();
  _setBodyCursor(hovering ? greenMoveCursor : null);
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
