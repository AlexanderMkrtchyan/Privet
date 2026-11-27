import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet/models.dart';
import 'package:privet/widgets/message_bubble.dart';

PrivetUser _sender() => PrivetUser(
  id: 'u1',
  handle: 'alex',
  displayName: 'Alex',
  avatarHue: 160,
);

ChatMessage _audioMessage({
  required String id,
  required String kind,
  required List<MediaAttachment> attachments,
}) {
  return ChatMessage(
    id: id,
    conversationId: 'c1',
    body: '',
    kind: kind,
    createdAt: DateTime(2026, 11, 27, 18, 30),
    sender: _sender(),
    attachments: attachments,
  );
}

Widget _wrap(ChatMessage message) {
  return MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: MessageBubble(
          message: message,
          mine: false,
          mediaBase: 'https://example.test',
          selfId: 'u1',
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a single sound gets a play bar with seek track', (tester) async {
    await tester.pumpWidget(
      _wrap(
        _audioMessage(
          id: 'm1',
          kind: 'audio',
          attachments: [
            MediaAttachment(
              mediaUrl: '/media/clip-1.webm',
              kind: 'audio',
              fileName: 'clip-1.webm',
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(VoicePlayer), findsOneWidget);
    expect(find.byType(SoundWaveTrack), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_filled_rounded), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sounds sent together get play + download but no bar',
      (tester) async {
    await tester.pumpWidget(
      _wrap(
        _audioMessage(
          id: 'm2',
          kind: 'album',
          attachments: [
            MediaAttachment(
              mediaUrl: '/media/clip-2.webm',
              kind: 'audio',
              fileName: 'clip-2.webm',
            ),
            MediaAttachment(
              mediaUrl: '/media/clip-3.webm',
              kind: 'audio',
              fileName: 'clip-3.webm',
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    // The bar is reserved for a sound sent on its own.
    expect(find.byType(VoicePlayer), findsNothing);
    expect(find.byType(SoundWaveTrack), findsNothing);
    expect(find.byIcon(Icons.play_circle_filled_rounded), findsNWidgets(2));
    expect(find.text('Download'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
