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
          if (path == null || path.isEmpty) continue;
          try {
            final picked = await pickedBytesFromRaw(
              bytes: null,
              path: path,
              filename: f['fileName']?.toString() ?? 'shared',
              mimeType: f['mimeType']?.toString(),
            );
            if (picked != null) files.add(picked);
          } catch (e, st) {
            debugPrint('[privet] shared file skipped: $e\n$st');
          }
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
