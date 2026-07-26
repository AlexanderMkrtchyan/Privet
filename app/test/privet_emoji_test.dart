import 'package:animated_emoji/animated_emoji.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet/widgets/privet_emoji.dart';

void main() {
  testWidgets('PrivetEmoji uses static glyph below threshold', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: PrivetEmoji('❤️', size: 16))),
      ),
    );

    expect(find.byType(Text), findsOneWidget);
    expect(find.text('❤️'), findsOneWidget);
    expect(find.byType(AnimatedEmoji), findsNothing);
  });

  testWidgets('PrivetEmoji skips empty strings', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: PrivetEmoji('   ', size: 16))),
      ),
    );

    expect(find.byType(Text), findsNothing);
    expect(find.byType(SizedBox), findsWidgets);
  });

  test('static glyph threshold skips reaction-size Lottie', () {
    expect(PrivetEmoji.staticGlyphThreshold, 28);
    expect(16 < PrivetEmoji.staticGlyphThreshold, isTrue);
    expect(26 < PrivetEmoji.staticGlyphThreshold, isTrue);
  });

  testWidgets('low-resource mode forces static glyphs', (tester) async {
    privetLowResourceEmoji = true;
    addTearDown(() => privetLowResourceEmoji = false);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: PrivetEmoji('😂', size: 48))),
      ),
    );
    expect(find.byType(Text), findsOneWidget);
    expect(find.byType(AnimatedEmoji), findsNothing);
  });

  test('defaults keep emoji animation one-shot', () {
    const emoji = PrivetEmoji('👍');
    expect(emoji.repeat, isFalse);
    expect(emoji.animate, isTrue);
  });
}
