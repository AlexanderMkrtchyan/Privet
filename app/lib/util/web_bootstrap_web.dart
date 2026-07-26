// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:html' as html;

import 'app_clipboard.dart';
import 'clipboard_files.dart';
import 'web_select_cursor.dart';

void bootstrapWebPlatform() {
  void block(html.Event event) {
    event.preventDefault();
    event.stopPropagation();
  }

  // Capture-phase listeners (Flutter's BrowserContextMenu.disableContextMenu
  // also attaches to the view root from main()).
  html.document.addEventListener('contextmenu', block, true);
  html.window.addEventListener('contextmenu', block, true);
  html.document.documentElement?.addEventListener('contextmenu', block, true);
  html.document.body?.addEventListener('contextmenu', block, true);
  html.document.onContextMenu.listen(block);
  html.document.documentElement?.setAttribute('oncontextmenu', 'return false');
  html.document.body?.setAttribute('oncontextmenu', 'return false');

  // Mirror Ctrl+C / Ctrl+X / paste text into AppClipboard so toolbar Paste
  // works when navigator.clipboard.readText() is denied.
  _mirrorDomClipboard();

  // Semantics overlay nodes often miss CSS cursor; pointer only when enabled.
  // Move/text cursors are painted signal-green (see installPrivetPaintedCursors).
  final style = html.StyleElement()
    ..id = 'privet-cursor-pointer'
    ..text = '''
button:not(:disabled):not([disabled]):not([aria-disabled="true"]),
[role="button"]:not([aria-disabled="true"]),
flt-semantics[role="button"]:not([aria-disabled="true"]),
a:not([aria-disabled="true"]),
[role="link"]:not([aria-disabled="true"]) {
  cursor: pointer;
}
button:disabled,
button[disabled],
[aria-disabled="true"],
[role="button"][aria-disabled="true"],
flt-semantics[role="button"][aria-disabled="true"] {
  cursor: default !important;
}
''';
  if (html.document.getElementById('privet-cursor-pointer') == null) {
    html.document.head?.append(style);
  }
  installPrivetPaintedCursors();
  // Shared attach <input type="file"> — must exist before first paint so the
  // paperclip overlay can position a real, gesture-safe control.
  ensureAttachFileInput();
  _installVisualViewportSync();
}

/// Blur focused composer / IME host and pin the visual viewport so iOS/Android
/// PWAs do not leave a white keyboard-sized gap after dismiss.
void dismissSoftKeyboard() {
  try {
    html.document.activeElement?.blur();
  } catch (_) {}
  _syncVisualViewport();
  html.window.scrollTo(0, 0);
  // Second pass after the browser finishes collapsing the keyboard.
  Future<void>.delayed(const Duration(milliseconds: 50), () {
    _syncVisualViewport();
    html.window.scrollTo(0, 0);
  });
  Future<void>.delayed(const Duration(milliseconds: 280), () {
    _syncVisualViewport();
    html.window.scrollTo(0, 0);
  });
}

void _syncVisualViewport() {
  final vv = html.window.visualViewport;
  final h = vv?.height ?? html.window.innerHeight?.toDouble() ?? 0;
  final w = vv?.width ?? html.window.innerWidth?.toDouble() ?? 0;
  if (h <= 0) return;
  final root = html.document.documentElement;
  root?.style.setProperty('--privet-vvh', '${h}px');
  if (w > 0) root?.style.setProperty('--privet-vvw', '${w}px');
  html.document.body?.style.height = '${h}px';
  root?.style.height = '${h}px';
}

void _installVisualViewportSync() {
  void sync([_]) => _syncVisualViewport();
  sync();
  html.window.onResize.listen(sync);
  final vv = html.window.visualViewport;
  if (vv != null) {
    vv.onResize.listen(sync);
    vv.onScroll.listen((_) {
      // Keyboard open can offset the visual viewport; keep the page pinned.
      html.window.scrollTo(0, 0);
      sync();
    });
  }
  html.document.addEventListener('focusout', (_) {
    Future<void>.delayed(const Duration(milliseconds: 50), sync);
    Future<void>.delayed(const Duration(milliseconds: 300), sync);
  });
}

void _mirrorDomClipboard() {
  String? selectedInActiveElement() {
    final active = html.document.activeElement;
    if (active is html.InputElement) {
      final value = active.value ?? '';
      final start = active.selectionStart ?? 0;
      final end = active.selectionEnd ?? 0;
      if (end > start && end <= value.length) {
        return value.substring(start, end);
      }
    } else if (active is html.TextAreaElement) {
      final value = active.value ?? '';
      final start = active.selectionStart ?? 0;
      final end = active.selectionEnd ?? 0;
      if (end > start && end <= value.length) {
        return value.substring(start, end);
      }
    }
    final sel = html.window.getSelection()?.toString();
    if (sel != null && sel.isNotEmpty) return sel;
    return null;
  }

  html.document.addEventListener('keydown', (html.Event e) {
    final ke = e as html.KeyboardEvent;
    if (!(ke.ctrlKey || ke.metaKey)) return;
    final key = (ke.key ?? '').toLowerCase();
    if (key != 'c' && key != 'x') return;
    final selected = selectedInActiveElement();
    if (selected != null && selected.isNotEmpty) {
      AppClipboard.remember(selected);
    }
  }, true);

  void mirrorClipboardEvent(html.Event e) {
    final data =
        (e as html.ClipboardEvent).clipboardData?.getData('text/plain');
    if (data != null && data.isNotEmpty) {
      AppClipboard.remember(data);
    }
  }

  html.document.addEventListener('copy', mirrorClipboardEvent, true);
  html.document.addEventListener('cut', mirrorClipboardEvent, true);
  html.document.addEventListener('paste', mirrorClipboardEvent, true);
}
