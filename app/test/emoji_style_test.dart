import 'package:flutter_test/flutter_test.dart';
import 'package:privet/util/emoji_style.dart';
import 'package:privet/util/kolobok_smileys.dart';
import 'package:privet/widgets/message_bubble.dart';

void main() {
  test('markGoogleEmoji is idempotent and strips for display', () {
    expect(markGoogleEmoji('👍'), '👍$kGoogleEmojiMark');
    expect(markGoogleEmoji(markGoogleEmoji('👍')), '👍$kGoogleEmojiMark');
    expect(displayEmoji(markGoogleEmoji('👍')), '👍');
    expect(isGoogleEmojiStyle(markGoogleEmoji('😂')), isTrue);
    expect(isGoogleEmojiStyle('😂'), isFalse);
  });

  test('popup keeps Kolobok shortcuts and a separate Google like', () {
    expect(kQuickReactions, ['❤️', '👍', '😮']);
    expect(kQuickGoogleLike, '👍$kGoogleEmojiMark');
    expect(kQuickReactions.contains('😂'), isFalse);
    expect(kolobokFileForEmoji(kQuickReactions[1]), isNotNull);
    expect(isGoogleEmojiStyle(kQuickGoogleLike), isTrue);
    expect(kQuickReactions.every(isGoogleEmojiStyle), isFalse);
  });
}
