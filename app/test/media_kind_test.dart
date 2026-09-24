import 'package:flutter_test/flutter_test.dart';
import 'package:privet/util/media_kind.dart';

void main() {
  test('mediaKindFromMime classifies video and image', () {
    expect(mediaKindFromMime('video/mp4', filename: 'clip.mp4'), 'video');
    expect(mediaKindFromMime('image/jpeg', filename: 'pic.jpg'), 'image');
    expect(mediaKindFromMime('application/octet-stream', filename: 'clip.mov'),
        'video');
    expect(mediaKindFromMime('application/pdf', filename: 'doc.pdf'), 'file');
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
}
