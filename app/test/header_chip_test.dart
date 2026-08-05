import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:privet/models.dart';
import 'package:privet/theme.dart';
import 'package:privet/widgets/chat_task_pane.dart';

TaskItem _task({String id = 't1', String body = 'Fix roof', bool pinned = true}) =>
    TaskItem(
      id: id,
      conversationId: 'c1',
      body: body,
      done: false,
      doneConfirmed: false,
      sortOrder: 0,
      createdAt: DateTime(2026, 1, 1),
      pinned: pinned,
    );

PaymentReminder _payment({int? cents = 123456}) => PaymentReminder(
      id: 'p1',
      conversationId: 'c1',
      kind: 'payment',
      currency: 'USD',
      direction: 'owe',
      dueDate: '2026-08-20',
      paid: false,
      createdAt: DateTime(2026, 1, 1),
      amountCents: cents,
    );

/// Mirrors the standard header button construction (Material → Ink → InkWell →
/// SizedBox) so the chip height can be compared against a real "other button".
class _ReferenceButton extends StatelessWidget {
  const _ReferenceButton();
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: BoxDecoration(
          color: PrivetTheme.panelElevated,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: PrivetTheme.line),
        ),
        child: InkWell(
          onTap: () {},
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            height: kChatHeaderChipHeight,
            width: kChatHeaderChipHeight,
          ),
        ),
      ),
    );
  }
}

void main() {
  testWidgets('pinned reminder and task chips match the standard button height',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: Row(children: [
            ReminderHeaderChip(reminder: _payment(), onTap: () {}),
            TaskHeaderChip(
              board: ConversationTasks(items: [_task()]),
              active: false,
              onTap: () {},
            ),
            const _ReferenceButton(),
          ]),
        ),
      ),
    ));

    final buttonHeight = tester.getSize(find.byType(_ReferenceButton)).height;
    expect(
      tester.getSize(find.byType(ReminderHeaderChip)).height,
      buttonHeight,
      reason: 'reminder chip must be as tall as the other header buttons',
    );
    expect(
      tester.getSize(find.byType(TaskHeaderChip)).height,
      buttonHeight,
      reason: 'task chip must be as tall as the other header buttons',
    );
  });

  test('compact money amount stays within 4 digits', () {
    final cases = <int, String>{
      50: r'$0.50', // 0.50
      5000: r'$50', // 50
      9999: r'$99.99', // 99.99
      12345: r'$123', // 123.45
      999999: r'$9999', // 9999.99
      1000000: r'$10k', // 10000.00
      1234567: r'$12.3k', // 12345.67
      123456789: r'$1.2M', // 1234567.89
    };
    for (final e in cases.entries) {
      expect(
        _payment(cents: e.key).compactAmount,
        e.value,
        reason: '${e.key} cents -> ${e.value}',
      );
    }
  });

  testWidgets('money reminder chip renders the compact amount', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ReminderHeaderChip(
          reminder: _payment(cents: 1234567),
          onTap: () {},
        ),
      ),
    ));

    expect(find.text(r'$12.3k'), findsOneWidget);
  });

  testWidgets(
      'pinned chips hide the pin icon and reveal a close button on hover',
      (tester) async {
    var unpinned = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Row(
          children: [
            ReminderHeaderChip(
              reminder: _payment(),
              onTap: () {},
              onUnpin: () => unpinned++,
            ),
            TaskHeaderChip(
              board: ConversationTasks(items: [_task()]),
              active: false,
              onTap: () {},
              onUnpin: () => unpinned++,
            ),
          ],
        ),
      ),
    ));

    expect(find.byIcon(Icons.push_pin_rounded), findsNothing,
        reason: 'header chips must no longer show the pin icon');
    expect(find.byIcon(Icons.close_rounded), findsNothing,
        reason: 'close button only appears while hovering');

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.moveTo(
      tester.getCenter(find.byType(ReminderHeaderChip).first),
    );
    await tester.pump();
    expect(find.byIcon(Icons.close_rounded), findsOneWidget,
        reason: 'hovering a pinned chip reveals the close button');

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();
    expect(unpinned, 1, reason: 'tapping the close button unpins');

    await gesture.moveTo(tester.getCenter(find.byType(TaskHeaderChip).first));
    await tester.pump();
    expect(find.byIcon(Icons.close_rounded), findsOneWidget,
        reason: 'task chip also reveals the close button on hover');
  });
}
