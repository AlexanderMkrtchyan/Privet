import 'dart:typed_data';

/// Client upload cap. Must stay in sync with `MAX_UPLOAD_BYTES` on the server.
const int kMaxUploadBytes = 1024 * 1024 * 1024;

/// Cloudflare's proxied request cap is 100 MB. Stay under it per request.
const int kUploadChunkBytes = 90 * 1024 * 1024;

/// Images smaller than this stay in RAM for the composer thumbnail.
/// Videos and bigger files keep a disk path and are streamed on send.
const int kMaxInMemoryAttachBytes = 12 * 1024 * 1024;

void ensureUploadFits(int size) {
  if (size > kMaxUploadBytes) throw const FileTooLargeException();
}

class FileTooLargeException implements Exception {
  const FileTooLargeException();

  @override
  String toString() => 'File too large (max 1 GB)';
}

String mimeForFilename(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.bmp') || lower.endsWith('.dib')) return 'image/bmp';
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

bool _imageFilename(String name) {
  return name.endsWith('.png') ||
      name.endsWith('.jpg') ||
      name.endsWith('.jpeg') ||
      name.endsWith('.gif') ||
      name.endsWith('.webp') ||
      name.endsWith('.bmp') ||
      name.endsWith('.dib');
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
  if (_imageFilename(name)) return 'image';
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

bool looksLikeImage({String? mimeType, String? filename, String? url}) {
  if (mediaKindFromMime(mimeType ?? '', filename: filename ?? '') == 'image') {
    return true;
  }
  final source = (filename ?? url ?? '').toLowerCase();
  return _imageFilename(source.split('?').first);
}

/// MIME from image magic bytes. Used when paste/camera omit a type.
String sniffImageMime(Uint8List bytes, {String fallback = 'image/png'}) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return 'image/png';
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
    return 'image/jpeg';
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46) {
    return 'image/gif';
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'image/webp';
  }
  if (bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D) {
    return 'image/bmp';
  }
  return fallback;
}

String imageExtensionForMime(String mime) {
  return switch (mime.split(';').first.trim().toLowerCase()) {
    'image/jpeg' => 'jpg',
    'image/gif' => 'gif',
    'image/webp' => 'webp',
    'image/bmp' || 'image/x-ms-bmp' || 'image/x-bmp' => 'bmp',
    _ => 'png',
  };
}

/// 0–1 progress as a whole-percent label (`37%`).
String formatTransferPercent(double progress) {
  final pct = (progress.clamp(0.0, 1.0) * 100).round();
  return '$pct%';
}
