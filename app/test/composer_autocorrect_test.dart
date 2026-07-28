import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet/util/composer_autocorrect.dart';
import 'package:privet/widgets/composer_autocorrect_controller.dart';

void main() {
  late ComposerAutocorrectDictionary dict;

  setUp(() {
    dict = ComposerAutocorrectDictionary.instance;
    // Frequency order: earlier = more common.
    dict.loadFromWords(const [
      'the',
      'and',
      'that',
      'their',
      'while',
      'about',
      'world',
      'hello',
      'test',
      'from',
      'form',
      'for',
      'receive',
      'wheel', // much rarer than while
      'cat',
      'bat',
      'hat',
      'tech',
      'tea',
      'ten',
    ]);
  });

  group('correctionFor', () {
    test('fixes unique transpose typo whiel → while', () {
      expect(dict.correctionFor('whiel'), 'while');
    });

    test('fixes teh → the', () {
      expect(dict.correctionFor('teh'), 'the');
    });

    test('preserves Title Case', () {
      expect(dict.correctionFor('Whiel'), 'While');
    });

    test('skips ALL-CAPS tokens (acronyms)', () {
      expect(dict.correctionFor('WHIEL'), isNull);
      expect(dict.correctionFor('ABC'), isNull);
    });

    test('known word unchanged', () {
      expect(dict.correctionFor('while'), isNull);
      expect(dict.correctionFor('hello'), isNull);
    });

    test('does not change chat slang bro → pro', () {
      expect(dict.correctionFor('bro'), isNull);
      expect(dict.correctionFor('Bro'), isNull);
    });

    test('does not touch contractions with apostrophe', () {
      expect(dict.correctionFor("what's"), isNull);
      expect(dict.correctionFor("don't"), isNull);
      expect(dict.correctionFor("can't"), isNull);
    });

    test('does not strip apostrophe from what\'s in a sentence', () {
      expect(dict.tryAutocorrect("what's ", 7), isNull);
      expect(dict.tryAutocorrect("what's up ", 10), isNull);
      // Apostrophe is not a word delimiter, so mid-contraction is ignored.
      expect(dict.tryAutocorrect("what'", 5), isNull);
    });

    test('bhut → but (delete stray letter)', () {
      expect(dict.correctionFor('bhut'), 'but');
    });

    test('chat typos from real usage', () {
      expect(dict.correctionFor('wht'), 'what');
      expect(dict.correctionFor('heer'), 'here');
      expect(dict.correctionFor('gong'), 'going');
      expect(dict.correctionFor('wassap'), 'wassup');
      expect(dict.correctionFor('corrctin'), 'correcting');
      expect(dict.correctionFor('bro'), isNull);
      expect(dict.correctionFor("what's"), isNull);
    });

    test('sentence of chat typos corrects last word', () {
      final a = dict.tryAutocorrect('wht is gong on heer ', 20);
      expect(a, isNotNull);
      expect(a!.original, 'heer');
      expect(a.corrected, 'here');
    });

    test('findSpellIssues underlines ths fxd cnty and suggests fixes', () {
      dict.loadFromWords(const [
        'the', 'this', 'thus', 'is', 'or', 'not', 'i', 'a', 'and', 'for',
        'fixed', 'fax', 'fed', 'can', 'cant', 'cent', 'cut', 'understand',
        'while', 'hello', 'but', 'what', 'here', 'going', 'correction',
      ]);
      final issues = dict.findSpellIssues("is ths fxd or not i cn't understand ");
      final words = issues.map((e) => e.word).toList();
      expect(words, contains('ths'));
      expect(words, contains('fxd'));
      expect(words, contains("cn't"));
      expect(words, isNot(contains('is')));
      expect(words, isNot(contains('understand')));

      final ths = issues.firstWhere((e) => e.word == 'ths');
      expect(ths.suggestions, isNotEmpty);
      expect(ths.suggestions.take(3).length, lessThanOrEqualTo(3));
      expect(
        ths.suggestions.any((s) => s.toLowerCase() == 'this' || s.toLowerCase() == 'the'),
        isTrue,
      );

      final cnt = issues.firstWhere((e) => e.word == "cn't");
      expect(
        cnt.suggestions.any((s) => s.toLowerCase().replaceAll("'", '') == 'cant' || s.contains("'")),
        isTrue,
      );
    });

    test('does not underline the word still being typed', () {
      dict.loadFromWords(const [
        'the', 'this', 'hello', 'world', 'well', 'will', 'wall',
      ]);
      // Mid-word — no trailing space yet.
      expect(dict.findSpellIssues('wll'), isEmpty);
      expect(dict.findSpellIssues('hello wll'), isEmpty);
      // Finished with space — underline.
      final issues = dict.findSpellIssues('hello wll ');
      expect(issues.map((e) => e.word), contains('wll'));
      // Finished word stays underlined while typing the next one.
      final midNext = dict.findSpellIssues('hello wll wor');
      expect(midNext.map((e) => e.word), contains('wll'));
      expect(midNext.map((e) => e.word), isNot(contains('wor')));
    });

    test('valid are / aren\'t / isn\'t stay clean; isnt / arent underline', () {
      dict.loadFromWords(const [
        'the', 'and', 'are', 'is', 'not', 'hello', 'world',
        // Junk bare form like the real frequency list.
        'isnt',
      ]);
      final clean = dict.findSpellIssues("aren't isn't are ");
      expect(clean, isEmpty);

      final typos = dict.findSpellIssues('isnt arent ');
      expect(typos.map((e) => e.word), containsAll(['isnt', 'arent']));
      final isnt = typos.firstWhere((e) => e.word == 'isnt');
      expect(
        isnt.suggestions.any((s) => s.toLowerCase() == "isn't"),
        isTrue,
      );
    });

    test('autocorrects bare contractions on space', () {
      dict.loadFromWords(const ['the', 'is', 'are', 'isnt', 'hello']);
      final isnt = dict.tryAutocorrect('isnt ', 5);
      expect(isnt, isNotNull);
      expect(isnt!.original, 'isnt');
      expect(isnt.corrected, "isn't");

      final arent = dict.tryAutocorrect('arent ', 6);
      expect(arent, isNotNull);
      expect(arent!.original, 'arent');
      expect(arent.corrected, "aren't");

      expect(dict.correctionFor("aren't"), isNull);
      expect(dict.correctionFor("isn't"), isNull);
    });

    test('unique edit-1 still wins when same word reachable twice', () {
      // sugestion → suggestion via insert 'g' at two indices; must not
      // treat that as an ambiguous multi-hit failure.
      dict.loadFromWords(List.generate(6000, (i) => 'pad$i')
        ..add('suggestion')
        ..add('hello'));
      expect(dict.correctionFor('sugestion'), 'suggestion');
      final a = dict.tryAutocorrect('sugestion ', 10);
      expect(a, isNotNull);
      expect(a!.corrected, 'suggestion');
    });

    test('missing space: correctthings → correct things', () {
      dict.loadFromWords(const [
        'the', 'and', 'correct', 'things', 'thing', 'cor', 'rect',
        'hello', 'people', 'thank', 'you', 'good', 'morning',
        'something', 'some',
      ]);
      expect(dict.correctionFor('correctthings'), 'correct things');
      expect(dict.correctionFor('Correctthings'), 'Correct things');
      final a = dict.tryAutocorrect('correctthings ', 14);
      expect(a, isNotNull);
      expect(a!.corrected, 'correct things');

      // Known solid compound stays intact.
      expect(dict.correctionFor('something'), isNull);

      final issues = dict.findSpellIssues('correctthings ');
      expect(issues.map((e) => e.word), contains('correctthings'));
      expect(
        issues.firstWhere((e) => e.word == 'correctthings').suggestions.first,
        'correct things',
      );
    });

    test('no underline without suggestions; gibberish gets prefix guesses', () {
      dict.loadFromWords(const [
        'the', 'and', 'ask', 'asked', 'asia', 'aside', 'hello', 'world',
        'association', 'assist',
      ]);
      // Pure mash with no prefix family in dict → no underline.
      expect(dict.findSpellIssues('qqqqzzzxxx '), isEmpty);

      // Shares "as…" with ask/asia/aside → underline + suggestions.
      final issues = dict.findSpellIssues('asdfadsfasdf ');
      expect(issues.map((e) => e.word), contains('asdfadsfasdf'));
      final s = issues.firstWhere((e) => e.word == 'asdfadsfasdf').suggestions;
      expect(s, isNotEmpty);
      expect(s.length, lessThanOrEqualTo(3));
      expect(
        s.any((e) => ['ask', 'asia', 'aside', 'asked'].contains(e.toLowerCase())),
        isTrue,
      );
    });

    test('skips ambiguous distance-1 (cat/bat/hat)', () {
      expect(dict.correctionFor('zat'), isNull);
    });

    test('skips short tokens', () {
      expect(dict.correctionFor('te'), isNull);
      expect(dict.correctionFor('a'), isNull);
    });

    test('skips URLs and @/# tokens', () {
      expect(dict.correctionFor('http'), isNull);
      expect(dict.correctionFor('@whiel'), isNull);
      expect(dict.correctionFor('#whiel'), isNull);
    });

    test('skips tokens with digits', () {
      expect(dict.correctionFor('whiel2'), isNull);
    });
  });

  group('tryAutocorrect', () {
    test('corrects word just closed by space', () {
      final attempt = dict.tryAutocorrect('whiel ', 6);
      expect(attempt, isNotNull);
      expect(attempt!.original, 'whiel');
      expect(attempt.corrected, 'while');
      expect(attempt.replaceStart, 0);
      expect(attempt.replaceEnd, 5);
    });

    test('corrects before punctuation', () {
      final attempt = dict.tryAutocorrect('teh.', 4);
      expect(attempt, isNotNull);
      expect(attempt!.corrected, 'the');
    });

    test('no attempt mid-word', () {
      expect(dict.tryAutocorrect('whiel', 5), isNull);
    });

    test('corrects later word in sentence', () {
      final attempt = dict.tryAutocorrect('hello whiel ', 12);
      expect(attempt, isNotNull);
      expect(attempt!.original, 'whiel');
      expect(attempt.replaceStart, 6);
      expect(attempt.replaceEnd, 11);
    });
  });

  group('ComposerAutocorrectController', () {
    testWidgets('Backspace undoes correction and suppresses re-correct', (
      tester,
    ) async {
      final ctrl = ComposerAutocorrectController(text: 'whiel ');
      addTearDown(() {
        ctrl.clearMarks();
        ctrl.dispose();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AnimatedBuilder(
              animation: ctrl,
              builder: (context, _) => TextField(controller: ctrl),
            ),
          ),
        ),
      );

      ctrl.applyCorrection(
        const AutocorrectAttempt(
          replaceStart: 0,
          replaceEnd: 5,
          original: 'whiel',
          corrected: 'while',
        ),
        caretAfter: 6,
      );

      expect(ctrl.text, 'while ');
      expect(ctrl.mark, isNotNull);
      expect(ctrl.backspaceUndoArmed, isTrue);
      expect(ctrl.selection.baseOffset, 6);
      expect(ctrl.tryUndoWithBackspace(), isTrue);
      expect(ctrl.text, 'whiel ');
      expect(ctrl.mark, isNull);

      ctrl.applyCorrection(
        const AutocorrectAttempt(
          replaceStart: 0,
          replaceEnd: 5,
          original: 'whiel',
          corrected: 'while',
        ),
        caretAfter: 6,
      );
      expect(ctrl.text, 'whiel ');
      expect(ctrl.mark, isNull);

      await tester.pump(const Duration(seconds: 9));
    });

    testWidgets('moving caret disarms Backspace undo so letters delete', (
      tester,
    ) async {
      final ctrl = ComposerAutocorrectController(text: 'teh ');
      addTearDown(() {
        ctrl.clearMarks();
        ctrl.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TextField(controller: ctrl))),
      );

      ctrl.applyCorrection(
        const AutocorrectAttempt(
          replaceStart: 0,
          replaceEnd: 3,
          original: 'teh',
          corrected: 'the',
        ),
        caretAfter: 4,
      );
      expect(ctrl.backspaceUndoArmed, isTrue);

      // User moves into the word to delete a letter — must not steal Backspace.
      ctrl.selection = const TextSelection.collapsed(offset: 2);
      ctrl.syncAfterEdit();
      expect(ctrl.backspaceUndoArmed, isFalse);
      expect(ctrl.tryUndoWithBackspace(), isFalse);
      expect(ctrl.text, 'the '); // unchanged; normal delete can proceed
      expect(ctrl.mark, isNotNull); // highlight may remain

      await tester.pump(const Duration(seconds: 9));
    });

    testWidgets('editing corrected word suppresses that typo', (tester) async {
      final ctrl = ComposerAutocorrectController(text: 'teh ');
      addTearDown(() {
        ctrl.clearMarks();
        ctrl.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TextField(controller: ctrl))),
      );

      ctrl.applyCorrection(
        const AutocorrectAttempt(
          replaceStart: 0,
          replaceEnd: 3,
          original: 'teh',
          corrected: 'the',
        ),
        caretAfter: 4,
      );
      expect(ctrl.text, 'the ');
      expect(ctrl.mark, isNotNull);

      // User edits inside the corrected word.
      ctrl.value = const TextEditingValue(
        text: 'thx ',
        selection: TextSelection.collapsed(offset: 3),
      );
      ctrl.syncAfterEdit();
      expect(ctrl.mark, isNull);

      // Retyping the original typo should not auto-correct again.
      ctrl.value = const TextEditingValue(
        text: 'teh ',
        selection: TextSelection.collapsed(offset: 4),
      );
      ctrl.applyCorrection(
        const AutocorrectAttempt(
          replaceStart: 0,
          replaceEnd: 3,
          original: 'teh',
          corrected: 'the',
        ),
        caretAfter: 4,
      );
      expect(ctrl.text, 'teh ');
      expect(ctrl.mark, isNull);
    });

    testWidgets('typing boundary applies curated correction', (tester) async {
      final ctrl = ComposerAutocorrectController();
      addTearDown(() {
        ctrl.clearMarks();
        ctrl.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TextField(controller: ctrl)),
        ),
      );

      ctrl.value = const TextEditingValue(
        text: 'teh ',
        selection: TextSelection.collapsed(offset: 4),
      );
      final attempt = ComposerAutocorrectDictionary.instance.tryAutocorrect(
        ctrl.text,
        ctrl.selection.baseOffset,
      );
      expect(attempt, isNotNull);
      ctrl.applyCorrection(attempt!, caretAfter: 4);
      expect(ctrl.text, 'the ');
      expect(ctrl.mark?.original, 'teh');
      ctrl.clearMarks();
      await tester.pump(const Duration(seconds: 9));
    });
  });
}
