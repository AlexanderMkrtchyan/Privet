/// Client upload cap. Must stay in sync with `MAX_UPLOAD_BYTES` on the server.
const int kMaxUploadBytes = 512 * 1024 * 1024;

String mimeForFilename(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.mp4')) return 'video/mp4';
  if (lower.endsWith('.webm')) return 'video/webm';
  if (lower.endsWith('.mov')) return 'video/quicktime';
  if (lower.endsWith('.m4v')) return 'video/mp4';
  if (lower.endsWith('.mp3')) return 'audio/mpeg';
  if (lower.endsWith('.wav')) return 'audio/wav';
  if (lower.endsWith('.m4a')) return 'audio/mp4';
  if (lower.endsWith('.ogg')) return 'audio/ogg';
  if (lower.endsWith('.pdf')) return 'application/pdf';
  return 'application/octet-stream';
}

String mediaKindFromMime(String mime, {String filename = ''}) {
  final type = mime.toLowerCase();
  if (type.startsWith('image/')) return 'image';
  if (type.startsWith('video/')) return 'video';
  if (type.startsWith('audio/')) return 'audio';
  final name = filename.toLowerCase();
  if (name.endsWith('.mp4') ||
      name.endsWith('.mov') ||
      name.endsWith('.webm') ||
      name.endsWith('.m4v')) {
    return 'video';
  }
  if (name.endsWith('.png') ||
      name.endsWith('.jpg') ||
      name.endsWith('.jpeg') ||
      name.endsWith('.gif') ||
      name.endsWith('.webp')) {
    return 'image';
  }
  return 'file';
}

bool looksLikeVideo({String? mimeType, String? filename, String? url}) {
  if (mediaKindFromMime(mimeType ?? '', filename: filename ?? '') == 'video') {
    return true;
  }
  final source = (filename ?? url ?? '').toLowerCase();
  return source.endsWith('.mp4') ||
      source.endsWith('.mov') ||
      source.endsWith('.webm') ||
      source.endsWith('.m4v') ||
      source.contains('.mp4?') ||
      source.contains('.mov?') ||
      source.contains('.webm?') ||
      source.contains('.m4v?');
}

/// 0–1 progress as a whole-percent label (`37%`).
String formatTransferPercent(double progress) {
  final pct = (progress.clamp(0.0, 1.0) * 100).round();
  return '$pct%';
}
