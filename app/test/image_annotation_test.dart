import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet/widgets/image_annotation.dart';

void main() {
  final ink = kAnnotationInks.first;

  group('ImageMarkDraft pencil', () {
    test('adds points only beyond the 1.5px throttle', () {
      final draft = ImageMarkDraft(
        tool: ImageAnnotTool.pencil,
        start: const Offset(10, 10),
        color: ink,
        strokeWidth: 4,
      );
      // Within throttle: no new point, no repaint requested.
      expect(draft.update(const Offset(10.5, 10.5)), isFalse);
      expect(draft.points.length, 1);
      // Past throttle: point added, repaint requested.
      expect(draft.update(const Offset(12, 12)), isTrue);
      expect(draft.points.length, 2);
    });

    test('incremental path paints without throwing and matches points', () {
      final draft = ImageMarkDraft(
        tool: ImageAnnotTool.pencil,
        start: const Offset(0, 0),
        color: ink,
        strokeWidth: 4,
      );
      for (final p in const <Offset>[
        Offset(0, 0),
        Offset(5, 0),
        Offset(10, 5),
        Offset(15, 10),
        Offset(30, 10),
        Offset(45, 10),
        Offset(60, 20),
      ]) {
        draft.update(p);
      }
      final recorder = ui.PictureRecorder();
      draft.paint(Canvas(recorder));
      recorder.endRecording().dispose();

      final committed = draft.commit()! as FreehandMark;
      expect(committed.points.length, draft.points.length);
      expect(committed.color, ink);
    });

    test('tiny stroke does not commit', () {
      final draft = ImageMarkDraft(
        tool: ImageAnnotTool.pencil,
        start: const Offset(5, 5),
        color: ink,
        strokeWidth: 4,
      );
      expect(draft.update(const Offset(5.4, 5.4)), isFalse);
      expect(draft.commit(), isNull);
    });
  });

  group('ImageMarkDraft rect/arrow', () {
    test('updates end and commits', () {
      final draft = ImageMarkDraft(
        tool: ImageAnnotTool.arrow,
        start: const Offset(0, 0),
        color: ink,
        strokeWidth: 4,
      );
      expect(draft.update(const Offset(40, 40)), isTrue);
      final mark = draft.commit()!;
      expect(mark, isA<ArrowMark>());
      expect((mark as ArrowMark).b, const Offset(40, 40));
    });

    test('rect paints without throwing', () {
      final draft = ImageMarkDraft(
        tool: ImageAnnotTool.rect,
        start: const Offset(0, 0),
        color: ink,
        strokeWidth: 4,
      );
      draft.update(const Offset(50, 30));
      final recorder = ui.PictureRecorder();
      draft.paint(Canvas(recorder));
      recorder.endRecording().dispose();
      expect(draft.commit(), isA<RectMark>());
    });
  });

  group('ImageAnnotationPainter', () {
    test('paints committed marks directly without a cached picture', () {
      final marks = <ImageMark>[
        FreehandMark(
          points: const [Offset(0, 0), Offset(10, 10), Offset(20, 0)],
          color: ink,
          strokeWidth: 4,
        ),
      ];
      final recorder = ui.PictureRecorder();
      ImageAnnotationPainter(marks: marks)
          .paint(Canvas(recorder), const Size(100, 100));
      recorder.endRecording().dispose();
    });

    test('paints cached picture plus draft', () {
      final marks = <ImageMark>[
        ArrowMark(
          a: const Offset(1, 1),
          b: const Offset(30, 30),
          color: ink,
          strokeWidth: 4,
        ),
      ];
      final pictureRecorder = ui.PictureRecorder();
      for (final m in marks) {
        m.paint(Canvas(pictureRecorder));
      }
      final cached = pictureRecorder.endRecording();

      final draft = ImageMarkDraft(
        tool: ImageAnnotTool.pencil,
        start: const Offset(10, 10),
        color: ink,
        strokeWidth: 4,
      );
      draft.update(const Offset(20, 20));

      final recorder = ui.PictureRecorder();
      ImageAnnotationPainter(marks: marks, draft: draft, cachedPicture: cached)
          .paint(Canvas(recorder), const Size(100, 100));
      final picture = recorder.endRecording();
      picture.dispose();
      cached.dispose();
    });
  });
}
