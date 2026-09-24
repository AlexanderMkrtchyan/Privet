import 'package:flutter_test/flutter_test.dart';
import 'package:privet/util/video_clock.dart';

void main() {
  test('formatVideoClock uses mm:ss under an hour', () {
    expect(formatVideoClock(Duration.zero), '00:00');
    expect(formatVideoClock(const Duration(seconds: 9)), '00:09');
    expect(formatVideoClock(const Duration(minutes: 1, seconds: 4)), '01:04');
    expect(
      formatVideoClock(const Duration(minutes: 12, seconds: 3)),
      '12:03',
    );
  });

  test('formatVideoClock uses h:mm:ss from one hour', () {
    expect(formatVideoClock(const Duration(hours: 1)), '1:00:00');
    expect(
      formatVideoClock(const Duration(hours: 1, minutes: 2, seconds: 3)),
      '1:02:03',
    );
  });

  test('nextPrivetVideoSpeed cycles the offered rates', () {
    expect(nextPrivetVideoSpeed(1.0), 1.25);
    expect(nextPrivetVideoSpeed(2.0), 0.5);
    expect(nextPrivetVideoSpeed(0.9), 1.0);
  });
}
