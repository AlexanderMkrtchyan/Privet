import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:privet/util/mini_call_layout.dart';

void main() {
  test('phone screen keeps the desktop-sized bar inside the screen', () {
    // Reproduces the Android minimize crash: 360 < 480 made the old
    // clamp(8, -120) throw ArgumentError before the mini bar could build.
    final offset = miniCallDefaultOffset(
      const Size(360, 800),
      const Size(480, 120),
    );
    expect(offset.dx, 0.0);
    expect(offset.dy, 800 - 120 - 16);
  });

  test('desktop keeps the usual bottom-right inset', () {
    final offset = miniCallDefaultOffset(
      const Size(1920, 1080),
      const Size(480, 120),
    );
    expect(offset.dx, 1920 - 480 - 16);
    expect(offset.dy, 1080 - 120 - 16);
  });

  test('bar larger than the screen still yields a finite offset', () {
    final offset = miniCallDefaultOffset(
      const Size(280, 90),
      const Size(480, 120),
    );
    expect(offset.dx, 0.0);
    expect(offset.dy, 0.0);
  });
}
