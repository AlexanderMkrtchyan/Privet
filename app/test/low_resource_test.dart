import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet/util/low_resource.dart';
import 'package:privet/util/perf.dart';

void main() {
  tearDown(() {
    setPrivetLowResource(false);
    LowResourceAutoDetect.cancel();
  });

  test('privetAnim collapses to zero when low-resource is on', () {
    expect(
      privetAnim(const Duration(milliseconds: 180)),
      const Duration(milliseconds: 180),
    );
    setPrivetLowResource(true);
    expect(privetAnim(const Duration(milliseconds: 180)), Duration.zero);
  });

  test('privetElevation flattens shadows when low-resource is on', () {
    expect(privetElevation(8), 8);
    setPrivetLowResource(true);
    expect(privetElevation(8), 0);
  });

  test('image decode caps tighten under low-resource', () {
    expect(ImageDecodeCaps.cacheWidth(2000, dpr: 1), 1280);
    setPrivetLowResource(true);
    expect(ImageDecodeCaps.cacheWidth(2000, dpr: 1), 640);
  });

  test('emoji alias tracks privetLowResource', () {
    privetLowResourceEmoji = true;
    expect(privetLowResource, isTrue);
    expect(privetLowResourceListenable.value, isTrue);
    privetLowResourceEmoji = false;
    expect(privetLowResource, isFalse);
    expect(privetLowResourceListenable.value, isFalse);
  });

  test('page transitions theme is instant when low-resource', () {
    final low = privetPageTransitionsTheme(lowResource: true);
    expect(
      low.builders[TargetPlatform.linux],
      isA<PrivetInstantPageTransitionsBuilder>(),
    );
    expect(
      low.builders[TargetPlatform.windows],
      isA<PrivetInstantPageTransitionsBuilder>(),
    );
  });
}
