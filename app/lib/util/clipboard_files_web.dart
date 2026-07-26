// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';

import 'clipboard_files.dart';

html.EventListener? _pasteListener;
void Function(PickedBytes file)? _onImage;
int _pasteBindId = 0;

html.FileUploadInputElement? _attachInput;
void Function(PickedBytes file)? _onAttachPicked;
void Function(Object error)? _onAttachError;
int _attachBindId = 0;

/// Creates the shared body-level file input used by the attach button.
void ensureAttachFileInput() {
  if (_attachInput != null) return;
  final input = html.FileUploadInputElement()
    ..accept = '*/*'
    ..multiple = true
    ..title = 'Attach files';
  input.style
    ..position = 'fixed'
    ..left = '-1000px'
    ..top = '-1000px'
    ..width = '1px'
    ..height = '1px'
    ..opacity = '0'
    ..border = '0'
    ..padding = '0'
    ..margin = '0'
    ..cursor = 'pointer'
    ..zIndex = '100000'
    ..overflow = 'hidden';
  input.style.setProperty('pointer-events', 'none');
  input.onChange.listen((_) => _handleAttachChange(input));
  html.document.body?.append(input);
  _attachInput = input;
}

/// Returns a bind id — pass it to [clearAttachHandlers] so a remounted
/// pane cannot clear a newer binder (old State dispose runs after new initState).
int setAttachHandlers({
  required void Function(PickedBytes file)? onPicked,
  void Function(Object error)? onError,
}) {
  ensureAttachFileInput();
  final id = ++_attachBindId;
  _onAttachPicked = onPicked;
  _onAttachError = onError;
  return id;
}

void clearAttachHandlers([int? id]) {
  if (id != null && id != _attachBindId) return;
  _onAttachPicked = null;
  _onAttachError = null;
}

void positionAttachInput({
  required double left,
  required double top,
  required double width,
  required double height,
  required bool active,
}) {
  ensureAttachFileInput();
  final input = _attachInput!;
  if (!active || width <= 0 || height <= 0) {
    input.style
      ..left = '-1000px'
      ..top = '-1000px'
      ..width = '1px'
      ..height = '1px';
    input.style.setProperty('pointer-events', 'none');
    return;
  }
  input.style
    ..left = '${left}px'
    ..top = '${top}px'
    ..width = '${width}px'
    ..height = '${height}px';
  input.style.setProperty('pointer-events', 'auto');
}

Future<void> _handleAttachChange(html.FileUploadInputElement input) async {
  try {
    final files = input.files;
    if (files == null || files.isEmpty) return;
    final picked = <PickedBytes>[];
    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      final bytes = await readBlobAsBytes(file);
      if (bytes == null || bytes.isEmpty) continue;
      picked.add(
        PickedBytes(
          bytes: bytes,
          filename: file.name.isEmpty ? 'attachment.bin' : file.name,
          mimeType: file.type.isEmpty ? 'application/octet-stream' : file.type,
        ),
      );
    }
    input.value = '';
    for (final file in picked) {
      _onAttachPicked?.call(file);
    }
  } catch (e) {
    _onAttachError?.call(e);
  }
}

/// Legacy programmatic picker — prefer the positioned overlay input.
Future<PickedBytes?> pickFileNative() {
  ensureAttachFileInput();
  final completer = Completer<PickedBytes?>();
  final input = html.FileUploadInputElement()
    ..accept = '*/*'
    ..multiple = true;

  input.style
    ..position = 'fixed'
    ..left = '0'
    ..top = '0'
    ..width = '1px'
    ..height = '1px'
    ..opacity = '0'
    ..overflow = 'hidden'
    ..zIndex = '2147483647';

  html.document.body?.append(input);

  var settled = false;
  void complete(PickedBytes? value) {
    if (settled) return;
    settled = true;
    input.remove();
    if (!completer.isCompleted) completer.complete(value);
  }

  input.onChange.listen((_) async {
    try {
      final files = input.files;
      if (files == null || files.isEmpty) {
        complete(null);
        return;
      }
      PickedBytes? first;
      for (var i = 0; i < files.length; i++) {
        final file = files[i];
        final bytes = await readBlobAsBytes(file);
        if (bytes == null || bytes.isEmpty) continue;
        final picked = PickedBytes(
          bytes: bytes,
          filename: file.name.isEmpty ? 'attachment.bin' : file.name,
          mimeType:
              file.type.isEmpty ? 'application/octet-stream' : file.type,
        );
        first ??= picked;
        if (i > 0) {
          _onAttachPicked?.call(picked);
        }
      }
      complete(first);
    } catch (_) {
      complete(null);
    }
  });

  input.on['cancel'].listen((_) => complete(null));
  Timer(const Duration(seconds: 30), () => complete(null));
  input.click();
  return completer.future;
}

