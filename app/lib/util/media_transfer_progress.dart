import 'package:flutter/foundation.dart';

/// Per-message 0–1 upload progress. Bubbles listen here so the chat list
/// does not rebuild on every chunk.
final Map<String, ValueNotifier<double>> _progress = {};

ValueNotifier<double> mediaTransferProgressOf(String id) =>
    _progress.putIfAbsent(id, () => ValueNotifier<double>(0));

void setMediaTransferProgress(String id, double value) {
  mediaTransferProgressOf(id).value = value.clamp(0.0, 1.0);
}

void clearMediaTransferProgress(String id) {
  final notifier = _progress.remove(id);
  notifier?.dispose();
}
