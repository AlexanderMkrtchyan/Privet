import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet/widgets/selectable_markup_text.dart';

/// Every bundled Kolobok is painted *over* the text layer, so the painted rect
/// must stay inside the slot reserved by the placeholder run. Anything wider
/// lands on the neighbouring glyph — the pack's wide artwork (≈3/4 of the files
/// are wider than tall) used to cover the letter before the smiley.
class _Art {
  const _Art(this.file, this.w, this.h);
  final String file;
  final int w;
  final int h;
}

Future<List<_Art>> _loadPack(String brightness) async {
  final dir = Directory('assets/emoji/kolobok/$brightness');
  final out = <_Art>[];
  for (final file in dir.listSync().whereType<File>()) {
    if (!file.path.endsWith('.webp')) continue;
    final bytes = file.readAsBytesSync();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    out.add(_Art(
      file.uri.pathSegments.last.replaceAll('.webp', ''),
      frame.image.width,
      frame.image.height,
    ));
    codec.dispose();
  }
  out.sort((a, b) => a.file.compareTo(b.file));
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const platforms = <TargetPlatform>[
    TargetPlatform.android,
    TargetPlatform.linux,
    TargetPlatform.windows,
    TargetPlatform.macOS,
  ];
  const fontSizes = <double>[11, 13, 15, 20, 30];

  test('pack is present for both brightnesses', () async {
    expect(await _loadPack('light'), hasLength(greaterThan(90)));
    expect(await _loadPack('dark'), hasLength(greaterThan(90)));
  });

  for (final brightness in ['light', 'dark']) {
    test('$brightness art never paints over neighbouring glyphs', () async {
      final pack = await _loadPack(brightness);
      for (final platform in platforms) {
        debugDefaultTargetPlatformOverride = platform;
        for (final em in fontSizes) {
          // Reserved slot as the placeholder run lays it out (see _splitKolobok).
          final slot = Rect.fromLTWH(0, 0, smileyAdvanceEm * em, em * 1.35);
          for (final art in pack) {
            final artSlot = kolobokArtSlot(slot, em);
            final scale = kolobokPaintScale(
              slot: artSlot,
              imageWidth: art.w,
              imageHeight: art.h,
              fontSize: em,
            );
            expect(
              scale,
              greaterThan(0),
              reason: '${art.file} @$platform ${em}px produced no scale',
            );
            final destH = art.h * scale;
            final dest = kolobokDestRect(
              artSlot: artSlot,
              center: kolobokPaintCenter(
                slot: artSlot,
                destHeight: destH,
                fontSize: em,
                baseline: slot.height * 0.8,
              ),
              width: art.w * scale,
              height: destH,
            );
            final why = '${art.file} ${art.w}x${art.h} @$platform ${em}px '
                'dest=$dest artSlot=$artSlot';
            expect(dest.left, greaterThanOrEqualTo(artSlot.left - 0.01),
                reason: why);
            expect(dest.right, lessThanOrEqualTo(artSlot.right + 0.01),
                reason: why);
          }
        }
      }
      debugDefaultTargetPlatformOverride = null;
    });

    test('$brightness art survives a collapsed slot', () async {
      // A narrow slot (tight bubble / small font) must still clamp, not spill.
      for (final platform in platforms) {
        debugDefaultTargetPlatformOverride = platform;
        const em = 15.0;
        final slot = Rect.fromLTWH(0, 0, smileyAdvanceEm * em * 0.55, em * 1.3);
        for (final art in await _loadPack(brightness)) {
          final artSlot = kolobokArtSlot(slot, em);
          final scale = kolobokPaintScale(
            slot: artSlot,
            imageWidth: art.w,
            imageHeight: art.h,
            fontSize: em,
          );
          final destH = art.h * scale;
          final dest = kolobokDestRect(
            artSlot: artSlot,
            center: kolobokPaintCenter(
              slot: artSlot,
              destHeight: destH,
              fontSize: em,
            ),
            width: art.w * scale,
            height: destH,
          );
          expect(dest.left, greaterThanOrEqualTo(artSlot.left - 0.01),
              reason: '${art.file} @$platform');
          expect(dest.right, lessThanOrEqualTo(artSlot.right + 0.01),
              reason: '${art.file} @$platform');
        }
      }
      debugDefaultTargetPlatformOverride = null;
    });
  }

  test('common smileys keep the oversized look', () async {
    // The clamp must not shrink the canonical square-ish faces — only the
    // over-wide artwork needed trimming.
    for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
      debugDefaultTargetPlatformOverride = platform;
      for (final em in fontSizes) {
        final slot = Rect.fromLTWH(0, 0, smileyAdvanceEm * em, em * 1.35);
        final artSlot = kolobokArtSlot(slot, em);
        // smile.webp is 144x176 — the tallest shape in the pack.
        final scale = kolobokPaintScale(
          slot: artSlot,
          imageWidth: 144,
          imageHeight: 176,
          fontSize: em,
        );
        expect(176 * scale, greaterThan(em * 1.2),
            reason: 'smile too small @$platform ${em}px');
      }
    }
    debugDefaultTargetPlatformOverride = null;
  });

  test('composer pad + raise keeps tall art inside the field', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    for (final em in fontSizes) {
      final slot = Rect.fromLTWH(0, 0, smileyAdvanceEm * em, em * 1.35);
      final artSlot = kolobokArtSlot(slot, em);
      final scale = kolobokPaintScale(
        slot: artSlot,
        imageWidth: 144,
        imageHeight: 176,
        fontSize: em,
      );
      final destH = 176 * scale;
      final dest = kolobokDestRect(
        artSlot: artSlot,
        center: kolobokPaintCenter(
          slot: artSlot,
          destHeight: destH,
          fontSize: em,
          baseline: slot.height * 0.8,
        ),
        width: 144 * scale,
        height: destH,
      );
      final pad = kolobokInlineVerticalPad(em);
      // Composer field: line box plus the extra content padding.
      final field = Rect.fromLTRB(
        dest.left,
        slot.top - pad,
        dest.right,
        slot.bottom + pad,
      );
      expect(dest.top, greaterThanOrEqualTo(field.top - 0.01),
          reason: 'smile clipped at top ${em}px dest=$dest field=$field');
      expect(dest.bottom, lessThanOrEqualTo(field.bottom + 0.01),
          reason: 'smile clipped at bottom ${em}px dest=$dest field=$field');
    }
    debugDefaultTargetPlatformOverride = null;
  });
}
