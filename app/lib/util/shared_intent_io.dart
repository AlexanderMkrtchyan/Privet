import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, debugPrint, kIsWeb;
import 'package:flutter/services.dart';

import 'clipboard_files.dart';
import 'shared_intent.dart';

const _channel = MethodChannel('privet/shared_intent');

Future<List<SharedDraft>> takePendingShares() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
    return const [];
  }
  try {
    final raw = await _channel.invokeMethod<List<dynamic>>('takePending');
    if (raw == null || raw.isEmpty) return const [];
    final drafts = <SharedDraft>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final files = <PickedBytes>[];
      final rawFiles = map['files'];
      if (rawFiles is List) {
        for (final f in rawFiles) {
          if (f is! Map) continue;
          final path = f['path']?.toString();
          final bytes = (path == null) ? null : await _readFile(path);
          if (bytes == null || bytes.isEmpty) continue;
          files.add(
            PickedBytes(
              bytes: bytes,
              filename: f['fileName']?.toString() ?? 'shared',
              mimeType:
                  f['mimeType']?.toString() ?? 'application/octet-stream',
            ),
          );
        }
      }
      final draft = SharedDraft(
        text: map['text']?.toString(),
        subject: map['subject']?.toString(),
        files: files,
      );
      if (!draft.isEmpty) drafts.add(draft);
    }
    return drafts;
  } catch (e, st) {
    debugPrint('[privet] takePendingShares failed: $e\n$st');
    return const [];
  }
}

Future<Uint8List?> _readFile(String path) async {
  try {
    return await File(path).readAsBytes();
  } catch (_) {
    return null;
  }
}
