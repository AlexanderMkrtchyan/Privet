import 'package:flutter_test/flutter_test.dart';
import 'package:privet/models.dart';
import 'package:privet/util/people_search.dart';

PrivetUser _u(String handle, String name) => PrivetUser(
      id: handle,
      handle: handle,
      displayName: name,
      avatarHue: 160,
    );

void main() {
  final directory = [
    _u('alice', 'Alice'),
    _u('linux', 'Linux user'),
    _u('linda', 'Linda'),
    _u('bob', 'Bob Linear'),
  ];

  test('partial handle finds people before full username', () {
    final hits = filterPeople(directory, 'lin');
    expect(hits.map((u) => u.handle).toList(), ['linda', 'linux', 'bob']);
  });

  test('exact handle ranks first', () {
    final hits = filterPeople(directory, 'linux');
    expect(hits.first.handle, 'linux');
  });

  test('@prefix and display-name word match', () {
    expect(filterPeople(directory, '@lin').map((u) => u.handle),
        ['linda', 'linux', 'bob']);
    expect(filterPeople(directory, 'user').single.handle, 'linux');
  });

  test('invite url detection', () {
    expect(looksLikeInviteUrl('https://messenger.banderdog.com/?invite=linux'),
        isTrue);
    expect(looksLikeInviteUrl('lin'), isFalse);
    expect(looksLikeInviteUrl('@linux'), isFalse);
  });
}
