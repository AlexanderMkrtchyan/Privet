import 'package:flutter_test/flutter_test.dart';
import 'package:privet/util/emoji_style.dart';
import 'package:privet/util/noto_color_emoji.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await NotoColorEmojiCache.instance.ensureLoaded();
  });

  test('atlas loads the same Noto strikes Linux paints', () {
    expect(NotoColorEmojiCache.instance.isLoaded, isTrue);
    expect(NotoColorEmojiCache.instance.debugLoadError, isNull);
    for (final glyph in ['👍', '❤️', '😂', '🇺🇸', '👩‍💻', '1️⃣', '🏳️‍🌈']) {
      expect(
        NotoColorEmojiCache.instance.hasGlyph(glyph),
        isTrue,
        reason: glyph,
      );
    }
    expect(NotoColorEmojiCache.instance.hasGlyph('abc'), isFalse);
    expect(isNotoAtlasGrapheme(kGoogleEmojiMark), isFalse);
  });

  test('bundled Noto path is Windows-only unless forced', () {
    expect(privetForceBundledNotoEmoji, isFalse);
    expect(useBundledNotoColorEmoji, isFalse);
    privetForceBundledNotoEmoji = true;
    addTearDown(() => privetForceBundledNotoEmoji = false);
    expect(useBundledNotoColorEmoji, isTrue);
  });
}
