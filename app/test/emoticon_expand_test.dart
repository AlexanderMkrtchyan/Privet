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
}
