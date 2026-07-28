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
  });
}
