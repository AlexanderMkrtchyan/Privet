import 'package:flutter_test/flutter_test.dart';
import 'package:privet/state.dart';
import 'package:privet/util/page_uri.dart';

void main() {
  test('httpOrigin returns null for file:// (Linux desktop Uri.base)', () {
    expect(httpOrigin(Uri.parse('file:///home/alex/Apps/privet/')), isNull);
    expect(httpOrigin(Uri.parse('file:///tmp/privet')), isNull);
  });

  test('httpOrigin returns origin for http(s)', () {
    expect(
      httpOrigin(Uri.parse('https://messenger.banderdog.com/app/?invite=alex')),
      'https://messenger.banderdog.com',
    );
    expect(
      httpOrigin(Uri.parse('http://127.0.0.1:7777/app/?invite=bob')),
      'http://127.0.0.1:7777',
    );
  });

  test('parseInviteHandle accepts /app/?invite= links', () {
    expect(
      PrivetState.parseInviteHandle(
        'https://messenger.banderdog.com/app/?invite=alex',
      ),
      'alex',
    );
  });
}