Future<PickedBytes?> _fromBlob(html.Blob blob, String? mimeHint) async {
  var type = (mimeHint != null && mimeHint.isNotEmpty)
      ? mimeHint
      : (blob.type.isEmpty ? '' : blob.type);
  if (type.isEmpty) {
    type = blob is html.File && blob.name.isNotEmpty
        ? _mimeFromName(blob.name)
        : 'application/octet-stream';
  }
  final bytes = await readBlobAsBytes(blob);
  if (bytes == null || bytes.isEmpty) return null;
  final ext = switch (type) {
    'image/png' => 'png',
    'image/jpeg' => 'jpg',
    'image/gif' => 'gif',
    'image/webp' => 'webp',
    'video/mp4' => 'mp4',
    'video/webm' => 'webm',
    'audio/webm' => 'webm',
    'audio/mpeg' => 'mp3',
    'application/pdf' => 'pdf',
    _ => type.contains('/')
        ? type.split('/').last.split(';').first
        : 'bin',
  };
  final name = blob is html.File && blob.name.isNotEmpty
      ? blob.name
      : 'paste-$ext-${DateTime.now().millisecondsSinceEpoch}.$ext';
  return PickedBytes(bytes: bytes, filename: name, mimeType: type);
}

String _mimeFromName(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.mp4')) return 'video/mp4';
  if (lower.endsWith('.webm')) return 'video/webm';
  if (lower.endsWith('.pdf')) return 'application/pdf';
  return 'application/octet-stream';
}

/// Returns:
/// - `handled` true when an attachable file was taken from the paste event
/// - `tryClipboardApi` when we should fall back to async clipboard.read()
({bool handled, bool tryClipboardApi}) _tryClipboardEvent(
  html.ClipboardEvent event,
) {
  final clipboard = event.clipboardData;
  if (clipboard == null) {
    return (handled: false, tryClipboardApi: false);
  }

  final items = clipboard.items;
  if (items != null) {
    final count = items.length ?? 0;
    var sawImageTypeWithoutFile = false;
    for (var i = 0; i < count; i++) {
      final item = items[i];
      final type = item.type ?? '';
      final attachable = type.startsWith('image/') ||
          type.startsWith('video/') ||
          type.startsWith('audio/') ||
          type == 'application/pdf';
      if (!attachable) continue;
      final blob = item.getAsFile();
      if (blob == null) {
        if (type.startsWith('image/')) sawImageTypeWithoutFile = true;
        continue;
      }
      event.preventDefault();
      event.stopImmediatePropagation();
      unawaited(
        _fromBlob(blob, type).then((picked) {
          if (picked != null) _onImage?.call(picked);
        }),
      );
      return (handled: true, tryClipboardApi: false);
    }
    if (sawImageTypeWithoutFile) {
      event.preventDefault();
      event.stopImmediatePropagation();
      return (handled: false, tryClipboardApi: true);
    }
  }

  final files = clipboard.files;
  if (files != null && files.isNotEmpty) {
    final file = files[0];
    final type = file.type.isEmpty ? _mimeFromName(file.name) : file.type;
    event.preventDefault();
    event.stopImmediatePropagation();
    unawaited(
      _fromBlob(file, type).then((picked) {
        if (picked != null) _onImage?.call(picked);
      }),
    );
    return (handled: true, tryClipboardApi: false);
  }
  return (handled: false, tryClipboardApi: false);
}

int bindImagePaste(void Function(PickedBytes file) onImage) {
  final id = ++_pasteBindId;
  _detachPasteListener();
  _onImage = onImage;

  _pasteListener = (html.Event event) {
    if (id != _pasteBindId) return;
    // Use only ClipboardEvent data — never navigator.clipboard.read()
    // (Chrome Paste permission bubble steals left-clicks).
    _tryClipboardEvent(event as html.ClipboardEvent);
  };

  html.document.addEventListener('paste', _pasteListener, true);
  html.window.addEventListener('paste', _pasteListener, true);
  return id;
}

void unbindImagePaste([int? id]) {
  if (id != null && id != _pasteBindId) return;
  _detachPasteListener();
  _onImage = null;
}

void _detachPasteListener() {
  if (_pasteListener != null) {
    html.document.removeEventListener('paste', _pasteListener, true);
    html.window.removeEventListener('paste', _pasteListener, true);
    _pasteListener = null;
  }
}

/// dart2js-safe blob read: ArrayBuffer fails `is ByteBuffer`, so use data-URL.
Future<Uint8List?> readBlobAsBytes(dynamic blob) async {
  final reader = html.FileReader();
  final loaded = reader.onLoadEnd.first;
  reader.readAsDataUrl(blob as html.Blob);
  await loaded;
  final result = reader.result;
  if (result is! String) return null;
  final comma = result.indexOf(',');
  if (comma < 0) return null;
  try {
    return Uint8List.fromList(base64Decode(result.substring(comma + 1)));
  } catch (_) {
    return null;
  }
}
