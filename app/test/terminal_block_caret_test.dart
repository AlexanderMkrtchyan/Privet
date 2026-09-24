import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet/widgets/terminal_block_caret.dart';

void main() {
  group('composerOverlayFieldClip', () {
    test('keeps the visible field inside the overlay', () {
      final clip = composerOverlayFieldClip(
        fieldOrigin: const Offset(8, 12),
        fieldSize: const Size(200, 80),
        paintSize: const Size(220, 100),
      );
      expect(clip, const Rect.fromLTWH(8, 12, 200, 80));
    });

    test('clips a caret that has scrolled above the field', () {
      final clip = composerOverlayFieldClip(
        fieldOrigin: const Offset(0, -40),
        fieldSize: const Size(200, 80),
        paintSize: const Size(200, 80),
      );
      expect(clip, const Rect.fromLTWH(0, 0, 200, 40));
    });

    test('clips a caret that has scrolled below the field', () {
      final clip = composerOverlayFieldClip(
        fieldOrigin: const Offset(0, 40),
        fieldSize: const Size(200, 80),
        paintSize: const Size(200, 80),
      );
      expect(clip, const Rect.fromLTWH(0, 40, 200, 40));
    });

    test('returns null when the field is fully outside the overlay', () {
      expect(
        composerOverlayFieldClip(
          fieldOrigin: const Offset(0, -200),
          fieldSize: const Size(200, 80),
          paintSize: const Size(200, 80),
        ),
        isNull,
      );
      expect(
        composerOverlayFieldClip(
          fieldOrigin: const Offset(0, 200),
          fieldSize: const Size(200, 80),
          paintSize: const Size(200, 80),
        ),
        isNull,
      );
    });
  });

  group('composerKolobokOverlayClip', () {
    test('keeps the editable horizontal inset and uses the full field height',
        () {
      final clip = composerKolobokOverlayClip(
        fieldOrigin: const Offset(8, 12),
        fieldSize: const Size(200, 24),
        paintSize: const Size(220, 48),
      );
      expect(clip, const Rect.fromLTWH(8, 0, 200, 48));
    });

    test('still returns null when the editable is fully outside', () {
      expect(
        composerKolobokOverlayClip(
          fieldOrigin: const Offset(0, -200),
          fieldSize: const Size(200, 24),
          paintSize: const Size(200, 48),
        ),
        isNull,
      );
    });
  });

  testWidgets('does not visit the field during build', (tester) async {
    final fieldKey = GlobalKey();
    final focus = FocusNode();
    final controller = TextEditingController(
      text: List.generate(12, (i) => 'line $i of a long draft').join('\n'),
    );
    controller.selection = TextSelection.collapsed(
      offset: controller.text.length,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 240,
            child: Stack(
              children: [
                TextField(
                  key: fieldKey,
                  controller: controller,
                  focusNode: focus,
                  showCursor: false,
                  minLines: 2,
                  maxLines: 2,
                ),
                Positioned.fill(
                  child: TerminalBlockCaret(
                    fieldKey: fieldKey,
                    focusNode: focus,
                    controller: controller,
                    height: 16,
                    width: 8,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    focus.requestFocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);

    controller.selection = const TextSelection.collapsed(offset: 0);
    await tester.pump();
    expect(tester.takeException(), isNull);

    focus.dispose();
    controller.dispose();
  });
}
