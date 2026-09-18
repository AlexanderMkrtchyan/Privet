import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:privet/util/kolobok_smileys.dart';
import 'package:privet/util/kolobok_webp.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('parseAnimatedWebp reads Kolobok ANMF frames', () async {
    final data = await rootBundle.load(kolobokAssetPath('smile', light: true));
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final anim = parseAnimatedWebp(bytes);
    expect(anim, isNotNull);
    expect(anim!.canvasWidth, 144);
    expect(anim.canvasHeight, 176);
    expect(anim.frames, hasLength(7));
    expect(anim.frames.first.offsetX, 0);
    expect(anim.frames.first.offsetY, 0);
    expect(anim.frames.first.width, 144);
    expect(anim.frames.first.height, 176);
    expect(anim.frames.first.durationMs, 1700);
    expect(anim.frames.first.blend, isFalse);
    expect(isRiffWebp(anim.frames.first.stillWebp), isTrue);
  });

  test('ANMF still wrap decodes as a single VP8L image', () async {
    final data = await rootBundle.load(kolobokAssetPath('smile', light: true));
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final anim = parseAnimatedWebp(bytes)!;
    final codec = await ui.instantiateImageCodec(anim.frames.first.stillWebp);
    expect(codec.frameCount, 1);
    final frame = await codec.getNextFrame();
    expect(frame.image.width, 144);
    expect(frame.image.height, 176);
    frame.image.dispose();
    codec.dispose();
  });

  test('offset ANMF frames keep the *2 canvas origin from the RIFF spec', () async {
    final data = await rootBundle.load(kolobokAssetPath('rofl', light: true));
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final anim = parseAnimatedWebp(bytes);
    expect(anim, isNotNull);
    expect(anim!.frames.length, greaterThan(50));
    final shifted = anim.frames.where((f) => f.offsetX != 0 || f.offsetY != 0);
    expect(shifted, isNotEmpty);
    expect(shifted.first.offsetX % 2, 0);
  });

  test('junk bytes are not treated as animated WebP', () {
    expect(parseAnimatedWebp(Uint8List.fromList([1, 2, 3, 4])), isNull);
  });
}
