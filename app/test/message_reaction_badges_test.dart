import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet/models.dart';
import 'package:privet/widgets/accent_chrome.dart';
import 'package:privet/widgets/message_bubble.dart';

ChatMessage _msg({
  required String id,
  required String body,
  List<MessageReaction> reactions = const [],
}) {
  return ChatMessage(
    id: id,
    conversationId: 'c1',
    body: body,
    kind: 'text',
    createdAt: DateTime(2026, 9, 24, 15, 30),
    sender: PrivetUser(
      id: 'u1',
      handle: 'alex',
      displayName: 'Alex',
      avatarHue: 160,
    ),
    reactions: reactions,
  );
}

void main() {
  testWidgets('reaction sits on its bubble, not in the gap before the next',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MessageBubble(
                key: const Key('reacted'),
                message: _msg(
                  id: 'm1',
                  body: 'Hello',
                  reactions: [
                    MessageReaction(
                      emoji: '❤️',
                      count: 1,
                      userIds: const ['u2'],
                    ),
                  ],
                ),
                mine: false,
                mediaBase: '',
                selfId: 'u1',
              ),
              MessageBubble(
                key: const Key('followup'),
                message: _msg(id: 'm2', body: 'Later'),
                mine: false,
                mediaBase: '',
                selfId: 'u1',
              ),
            ],
          ),
        ),
      ),
    );

    final reaction = tester.getRect(find.byKey(const ValueKey('reaction-❤️')));
    final firstChrome = tester.getRect(
      find.descendant(
        of: find.byKey(const Key('reacted')),
        matching: find.byType(AccentChromeFrame),
      ),
    );
    final second = tester.getRect(find.byKey(const Key('followup')));

    expect(reaction.bottom, greaterThan(firstChrome.top),
        reason: 'badge must overlap the top of its bubble');
    expect(reaction.top, lessThan(firstChrome.top + 8),
        reason: 'badge must sit on the top edge, not drop into the body');
    expect((reaction.left - firstChrome.left).abs(), lessThan(16),
        reason: 'incoming and outgoing badges sit on the top-left');
    expect(reaction.right, lessThan(firstChrome.right - 16),
        reason: 'badge must stay off the timestamp on the right');
    expect(reaction.bottom, lessThan(second.top),
        reason: 'badge must stay above the following message');
    expect(
      (reaction.center.dy - firstChrome.center.dy).abs(),
      lessThan((reaction.center.dy - second.center.dy).abs()),
      reason: 'badge is closer to its own message than the next one',
    );
  });

  testWidgets('reaction count is shown when more than one person reacted',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: _msg(
              id: 'm1',
              body: 'Hello',
              reactions: [
                MessageReaction(
                  emoji: '👍',
                  count: 3,
                  userIds: const ['u2', 'u3', 'u4'],
                ),
              ],
            ),
            mine: true,
            mediaBase: '',
            selfId: 'u1',
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('reaction-👍')), findsOneWidget);
    expect(find.text('3'), findsOneWidget);

    final reaction = tester.getRect(find.byKey(const ValueKey('reaction-👍')));
    final chrome = tester.getRect(find.byType(AccentChromeFrame));
    expect((reaction.left - chrome.left).abs(), lessThan(16),
        reason: 'outgoing reactions also sit on the top-left');
  });
}
