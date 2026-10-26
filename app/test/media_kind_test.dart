import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:privet/util/media_kind.dart';

void main() {
  test('mediaKindFromMime classifies video and image', () {
    expect(mediaKindFromMime('video/mp4', filename: 'clip.mp4'), 'video');
    expect(mediaKindFromMime('image/jpeg', filename: 'pic.jpg'), 'image');
    expect(mediaKindFromMime('application/octet-stream', filename: 'clip.mov'),
        'video');
    expect(mediaKindFromMime('application/pdf', filename: 'doc.pdf'), 'file');
    expect(mediaKindFromMime('image/bmp', filename: 'pic.bmp'), 'image');
    expect(mediaKindFromMime('application/octet-stream', filename: 'pic.bmp'),
        'image');
  });

  test('mimeForFilename maps bmp', () {
    expect(mimeForFilename('photo.bmp'), 'image/bmp');
    expect(mimeForFilename('photo.BMP'), 'image/bmp');
    expect(mimeForFilename('clip.dib'), 'image/bmp');
  });

  test('sniffImageMime recognizes BMP magic', () {
    expect(sniffImageMime(Uint8List.fromList([0x42, 0x4D, 0x00])), 'image/bmp');
    expect(sniffImageMime(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47])),
        'image/png');
  });

  test('looksLikeImage uses filename and url', () {
    expect(looksLikeImage(filename: 'pic.bmp'), isTrue);
    expect(looksLikeImage(url: '/media/uuid.bmp'), isTrue);
    expect(looksLikeImage(mimeType: 'image/x-ms-bmp'), isTrue);
    expect(looksLikeImage(filename: 'notes.pdf'), isFalse);
  });

  test('formatTransferPercent is a whole percent', () {
    expect(formatTransferPercent(0), '0%');
    expect(formatTransferPercent(0.374), '37%');
    expect(formatTransferPercent(1), '100%');
    expect(formatTransferPercent(1.4), '100%');
  });

  test('looksLikeVideo uses filename and url', () {
    expect(looksLikeVideo(filename: 'clip.mp4'), isTrue);
    expect(looksLikeVideo(url: 'https://x/a.webm?x=1'), isTrue);
    expect(looksLikeVideo(filename: 'pic.jpg'), isFalse);
  });

  test('ensureUploadFits allows 256MB and rejects over 1GB', () {
    expect(() => ensureUploadFits(256 * 1024 * 1024), returnsNormally);
    expect(() => ensureUploadFits(kMaxUploadBytes), returnsNormally);
    expect(
      () => ensureUploadFits(kMaxUploadBytes + 1),
      throwsA(isA<FileTooLargeException>()),
    );
  });
}
