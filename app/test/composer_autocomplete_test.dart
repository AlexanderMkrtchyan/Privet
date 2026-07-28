import 'package:flutter_test/flutter_test.dart';
import 'package:privet/util/composer_autocomplete.dart';

void main() {
  group('parenthetical emoticons', () {
    test('suggests matching shortcodes', () {
      final match = matchComposerAutocomplete('(sm', 3)!;
      expect(match.replaceStart, 0);
      expect(match.replaceEnd, 3);
      expect(match.suggestions.map((s) => s.label), contains('(smile)'));
      expect(match.suggestions.first.insert.trim().isNotEmpty, isTrue);
    });

    test('ignores bare open paren', () {
      expect(matchComposerAutocomplete('(', 1), isNull);
    });

    test('ignores closed shortcodes', () {
      expect(matchComposerAutocomplete('(smile)', 7), isNull);
    });
  });

  group('western faces', () {
    test('does not open autocomplete popup', () {
      expect(matchComposerAutocomplete(':-', 2), isNull);
      expect(matchComposerAutocomplete(':D', 2), isNull);
      expect(matchComposerAutocomplete(':(', 2), isNull);
      expect(matchComposerAutocomplete(':', 1), isNull);
    });
  });

  group('AI commands', () {
    test('suggests when AI enabled', () {
      final match = matchComposerAutocomplete('#', 1, aiEnabled: true)!;
      expect(match.suggestions.map((s) => s.label), contains('# summarize'));
      expect(match.suggestions.map((s) => s.label), contains('#me'));
    });

    test('skips when AI disabled', () {
      expect(matchComposerAutocomplete('#', 1, aiEnabled: false), isNull);
    });

    test('filters by prefix', () {
      final match = matchComposerAutocomplete('#me s', 5, aiEnabled: true)!;
      expect(
        match.suggestions.map((s) => s.label),
        contains('#me summarize'),
      );
    });
  });
}
