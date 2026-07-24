import 'app_clipboard_stub.dart'
    if (dart.library.html) 'app_clipboard_web_store.dart' as store;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Text clipboard with an in-app mirror.
///
/// On Flutter web, toolbar **Paste** uses `navigator.clipboard.readText()`,
/// which often hangs or fails. We keep the last text from in-app Copy / Ctrl+C
/// (and DOM copy/cut/paste events) so toolbar Paste can insert synchronously.
class AppClipboard {
  AppClipboard._();

  static String? _lastText;

  /// Sync remember without touching the system clipboard.
  static void remember(String text) {
    if (text.isEmpty) return;
    _lastText = text;
    store.persistClipboardText(text);
  }

  static String? peek() {
    if (_lastText != null && _lastText!.isNotEmpty) return _lastText;
    final fromStore = store.readClipboardText();
    if (fromStore != null && fromStore.isNotEmpty) {
      _lastText = fromStore;
      return fromStore;
    }
    return null;
  }

  static Future<void> setText(String text) async {
    if (text.isEmpty) return;
    remember(text);
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } catch (_) {}
  }

  /// System clipboard first (short timeout), then in-app mirror.
  /// Prefer [peek] for toolbar Paste — never block the button on readText().
  static Future<String?> getText() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain)
          .timeout(const Duration(milliseconds: 200));
      final t = data?.text;
      if (t != null && t.isNotEmpty) {
        remember(t);
        return t;
      }
    } catch (_) {}
    return peek();
  }
}

void insertTextIntoEditable(EditableTextState state, String text) {
  if (text.isEmpty) return;
  final value = state.textEditingValue;
  var selection = value.selection;
  if (!selection.isValid) {
    selection = TextSelection.collapsed(offset: value.text.length);
  }
  final start = selection.start;
  final end = selection.end;
  final newText = value.text.replaceRange(start, end, text);
  final caret = start + text.length;
  final next = TextEditingValue(
    text: newText,
    selection: TextSelection.collapsed(offset: caret),
  );
  state.userUpdateTextEditingValue(next, SelectionChangedCause.toolbar);
  state.bringIntoView(TextPosition(offset: caret));
}

/// Insert [text] into a [TextEditingController] at the current selection.
void insertTextIntoController(TextEditingController controller, String text) {
  if (text.isEmpty) return;
  final value = controller.value;
  var selection = value.selection;
  if (!selection.isValid) {
    selection = TextSelection.collapsed(offset: value.text.length);
  }
  final start = selection.start;
  final end = selection.end;
  final newText = value.text.replaceRange(start, end, text);
  controller.value = TextEditingValue(
    text: newText,
    selection: TextSelection.collapsed(offset: start + text.length),
  );
}

/// Paste using the in-app mirror only (no clipboard.readText).
/// Returns true when text was inserted.
bool pasteMirrorIntoEditable(
  EditableTextState state, {
  TextEditingController? controller,
}) {
  final text = AppClipboard.peek();
  if (text == null || text.isEmpty) return false;
  if (controller != null) {
    insertTextIntoController(controller, text);
    state.userUpdateTextEditingValue(
      controller.value,
      SelectionChangedCause.toolbar,
    );
  } else {
    insertTextIntoEditable(state, text);
  }
  return true;
}

Future<void> pasteIntoEditable(EditableTextState state) async {
  if (pasteMirrorIntoEditable(state)) return;
  final text = await AppClipboard.getText();
  if (text == null || text.isEmpty) return;
  insertTextIntoEditable(state, text);
}

/// Toolbar whose **Paste** never calls `clipboard.readText()`.
Widget clipboardAwareContextMenu(
  BuildContext context,
  EditableTextState editableTextState, {
  TextEditingController? controller,
  VoidCallback? onPasted,
}) {
  final items = <ContextMenuButtonItem>[
    for (final item in editableTextState.contextMenuButtonItems)
      if (item.type == ContextMenuButtonType.paste)
        ContextMenuButtonItem(
          type: ContextMenuButtonType.paste,
          onPressed: () {
            final inserted = pasteMirrorIntoEditable(
              editableTextState,
              controller: controller,
            );
            editableTextState.hideToolbar();
            if (inserted) onPasted?.call();
          },
        )
      else
        item,
  ];

  return TextFieldTapRegion(
    child: AdaptiveTextSelectionToolbar.buttonItems(
      anchors: editableTextState.contextMenuAnchors,
      buttonItems: items,
    ),
  );
}
