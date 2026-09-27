import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:privet/util/clipboard_files.dart';
import 'package:privet/util/media_kind.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('privet_pick');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('video path is kept without loading bytes', () async {
    final file = File('${tmp.path}/clip.mp4');
    await file.writeAsBytes(Uint8List(80 * 1024));
    final picked = await pickedBytesFromRaw(
      bytes: null,
      path: file.path,
      filename: 'clip.mp4',
    );
    expect(picked, isNotNull);
    expect(picked!.path, file.path);
    expect(picked.bytes, isEmpty);
    expect(picked.fileSize, 80 * 1024);
    expect(picked.mimeType, 'video/mp4');
  });

  test('small image is loaded for the composer thumbnail', () async {
    final file = File('${tmp.path}/pic.png');
    final png = Uint8List.fromList([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
      0x00, 0x00, 0x00, 0x00,
    ]);
    await file.writeAsBytes(png);
    final picked = await pickedBytesFromRaw(
      bytes: null,
      path: file.path,
      filename: 'pic.png',
    );
    expect(picked, isNotNull);
    expect(picked!.hasPreviewBytes, isTrue);
    expect(picked.bytes, png);
    expect(picked.path, file.path);
  });

  test('oversized file is rejected before bytes are read', () async {
    expect(
      () => ensureUploadFits(kMaxUploadBytes + 1024),
      throwsA(isA<FileTooLargeException>()),
    );
    expect(
      FileTooLargeException().toString(),
      'File too large (max 512MB)',
    );
  });
}
