import 'package:flutter_test/flutter_test.dart';
import 'package:privet/util/perf.dart';
import 'package:privet/util/throttle.dart';

void main() {
  group('Throttle', () {
    test('leading call runs immediately; bursts coalesce', () async {
      var count = 0;
      final throttle = Throttle(const Duration(milliseconds: 50));
      throttle(() => count++);
      throttle(() => count++);
      throttle(() => count++);
      expect(count, 1);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(count, 2);
      throttle.cancel();
    });

    test('reset allows an immediate leading call again', () {
      var count = 0;
      final throttle = Throttle(const Duration(seconds: 5));
      throttle(() => count++);
      throttle(() => count++);
      expect(count, 1);
      throttle.reset();
      throttle(() => count++);
      expect(count, 2);
      throttle.cancel();
    });
  });

  group('Debouncer', () {
    test('trailing-only fires once after quiet period', () async {
      var count = 0;
      final debouncer = Debouncer(const Duration(milliseconds: 40));
      debouncer(() => count++);
      debouncer(() => count++);
      debouncer(() => count++);
      expect(count, 0);
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(count, 1);
      debouncer.cancel();
    });

    test('flush runs pending action immediately', () {
      var count = 0;
      final debouncer = Debouncer(const Duration(seconds: 5));
      debouncer(() => count++);
      expect(debouncer.isArmed, isTrue);
      debouncer.flush(() => count++);
      expect(count, 1);
      expect(debouncer.isArmed, isFalse);
    });
  });

  group('ImageDecodeCaps', () {
    test('clamps decode size to display * dpr', () {
      expect(ImageDecodeCaps.cacheWidth(260, dpr: 2), 520);
      expect(ImageDecodeCaps.cacheHeight(160, dpr: 1), 160);
      expect(ImageDecodeCaps.cacheWidth(10, dpr: 1), 32);
      expect(ImageDecodeCaps.cacheWidth(4000, dpr: 3), 1280);
    });
  });
}
