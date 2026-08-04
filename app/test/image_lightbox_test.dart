import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet/util/clipboard_files.dart';
import 'package:privet/util/composer_media_attach.dart';
import 'package:privet/widgets/image_lightbox.dart';

void main() {
  testWidgets('lightbox: draw pencil stroke and export annotated PNG',
      (tester) async {
    // The test HttpClient returns 400, so Image.network falls to its
    // errorBuilder — the lightbox still has a sizeable, capturable area.
    PickedBytes? staged;
    final attachId = registerComposerMediaAttach((file) => staged = file);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showImageLightbox(
                  context,
                  urls: const ['https://example.test/photo.png'],
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    // Enter annotate mode via the view-toolbar draw button.
    await tester.tap(find.byTooltip('Annotate'));
    await tester.pumpAndSettle();

    // Draw a pencil stroke across the centered image area.
    final gesture = await tester.startGesture(const Offset(360, 280));
    for (var i = 0; i < 12; i++) {
      await gesture.moveBy(const Offset(6, 4));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    // A committed mark enables the export button.
    expect(find.text('Add to message'), findsOneWidget);

    await tester.tap(find.text('Add to message'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // Boundary toImage + PNG encode complete on the real event loop.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 600)),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(staged, isNotNull);
    expect(staged!.mimeType, 'image/png');
    expect(staged!.bytes.length, greaterThan(100));
    expect(staged!.filename, contains('_annotated.png'));

    unregisterComposerMediaAttach(attachId);
  });

  testWidgets(
      'lightbox: annotate-mode hover tracks the pointer without errors '
      '(crosshair overlay absorbs per-pixel moves)', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showImageLightbox(
                  context,
                  urls: const ['https://example.test/photo.png'],
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    await tester.tap(find.byTooltip('Annotate'));
    await tester.pumpAndSettle();

    // Chrome fires a hover for every pixel during a drag; these moves must be
    // absorbed by the cursor overlay without errors, relayout or crashes.
    final hover = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await hover.addPointer(location: Offset.zero);
    addTearDown(hover.removePointer);
    await tester.pump();

    for (var i = 0; i < 8; i++) {
      await hover.moveTo(Offset(120.0 + i * 40, 240.0 + i * 20));
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(tester.takeException(), isNull);
    expect(find.byTooltip('Done'), findsOneWidget);

    // A stroke still draws after all the hover traffic.
    final gesture = await tester.startGesture(const Offset(360, 280));
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(8, 5));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('Add to message'), findsOneWidget);
  });
}
