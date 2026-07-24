// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;

class ClipboardImageBlob {
  ClipboardImageBlob({required this.blob, required this.mimeType});
  final html.Blob blob;
  final String mimeType;
}

/// Async Clipboard API read for image pastes (Chromium).
Future<List<ClipboardImageBlob>> readClipboardImageBlobs() async {
  try {
    final clipboard = html.window.navigator.clipboard;
    if (clipboard == null) return const [];
    final items = await (clipboard as dynamic).read() as List<dynamic>;
    final out = <ClipboardImageBlob>[];
    for (final item in items) {
      final types =
          (item.types as List?)?.map((e) => '$e').toList() ?? const <String>[];
      final imageType = types.firstWhere(
        (t) => t.startsWith('image/'),
        orElse: () => '',
      );
      if (imageType.isEmpty) continue;
      final blob = await item.getType(imageType) as html.Blob;
      out.add(ClipboardImageBlob(blob: blob, mimeType: imageType));
    }
    return out;
  } catch (_) {
    return const [];
  }
}
