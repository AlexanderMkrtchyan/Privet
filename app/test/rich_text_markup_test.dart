import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet/util/rich_text_markup.dart';

void main() {
  group('parseMarkup', () {
    test('plain text parses unchanged', () {
      final p = parseMarkup('hello world');
      expect(p.plainText, 'hello world');
      expect(p.runs, isEmpty);
    });

    test('bold', () {
      final p = parseMarkup('[b]bold[/b] rest');
      expect(p.plainText, 'bold rest');
      expect(p.runs, hasLength(1));
      expect(p.runs.single.start, 0);
      expect(p.runs.single.end, 4);
      expect(p.runs.single.format.bold, isTrue);
    });

    test('nested bold + italic', () {
      final p = parseMarkup('[b]a[i]b[/i][/b]');
      expect(p.plainText, 'ab');
      expect(p.runs, hasLength(2));
      expect(p.runs[0].format.bold, isTrue);
      expect(p.runs[0].format.italic, isFalse);
      expect(p.runs[1].format.bold, isTrue);
      expect(p.runs[1].format.italic, isTrue);
    });

    test('default highlight is yellow', () {
      final p = parseMarkup('[bg]hi[/bg]');
      expect(p.plainText, 'hi');
      expect(p.runs.single.format.background, kDefaultHighlight);
    });

    test('colored highlight', () {
      final p = parseMarkup('[bg=#ff0000]hi[/bg]');
      expect(p.runs.single.format.background, const Color(0xFFFF0000));
    });

    test('font family', () {
      final p = parseMarkup('[font=monospace]code[/font]');
      expect(p.plainText, 'code');
      expect(p.runs.single.format.fontFamily, 'monospace');
    });

    test('bundled google font family parses', () {
      final p = parseMarkup('[font=cinzel]legio[/font]');
      expect(p.plainText, 'legio');
      expect(p.runs.single.format.fontFamily, 'cinzel');
    });

    test('unclosed tag renders literally', () {
      final p = parseMarkup('[b]never closed');
      expect(p.plainText, '[b]never closed');
      expect(p.runs, isEmpty);
    });

    test('escaped brackets render literally', () {
      final p = parseMarkup(r'\[b\] literal');
      expect(p.plainText, '[b] literal');
      expect(p.runs, isEmpty);
    });

    test('escaped backslash', () {
      final p = parseMarkup(r'C:\\temp');
      expect(p.plainText, r'C:\temp');
    });

    test('tag-looking text without close stays literal', () {
      final p = parseMarkup('[bg=#ff0000] never closes');
      expect(p.plainText, '[bg=#ff0000] never closes');
    });
  });

  group('serializeMarkup', () {
    test('no runs escapes only exact tag starts', () {
      expect(serializeMarkup(r'check [foo] and [b]x', []), r'check [foo] and \[b]x');
    });

    test('bold run', () {
      expect(
        serializeMarkup('bold rest', [
          FormatRun(0, 4, const TextFormat(bold: true)),
        ]),
        '[b]bold[/b] rest',
      );
    });

    test('adjacent runs merge', () {
      expect(
        serializeMarkup('ab', [
          FormatRun(0, 1, const TextFormat(bold: true)),
          FormatRun(1, 2, const TextFormat(bold: true)),
        ]),
        '[b]ab[/b]',
      );
    });

    test('highlight color hex lowercased', () {
      expect(
        serializeMarkup('x', [
          FormatRun(0, 1, const TextFormat(background: Color(0xFFFF0000))),
        ]),
        '[bg=#ff0000]x[/bg]',
      );
    });

    test('font', () {
      expect(
        serializeMarkup('x', [
          FormatRun(0, 1, const TextFormat(fontFamily: 'serif')),
        ]),
        '[font=serif]x[/font]',
      );
    });

    test('every offered font key round trips', () {
      for (final f in kMessageFonts) {
        final markup = serializeMarkup('x', [
          FormatRun(0, 1, TextFormat(fontFamily: f)),
        ]);
        expect(markup, '[font=$f]x[/font]', reason: 'font key $f');
        final parsed = parseMarkup(markup);
        expect(parsed.runs.single.format.fontFamily, f, reason: 'font key $f');
      }
    });

    test('every offered font key has a human label', () {
      for (final f in kMessageFonts) {
        expect(kMessageFontLabels[f], isNotEmpty, reason: 'font key $f');
      }
    });

    test('round trips through parse', () {
      final plain = 'a [b] literal \\ path and bold words';
      final runs = [
        FormatRun(18, 22, const TextFormat(bold: true)),
        FormatRun(27, 31, const TextFormat(italic: true)),
      ];
      final markup = serializeMarkup(plain, runs);
      final parsed = parseMarkup(markup);
      expect(parsed.plainText, plain);
      final again = serializeMarkup(parsed.plainText, parsed.runs);
      expect(again, markup);
    });

    test('escape survives round trip', () {
      const plain = r'C:\Users\name\AppData';
      final markup = serializeMarkup(plain, const []);
      final parsed = parseMarkup(markup);
      expect(parsed.plainText, plain);
    });
  });

  group('selection operations', () {
    test('applyFormatToSelection overwrites interior only', () {
      const bold = TextFormat(bold: true);
      final runs = [
        FormatRun(0, 10, bold),
        FormatRun(20, 30, bold),
      ];
      final next = applyFormatToSelection(
        runs,
        5,
        25,
        const TextFormat(background: kDefaultHighlight),
      );
      // [0,5) bold, [5,25) highlight, [25,30) bold
      expect(next, hasLength(3));
      expect(next[0].format.bold, isTrue);
      expect(next[0].format.background, isNull);
      expect(next[1].format.bold, isFalse);
      expect(next[1].format.background, kDefaultHighlight);
      expect(next[2].format.bold, isTrue);
      expect(next[2].format.background, isNull);
    });

    test('applyFormatToSelection can clear a selection', () {
      const bold = TextFormat(bold: true);
      final runs = [FormatRun(0, 10, bold)];
      final next = applyFormatToSelection(
        runs,
        2,
        8,
        TextFormat.empty,
      );
      expect(next, hasLength(2));
      expect(next[0].end, 2);
      expect(next[1].start, 8);
    });

    test('selectionFormat merges across runs', () {
      final runs = [
        FormatRun(0, 3, const TextFormat(bold: true)),
        FormatRun(3, 6, const TextFormat(italic: true)),
      ];
      final merged = selectionFormat(runs, 0, 6);
      expect(merged.bold, isTrue);
      expect(merged.italic, isTrue);
    });

    test('toggledFormatOverSelection adds bold to plain selection', () {
      final desired = toggledFormatOverSelection(
        const [],
        0,
        3,
        bold: true,
      );
      expect(desired.bold, isTrue);
    });

    test('toggledFormatOverSelection removes bold from wholly-bold selection',
        () {
      final runs = [FormatRun(0, 3, const TextFormat(bold: true))];
      final desired = toggledFormatOverSelection(runs, 0, 3, bold: true);
      expect(desired.bold, isFalse);
    });

    test('toggledFormatOverSelection keeps mixed italic when toggling bold',
        () {
      final runs = [
        FormatRun(0, 3, const TextFormat(italic: true)),
      ];
      final desired = toggledFormatOverSelection(runs, 0, 3, bold: true);
      expect(desired.bold, isTrue);
      expect(desired.italic, isTrue);
    });

    test('toggledFormatOverSelection transparent clears highlight', () {
      final runs = [
        FormatRun(0, 3, const TextFormat(background: kDefaultHighlight)),
      ];
      final desired = toggledFormatOverSelection(
        runs,
        0,
        3,
        background: Colors.transparent,
      );
      expect(desired.background, isNull);
    });

    test('toggledFormatOverSelection empty font clears font', () {
      final runs = [
        FormatRun(0, 3, const TextFormat(fontFamily: 'serif')),
      ];
      final desired = toggledFormatOverSelection(runs, 0, 3, fontFamily: '');
      expect(desired.fontFamily, isNull);
    });
  });

  group('markupToPlain', () {
    test('strips markup', () {
      expect(markupToPlain('[b]a[/b] [i]b[/i] [bg]c[/bg]'), 'a b c');
    });
  });

  group('applyDefaultMessageFont', () {
    test('empty or blank default leaves markup unchanged', () {
      expect(applyDefaultMessageFont('hello', ''), 'hello');
      expect(applyDefaultMessageFont('[b]hi[/b]', '   '), '[b]hi[/b]');
    });

    test('plain text is wrapped in the default font', () {
      expect(
        applyDefaultMessageFont('hello world', 'gothic'),
        '[font=gothic]hello world[/font]',
      );
    });

    test('already fully explicit font is left alone', () {
      expect(
        applyDefaultMessageFont('[font=serif]hello[/font]', 'gothic'),
        '[font=serif]hello[/font]',
      );
    });

    test('partial explicit font nests inside the wrapper', () {
      final out = applyDefaultMessageFont(
        '[font=monospace]code[/font] rest',
        'gothic',
      );
      expect(out, '[font=gothic][font=monospace]code[/font] rest[/font]');
      final parsed = parseMarkup(out);
      expect(parsed.plainText, 'code rest');
      expect(parsed.runs[0].format.fontFamily, 'monospace');
      expect(parsed.runs[1].format.fontFamily, 'gothic');
    });

    test('inline markup survives the wrap', () {
      final out = applyDefaultMessageFont('[b]bold[/b] rest', 'cinzel');
      expect(out, '[font=cinzel][b]bold[/b] rest[/font]');
      final parsed = parseMarkup(out);
      expect(parsed.plainText, 'bold rest');
      expect(parsed.runs[0].format.bold, isTrue);
      expect(parsed.runs[0].format.fontFamily, 'cinzel');
      expect(parsed.runs[1].format.fontFamily, 'cinzel');
    });

    test('empty message stays empty', () {
      expect(applyDefaultMessageFont('', 'gothic'), '');
    });
  });
}
