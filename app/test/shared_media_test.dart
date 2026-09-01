import 'package:flutter_test/flutter_test.dart';
import 'package:privet/models.dart';
import 'package:privet/widgets/chat_media_folder.dart';

ChatMessage _msg({
  required String id,
  required String kind,
  String? mediaUrl,
  List<MediaAttachment>? attachments,
  DateTime? at,
  String senderName = 'Alex',
}) {
  return ChatMessage(
    id: id,
    conversationId: 'c1',
    body: '',
    kind: kind,
    createdAt: at ?? DateTime(2026, 8, 1),
    sender: PrivetUser(
      id: 'u1',
      handle: 'alex',
      displayName: senderName,
      avatarHue: 160,
    ),
    mediaUrl: mediaUrl,
    fileName: mediaUrl == null ? null : 'file',
    attachments: attachments ?? const [],
  );
}

TaskItem _task({
  required String id,
  required String kind,
  required String mediaUrl,
  DateTime? at,
}) {
  return TaskItem(
    id: id,
    conversationId: 'c1',
    body: 'task',
    status: 'todo',
    priority: 'medium',
    sortOrder: 0,
    createdAt: at ?? DateTime(2026, 8, 1),
    attachments: [
      MediaAttachment(mediaUrl: mediaUrl, kind: kind, fileName: 'file'),
    ],
  );
}

void main() {
  group('collectSharedMedia', () {
    test('includes media from chat messages', () {
      final messages = [
        _msg(id: 'm1', kind: 'image', mediaUrl: '/media/a.png'),
        _msg(id: 'm2', kind: 'file', mediaUrl: '/media/b.pdf'),
        _msg(id: 'm3', kind: 'text'),
      ];
      final photos = collectSharedMedia(
        messages,
        folder: ChatMediaFolderKind.photos,
      );
      expect(photos.map((e) => e.attachment.mediaUrl), ['/media/a.png']);
      final files = collectSharedMedia(
        messages,
        folder: ChatMediaFolderKind.files,
      );
      expect(files.map((e) => e.attachment.mediaUrl), ['/media/b.pdf']);
    });

    test('album attachments expand into individual items', () {
      final messages = [
        _msg(
          id: 'm1',
          kind: 'album',
          attachments: [
            MediaAttachment(mediaUrl: '/media/1.png', kind: 'image'),
            MediaAttachment(mediaUrl: '/media/2.png', kind: 'image'),
          ],
        ),
      ];
      final photos = collectSharedMedia(
        messages,
        folder: ChatMediaFolderKind.photos,
      );
      expect(photos.length, 2);
    });

    test('includes task attachments as source task', () {
      final items = collectSharedMedia(
        const [],
        folder: ChatMediaFolderKind.photos,
        tasks: [_task(id: 't1', kind: 'image', mediaUrl: '/media/t.png')],
      );
      expect(items.single.source, 'task');
      expect(items.single.attachment.mediaUrl, '/media/t.png');
    });

    test('newest first', () {
      final messages = [
        _msg(
          id: 'old',
          kind: 'image',
          mediaUrl: '/media/old.png',
          at: DateTime(2026, 1, 1),
        ),
        _msg(
          id: 'new',
          kind: 'image',
          mediaUrl: '/media/new.png',
          at: DateTime(2026, 2, 1),
        ),
      ];
      final photos = collectSharedMedia(
        messages,
        folder: ChatMediaFolderKind.photos,
      );
      expect(photos.first.attachment.mediaUrl, '/media/new.png');
    });
  });

  group('SharedMediaItem.fromJson', () {
    test('parses server payload', () {
      final item = SharedMediaItem.fromJson({
        'mediaUrl': '/media/a.png',
        'kind': 'image',
        'mimeType': 'image/png',
        'fileName': 'a.png',
        'fileSize': 1234,
        'createdAt': '2026-08-03 21:04:09',
        'senderName': 'Alex',
        'source': 'message',
        'messageId': 'm1',
      });
      expect(item.attachment.kind, 'image');
      expect(item.attachment.fileSize, 1234);
      expect(item.senderName, 'Alex');
      expect(item.messageId, 'm1');
    });
  });

  group('mergeSharedMedia', () {
    test('dedupes the same share from server and local view', () {
      final server = [
        SharedMediaItem.fromJson({
          'mediaUrl': '/media/a.png',
          'kind': 'image',
          'createdAt': '2026-08-03 21:04:09',
          'senderName': 'Alex',
          'messageId': 'm1',
        }),
      ];
      final local = collectSharedMedia(
        [_msg(id: 'm1', kind: 'image', mediaUrl: '/media/a.png')],
        folder: ChatMediaFolderKind.photos,
      );
      final merged = mergeSharedMedia(server, local);
      expect(merged.length, 1);
    });

    test('keeps distinct shares of the same file in different messages', () {
      final server = [
        SharedMediaItem.fromJson({
          'mediaUrl': '/media/a.png',
          'kind': 'image',
          'createdAt': '2026-08-03 21:04:09',
          'senderName': 'Alex',
          'messageId': 'm1',
        }),
        SharedMediaItem.fromJson({
          'mediaUrl': '/media/a.png',
          'kind': 'image',
          'createdAt': '2026-08-04 21:04:09',
          'senderName': 'Alex',
          'messageId': 'm2',
        }),
      ];
      expect(mergeSharedMedia(server, const []).length, 2);
    });
  });

  group('filterSharedMedia', () {
    test('routes photos and files to the right tabs', () {
      final items = [
        SharedMediaItem.fromJson({
          'mediaUrl': '/media/a.png',
          'kind': 'image',
          'createdAt': '2026-08-03 21:04:09',
        }),
        SharedMediaItem.fromJson({
          'mediaUrl': '/media/b.mp4',
          'kind': 'video',
          'createdAt': '2026-08-03 21:04:09',
        }),
      ];
      final photos = filterSharedMedia(items, ChatMediaFolderKind.photos);
      expect(photos.map((e) => e.attachment.kind), ['image']);
      final files = filterSharedMedia(items, ChatMediaFolderKind.files);
      expect(files.map((e) => e.attachment.kind), ['video']);
    });
  });
}
