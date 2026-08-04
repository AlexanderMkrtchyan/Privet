import 'package:flutter_test/flutter_test.dart';
import 'package:privet/util/emoticon_expand.dart';

void main() {
  test('expands western and parenthetical emoticons', () {
    expect(expandEmoticons(':D'), '😃');
    expect(expandEmoticons('(sob)'), '😭');
    expect(expandEmoticons('hi :D (sob)'), 'hi 😃 😭');
    expect(expandEmoticons(':-)'), '🙂');
    expect(expandEmoticons('(SOB)'), '😭');
    expect(expandEmoticons('<3'), '❤️');
  });

  test('does not break URLs', () {
    expect(
      expandEmoticons('see https://example.com and :/'),
      'see https://example.com and 😕',
    );
  });

  test('leaves plain text alone', () {
    expect(expandEmoticons('hello world'), 'hello world');
    expect(expandEmoticons(''), '');
  });

  group('tryExpandEmoticonAtCursor', () {
    test('expands western faces at caret', () {
      expect(tryExpandEmoticonAtCursor(':)', 2)?.emoji, '🙂');
      expect(tryExpandEmoticonAtCursor(':(', 2)?.emoji, '😞');
      expect(tryExpandEmoticonAtCursor('hi :)', 5)?.emoji, '🙂');
      expect(tryExpandEmoticonAtCursor(':-)', 3)?.emoji, '🙂');
      expect(tryExpandEmoticonAtCursor(':D', 2)?.emoji, '😃');
    });

    test('expands parenthetical codes when ) closes token', () {
      expect(tryExpandEmoticonAtCursor('(sob)', 5)?.emoji, '😭');
      expect(tryExpandEmoticonAtCursor('(SOB)', 5)?.emoji, '😭');
    });

    test('does not expand partial tokens', () {
      expect(tryExpandEmoticonAtCursor(':', 1), isNull);
      expect(tryExpandEmoticonAtCursor(':-', 2), isNull);
      expect(tryExpandEmoticonAtCursor('(sm', 3), isNull);
    });

    test('does not expand into words or URLs', () {
      expect(tryExpandEmoticonAtCursor(':Debug', 2), isNull);
      expect(tryExpandEmoticonAtCursor('http:/', 6), isNull);
      expect(tryExpandEmoticonAtCursor('http://', 7), isNull);
      expect(tryExpandEmoticonAtCursor(':/', 2), isNull);
    });

    test('does not turn a time like 11:3 into :3', () {
      expect(tryExpandEmoticonAtCursor('11:3', 4), isNull);
      expect(tryExpandEmoticonAtCursor('11:34', 4), isNull);
      expect(tryExpandEmoticonAtCursor('09:3', 4), isNull);
      // Deliberate :3 still expands (space before it).
      expect(tryExpandEmoticonAtCursor('hey :3', 6)?.emoji, '😊');
      expect(tryExpandEmoticonAtCursor(':3', 2)?.emoji, '😊');
    });

    test('does not expand time on send', () {
      expect(expandEmoticons('11:34'), '11:34');
      expect(expandEmoticons('at 12:30 sharp'), 'at 12:30 sharp');
      expect(expandEmoticons('9:3'), '9:3');
      // Deliberate emoticons still expand on send.
      expect(expandEmoticons('hey :D'), 'hey 😃');
      expect(expandEmoticons('hi :)'), 'hi 🙂');
      expect(expandEmoticons('ok :3'), 'ok 😊');
      expect(expandEmoticons(':3'), '😊');
    });
  });
}
