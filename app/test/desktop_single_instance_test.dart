import 'package:flutter_test/flutter_test.dart';
import 'package:privet/util/desktop_single_instance_io.dart';

void main() {
  test('raise payload carries an activation token on its own line', () {
    expect(raisePayload(), 'raise');
    expect(raisePayload(activationToken: '  '), 'raise');
    expect(
      raisePayload(activationToken: 'gtk-privet-1_TIME0'),
      'raise\ngtk-privet-1_TIME0',
    );
  });

  test('activation token is read back from a raise payload', () {
    expect(activationTokenFromRaisePayload('raise'), isNull);
    expect(activationTokenFromRaisePayload('raise\n'), isNull);
    expect(
      activationTokenFromRaisePayload('raise\ngtk-privet-1_TIME0\n'),
      'gtk-privet-1_TIME0',
    );
    expect(activationTokenFromRaisePayload('nope'), isNull);
    expect(
      activationTokenFromRaisePayload('raise\n${'x' * 513}'),
      isNull,
    );
  });
}
