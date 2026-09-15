import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:privet/util/kolobok_smileys.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The mapping is hand-maintained against a pack that ships as opaque GIFs
  // with no index file, so a typo would only surface as a blank smiley in a
  // real chat. Load every path instead.
  test('every mapped smiley ships in both backgrounds', () async {
    for (final entry in kolobokSmileys) {
      for (final light in [true, false]) {
        final path = kolobokAssetPath(entry.file, light: light);
        final data = await rootBundle.load(path);
        expect(data.lengthInBytes, greaterThan(0), reason: path);
      }
    }
  });

  test('a glyph resolves to its pack file, ignoring variation selectors', () {
    expect(kolobokFileForEmoji('🙂'), 'smile');
    expect(kolobokFileForEmoji('❤️'), 'heart');
    expect(kolobokFileForEmoji('❤'), 'heart');
    expect(kolobokFileForEmoji('  ❤️  '), 'heart');
    expect(kolobokFileForEmoji(''), isNull);
    expect(kolobokFileForEmoji('zzz'), isNull);
  });

  test('the two backgrounds stay apart', () {
    expect(kolobokAssetPath('smile', light: true), contains('/light/'));
    expect(kolobokAssetPath('smile', light: false), contains('/dark/'));
    expect(kolobokAssetPath('smile', light: true), isNot(
      kolobokAssetPath('smile', light: false),
    ));
  });

  test('every entry maps back to its own glyph', () {
    for (final entry in kolobokSmileys) {
      expect(kolobokEmojiForFile(entry.file), entry.emoji);
    }
  });

  test('pack files are unique and non-empty', () {
    final files = kolobokSmileys.map((entry) => entry.file).toList();
    expect(files.toSet(), hasLength(files.length));
    expect(files, isNot(contains('')));
  });
}
