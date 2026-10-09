import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet/util/html_clipboard_markup.dart';
import 'package:privet/util/rich_text_markup.dart';

void main() {
  group('htmlToMarkup', () {
    test('bold and italic', () {
      final p = htmlToMarkup('<b>bold</b> and <i>italic</i>');
      expect(p.plainText, 'bold and italic');
      expect(p.runs, hasLength(2));
      expect(p.runs[0].format.bold, isTrue);
      expect(p.runs[0].plainSlice(p.plainText), 'bold');
      expect(p.runs[1].format.italic, isTrue);
      expect(p.runs[1].plainSlice(p.plainText), 'italic');
    });

    test('inline color from style', () {
      final p = htmlToMarkup(
        '<span style="color: #0000ff">blue</span> plain',
      );
      expect(p.plainText, 'blue plain');
      expect(p.runs.single.format.background, const Color(0xFF0000FF));
      expect(p.runs.single.plainSlice(p.plainText), 'blue');
    });

    test('rgb() color', () {
      final p = htmlToMarkup(
        '<span style="color: rgb(255, 0, 0)">red</span>',
      );
      expect(p.runs.single.format.background, const Color(0xFFFF0000));
    });

    test('unordered list becomes bullets with space indent for nesting', () {
      final p = htmlToMarkup(
        '<ul><li>one</li><li>two<ul><li>nested</li></ul></li></ul>',
      );
      expect(p.plainText, '• one\n• two\n  • nested');
    });

    test('ordered list uses numbers', () {
      final p = htmlToMarkup('<ol><li>a</li><li>b</li></ol>');
      expect(p.plainText, '1. a\n2. b');
    });

    test('preserves tabs inside pre', () {
      final p = htmlToMarkup('<pre>a\tb</pre>');
      expect(p.plainText, 'a\tb');
      expect(p.runs.single.format.fontFamily, 'monospace');
    });

    test('preserves leading indent inside colored spans', () {
      // Cursor / IDE style: indent lives in the visible text node, while
      // pretty-print whitespace between tags must be ignored.
      final p = htmlToMarkup(
        '<div>\n  <span style="color:#0000ff">    hello</span>\n</div>',
      );
      expect(p.plainText, '    hello');
    });

    test('preserves literal tabs in visible text', () {
      final p = htmlToMarkup('<span>col1\tcol2\tcol3</span>');
      expect(p.plainText, 'col1\tcol2\tcol3');
    });

    test('table becomes TSV with tabs between cells', () {
      final p = htmlToMarkup('''
        <table>
          <tr><th>Name</th><th>Age</th></tr>
          <tr><td>Ann</td><td>3</td></tr>
          <tr><td>Bob</td><td>4</td></tr>
        </table>
      ''');
      expect(p.plainText, 'Name\tAge\nAnn\t3\nBob\t4');
    });

    test('table cells with inner paragraphs stay on one row', () {
      final p = htmlToMarkup('''
        <table>
          <tr>
            <td><p>A</p><p>line</p></td>
            <td><div>B</div></td>
          </tr>
        </table>
      ''');
      expect(p.plainText, 'A line\tB');
      expect(p.plainText.contains('\n'), isFalse);
    });

    test('table with thead/tbody', () {
      final p = htmlToMarkup('''
        <table>
          <thead><tr><td>H1</td><td>H2</td></tr></thead>
          <tbody><tr><td>1</td><td>2</td></tr></tbody>
        </table>
      ''');
      expect(p.plainText, 'H1\tH2\n1\t2');
    });

    test('margin-left becomes leading tabs', () {
      final p = htmlToMarkup(
        '<p style="margin-left: 80px">indented</p>',
      );
      expect(p.plainText, '\t\tindented');
    });

    test('font color attribute', () {
      final p = htmlToMarkup('<font color="green">go</font>');
      expect(p.runs.single.format.background, const Color(0xFF008000));
    });

    test('CF_HTML fragment markers', () {
      const fragment = '<b>hi</b>';
      final start = 'Version:0.9\nStartHTML:0000000000\nEndHTML:0000000000\n'
              'StartFragment:0000000000\nEndFragment:0000000000\n'
          .length;
      final end = start + fragment.length;
      final raw =
          'Version:0.9\nStartHTML:0000000000\nEndHTML:0000000000\n'
          'StartFragment:${start.toString().padLeft(10, '0')}\n'
          'EndFragment:${end.toString().padLeft(10, '0')}\n'
          '$fragment';
      expect(raw.substring(start, end), fragment);
      final p = htmlToMarkup(raw);
      expect(p.plainText, 'hi');
      expect(p.runs.single.format.bold, isTrue);
    });

    test('body fallback when fragment offsets are wrong', () {
      const raw = '''
Version:0.9
StartFragment:0000009999
EndFragment:0000010000
<html><body><i>yo</i></body></html>
''';
      final p = htmlToMarkup(raw);
      expect(p.plainText, 'yo');
      expect(p.runs.single.format.italic, isTrue);
    });

    test('round-trips through serializeMarkup', () {
      final p = htmlToMarkup(
        '<b><span style="color:#3B82F6">Azure</span></b>',
      );
      final markup = serializeMarkup(p.plainText, p.runs);
      final again = parseMarkup(markup);
      expect(again.plainText, 'Azure');
      expect(again.runs.single.format.bold, isTrue);
      expect(again.runs.single.format.background, const Color(0xFF3B82F6));
    });
  });

  group('htmlClipboardLooksRich', () {
    test('detects color and lists and tables', () {
      expect(htmlClipboardLooksRich('<span style="color:blue">x</span>'), isTrue);
      expect(htmlClipboardLooksRich('<ul><li>a</li></ul>'), isTrue);
      expect(htmlClipboardLooksRich('<table><tr><td>a</td></tr></table>'), isTrue);
      expect(htmlClipboardLooksRich('<p>just text</p>'), isFalse);
    });
  });

  group('htmlSelectionWasDoubled', () {
    test('detects the selection serialized twice', () {
      expect(htmlSelectionWasDoubled('hello', 'hellohello'), isTrue);
      expect(htmlSelectionWasDoubled('hello', 'hello\nhello'), isTrue);
      expect(htmlSelectionWasDoubled('hello', 'hello hello'), isTrue);
      expect(htmlSelectionWasDoubled('hello', 'hello'), isFalse);
      expect(htmlSelectionWasDoubled('hellohello', 'hellohello'), isFalse);
      expect(htmlSelectionWasDoubled('Hello\nHello', 'Hello\nHello'), isFalse);
    });
  });

  group('hidden clipboard nodes', () {
    test('skips display:none duplicates', () {
      final p = htmlToMarkup(
        '<span>hello</span><span style="display:none">hello</span>',
      );
      expect(p.plainText, 'hello');
    });
  });

  group('plainTextLooksMoreStructured', () {
    test('prefers plain when it keeps more tabs', () {
      expect(
        plainTextLooksMoreStructured('a\tb\tc\nd\te\tf', 'a b c d e f'),
        isTrue,
      );
      expect(
        plainTextLooksMoreStructured('hello', 'hello'),
        isFalse,
      );
    });
  });
}

extension on FormatRun {
  String plainSlice(String plain) => plain.substring(start, end);
}
