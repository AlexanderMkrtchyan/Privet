class PrivetUser {
  PrivetUser({
    required this.id,
    required this.handle,
    required this.displayName,
    required this.avatarHue,
    this.avatarUrl,
    this.lastSeenAt,
    this.online = false,
    this.lastReadAt,
  });

  final String id;
  final String handle;
  final String displayName;
  final int avatarHue;
  final String? avatarUrl;
  final DateTime? lastSeenAt;
  final bool online;
  final DateTime? lastReadAt;

  factory PrivetUser.fromJson(Map<String, dynamic> json) {
    DateTime? parseTs(dynamic v) {
      if (v == null) return null;
      return DateTime.tryParse('$v'.replaceFirst(' ', 'T'));
    }

    return PrivetUser(
      id: json['id'] as String,
      handle: json['handle'] as String,
      displayName: json['displayName'] as String,
      avatarHue: (json['avatarHue'] as num?)?.toInt() ?? 160,
      avatarUrl: json['avatarUrl'] as String?,
      lastSeenAt: parseTs(json['lastSeenAt']),
      online: json['online'] == true,
      lastReadAt: parseTs(json['lastReadAt']),
    );
  }

  PrivetUser copyWith({
    String? displayName,
    int? avatarHue,
    String? avatarUrl,
    DateTime? lastSeenAt,
    bool? online,
    DateTime? lastReadAt,
    bool clearAvatarUrl = false,
  }) =>
      PrivetUser(
        id: id,
        handle: handle,
        displayName: displayName ?? this.displayName,
        avatarHue: avatarHue ?? this.avatarHue,
        avatarUrl: clearAvatarUrl ? null : (avatarUrl ?? this.avatarUrl),
        lastSeenAt: lastSeenAt ?? this.lastSeenAt,
        online: online ?? this.online,
        lastReadAt: lastReadAt ?? this.lastReadAt,
      );
}

class MemberRead {
  MemberRead({
    required this.userId,
    this.lastReadAt,
    this.lastReadMessageId,
  });

  final String userId;
  final DateTime? lastReadAt;
  final String? lastReadMessageId;

  factory MemberRead.fromJson(Map<String, dynamic> json) {
    DateTime? parseTs(dynamic v) {
      if (v == null) return null;
      return DateTime.tryParse('$v'.replaceFirst(' ', 'T'));
    }

    return MemberRead(
      userId: json['userId'] as String,
      lastReadAt: parseTs(json['lastReadAt']),
      lastReadMessageId: json['lastReadMessageId'] as String?,
    );
  }
}

class ForwardedFrom {
  ForwardedFrom({
    required this.messageId,
    this.displayName,
    this.handle,
  });

  final String messageId;
  final String? displayName;
  final String? handle;

  String get label {
    final name = (displayName ?? '').trim();
    if (name.isNotEmpty) return name;
    final h = (handle ?? '').trim();
    if (h.isNotEmpty) return '@$h';
    return 'Forwarded';
  }

  factory ForwardedFrom.fromJson(Map<String, dynamic> json) => ForwardedFrom(
        messageId: (json['messageId'] as String?) ?? '',
        displayName: json['displayName'] as String?,
        handle: json['handle'] as String?,
      );
}

class MessageReaction {
  MessageReaction({
    required this.emoji,
    required this.count,
    required this.userIds,
  });

  final String emoji;
  final int count;
  final List<String> userIds;

  bool reactedBy(String? userId) =>
      userId != null && userIds.contains(userId);

  factory MessageReaction.fromJson(Map<String, dynamic> json) =>
      MessageReaction(
        emoji: json['emoji'] as String,
        count: (json['count'] as num?)?.toInt() ??
            ((json['userIds'] as List?)?.length ?? 0),
        userIds: ((json['userIds'] as List?) ?? []).map((e) => '$e').toList(),
      );
}

class ReplyPreview {
  ReplyPreview({
    required this.id,
    required this.body,
    required this.kind,
    required this.senderName,
    this.senderHandle = '',
  });

  final String id;
  final String body;
  final String kind;
  final String senderName;
  final String senderHandle;

  factory ReplyPreview.fromJson(Map<String, dynamic> json) => ReplyPreview(
        id: json['id'] as String,
        body: (json['body'] as String?) ?? '',
        kind: (json['kind'] as String?) ?? 'text',
        senderName: (json['senderName'] as String?) ?? '',
        senderHandle: (json['senderHandle'] as String?) ?? '',
      );

  factory ReplyPreview.fromMessage(
    ChatMessage m, {
    String? bodyOverride,
  }) =>
      ReplyPreview(
        id: m.id,
        body: (bodyOverride != null && bodyOverride.isNotEmpty)
            ? bodyOverride
            : m.body.isNotEmpty
                ? m.body
                : switch (m.kind) {
                    'image' => '📷 Photo',
                    'video' => '🎬 Video',
                    'audio' => '🎵 Audio',
                    'voice' => '🎤 Voice message',
                    'file' => m.fileName ?? '📎 File',
                    'album' => m.body.isNotEmpty
                        ? m.body
                        : '📎 ${m.mediaItems.length} attachments',
                    _ => m.body,
                  },
        kind: m.kind,
        senderName: m.sender.displayName,
        senderHandle: m.sender.handle,
      );
}

/// Shared checklist for a conversation (DM or group). Anyone in the chat can edit.
class TaskItem {
  TaskItem({
    required this.id,
    required this.conversationId,
    required this.body,
    required this.done,
    required this.sortOrder,
    required this.createdAt,
    this.messageId,
    this.mediaUrl,
    this.mimeType,
    this.fileName,
    this.createdBy,
    this.updatedAt,
  });

  final String id;
  final String conversationId;
  final String body;
  final bool done;
  final int sortOrder;
  final String? messageId;
  final String? mediaUrl;
  final String? mimeType;
  final String? fileName;
  final PrivetUser? createdBy;
  final DateTime createdAt;
  final DateTime? updatedAt;

  bool get hasMedia => mediaUrl != null && mediaUrl!.isNotEmpty;

  bool get isImage {
    if (mimeType != null && mimeType!.startsWith('image/')) return true;
    final name = (fileName ?? mediaUrl ?? '').toLowerCase();
    return name.endsWith('.png') ||
        name.endsWith('.jpg') ||
        name.endsWith('.jpeg') ||
        name.endsWith('.gif') ||
        name.endsWith('.webp');
  }

  factory TaskItem.fromJson(Map<String, dynamic> json) => TaskItem(
        id: json['id'] as String,
        conversationId: json['conversationId'] as String,
        body: (json['body'] as String?) ?? '',
        done: json['done'] == true,
        sortOrder: (json['sortOrder'] as num?)?.toInt() ?? 0,
        messageId: json['messageId'] as String?,
        mediaUrl: json['mediaUrl'] as String?,
        mimeType: json['mimeType'] as String?,
        fileName: json['fileName'] as String?,
        createdBy: json['createdBy'] is Map<String, dynamic>
            ? PrivetUser.fromJson(json['createdBy'] as Map<String, dynamic>)
            : null,
        createdAt: DateTime.tryParse('${json['createdAt']}') ?? DateTime.now(),
        updatedAt: json['updatedAt'] != null
            ? DateTime.tryParse('${json['updatedAt']}')
            : null,
      );

  TaskItem copyWith({
    String? body,
    bool? done,
    String? mediaUrl,
    String? mimeType,
    String? fileName,
    bool clearMedia = false,
  }) =>
      TaskItem(
        id: id,
        conversationId: conversationId,
        body: body ?? this.body,
        done: done ?? this.done,
        sortOrder: sortOrder,
        messageId: messageId,
        mediaUrl: clearMedia ? null : (mediaUrl ?? this.mediaUrl),
        mimeType: clearMedia ? null : (mimeType ?? this.mimeType),
        fileName: clearMedia ? null : (fileName ?? this.fileName),
        createdBy: createdBy,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );
}

class ConversationTasks {
  ConversationTasks({required this.items});

  final List<TaskItem> items;

  int get total => items.length;
  int get doneCount => items.where((i) => i.done).length;
  bool get isComplete => total == 0 || doneCount == total;
  double get progress => total == 0 ? 1.0 : doneCount / total;

  factory ConversationTasks.fromJsonList(List<dynamic> list) =>
      ConversationTasks(
        items: list
            .map((e) => TaskItem.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class MediaAttachment {
  MediaAttachment({
    required this.mediaUrl,
    required this.kind,
    this.mimeType,
    this.fileName,
    this.fileSize,
  });

  final String mediaUrl;
  final String kind;
  final String? mimeType;
  final String? fileName;
  final int? fileSize;

  factory MediaAttachment.fromJson(Map<String, dynamic> json) =>
      MediaAttachment(
        mediaUrl: json['mediaUrl'] as String,
        kind: (json['kind'] as String?) ?? 'file',
        mimeType: json['mimeType'] as String?,
        fileName: json['fileName'] as String?,
        fileSize: (json['fileSize'] as num?)?.toInt(),
      );

  Map<String, dynamic> toJson() => {
        'mediaUrl': mediaUrl,
        'kind': kind,
        if (mimeType != null) 'mimeType': mimeType,
        if (fileName != null) 'fileName': fileName,
        if (fileSize != null) 'fileSize': fileSize,
      };
}

/// Teams-style link unfurl (Open Graph / Twitter card).
class LinkPreview {
  LinkPreview({
    required this.url,
    this.title,
    this.description,
    this.image,
    this.siteName,
  });

  final String url;
  final String? title;
  final String? description;
  final String? image;
  final String? siteName;

  factory LinkPreview.fromJson(Map<String, dynamic> json) => LinkPreview(
        url: json['url'] as String,
        title: json['title'] as String?,
        description: json['description'] as String?,
        image: json['image'] as String?,
        siteName: json['siteName'] as String?,
      );
}

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.conversationId,
    required this.body,
    required this.kind,
    required this.createdAt,
    required this.sender,
    this.mediaUrl,
    this.mimeType,
    this.fileName,
    this.fileSize,
    this.attachments = const [],
    this.replyToId,
    this.replyTo,
    this.forwardedFrom,
    this.linkPreview,
    this.reactions = const [],
    this.pending = false,
    this.editedAt,
    this.deletedAt,
    this.conversationTitle,
    this.conversationIsGroup = false,
    this.aiLocal = false,
  });

  final String id;
  final String conversationId;
  final String body;
  final String kind;
  final DateTime createdAt;
  final PrivetUser sender;
  final String? mediaUrl;
  final String? mimeType;
  final String? fileName;
  final int? fileSize;
  final List<MediaAttachment> attachments;
  final String? replyToId;
  final ReplyPreview? replyTo;
  final ForwardedFrom? forwardedFrom;
  final LinkPreview? linkPreview;
  final List<MessageReaction> reactions;
  final bool pending;
  final DateTime? editedAt;
  final DateTime? deletedAt;
  final String? conversationTitle;
  final bool conversationIsGroup;
  final bool aiLocal;

  bool get isDeleted =>
      deletedAt != null || kind == 'deleted';

  bool get hasAccentWrap =>
      !isDeleted &&
      (replyTo != null || linkPreview != null || forwardedFrom != null);

  List<MediaAttachment> get mediaItems {
    if (isDeleted) return const [];
    if (attachments.isNotEmpty) return attachments;
    if (mediaUrl == null || mediaUrl!.isEmpty) return const [];
    return [
      MediaAttachment(
        mediaUrl: mediaUrl!,
        kind: kind == 'album' ? 'file' : kind,
        mimeType: mimeType,
        fileName: fileName,
        fileSize: fileSize,
      ),
    ];
  }

  bool get isMedia =>
      !isDeleted &&
      (kind == 'image' ||
          kind == 'video' ||
          kind == 'audio' ||
          kind == 'voice' ||
          kind == 'file' ||
          kind == 'album' ||
          mediaItems.isNotEmpty);

  ChatMessage copyWith({
    String? body,
    List<MessageReaction>? reactions,
    ReplyPreview? replyTo,
    ForwardedFrom? forwardedFrom,
    LinkPreview? linkPreview,
    bool? pending,
    DateTime? editedAt,
    DateTime? deletedAt,
    bool? aiLocal,
  }) =>
      ChatMessage(
        id: id,
        conversationId: conversationId,
        body: body ?? this.body,
        kind: kind,
        createdAt: createdAt,
        sender: sender,
        mediaUrl: mediaUrl,
        mimeType: mimeType,
        fileName: fileName,
        fileSize: fileSize,
        attachments: attachments,
        replyToId: replyToId,
        replyTo: replyTo ?? this.replyTo,
        forwardedFrom: forwardedFrom ?? this.forwardedFrom,
        linkPreview: linkPreview ?? this.linkPreview,
        reactions: reactions ?? this.reactions,
        pending: pending ?? this.pending,
        editedAt: editedAt ?? this.editedAt,
        deletedAt: deletedAt ?? this.deletedAt,
        conversationTitle: conversationTitle,
        conversationIsGroup: conversationIsGroup,
        aiLocal: aiLocal ?? this.aiLocal,
      );

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final sender = json['sender'] as Map<String, dynamic>? ??
        {
          'id': json['senderId'] ?? '',
          'handle': '',
          'displayName': json['senderName'] ?? '',
          'avatarHue': 160,
        };
    final replyRaw = json['replyTo'] as Map<String, dynamic>?;
    final forwardRaw = json['forwardedFrom'] as Map<String, dynamic>?;
    final linkRaw = json['linkPreview'] as Map<String, dynamic>?;
    final reactionsRaw = (json['reactions'] as List?) ?? const [];
    final attachmentsRaw = (json['attachments'] as List?) ?? const [];
    DateTime? parseTs(dynamic v) {
      if (v == null) return null;
      return DateTime.tryParse('$v'.replaceFirst(' ', 'T'));
    }

    return ChatMessage(
      id: json['id'] as String,
      conversationId: json['conversationId'] as String? ?? '',
      body: (json['body'] as String?) ?? '',
      kind: (json['kind'] as String?) ?? 'text',
      mediaUrl: json['mediaUrl'] as String?,
      mimeType: json['mimeType'] as String?,
      fileName: json['fileName'] as String?,
      fileSize: (json['fileSize'] as num?)?.toInt(),
      attachments: attachmentsRaw
          .whereType<Map>()
          .map((e) => MediaAttachment.fromJson(Map<String, dynamic>.from(e)))
          .where((e) => e.mediaUrl.isNotEmpty)
          .toList(),
      replyToId: json['replyToId'] as String?,
      replyTo: replyRaw == null ? null : ReplyPreview.fromJson(replyRaw),
      forwardedFrom:
          forwardRaw == null ? null : ForwardedFrom.fromJson(forwardRaw),
      linkPreview: linkRaw == null ? null : LinkPreview.fromJson(linkRaw),
      reactions: reactionsRaw
          .map((e) => MessageReaction.fromJson(e as Map<String, dynamic>))
          .toList(),
      createdAt: parseTs(json['createdAt']) ?? DateTime.now(),
      editedAt: parseTs(json['editedAt']),
      deletedAt: parseTs(json['deletedAt']),
      sender: PrivetUser.fromJson(Map<String, dynamic>.from(sender)),
      conversationTitle: json['conversationTitle'] as String?,
      conversationIsGroup: json['conversationIsGroup'] == true,
    );
  }
}

class Conversation {
  Conversation({
    required this.id,
    required this.title,
    required this.isGroup,
    this.peer,
    this.lastMessage,
    this.memberCount = 2,
    this.ownerId,
    this.muted = false,
    this.pinned = false,
    this.unreadCount = 0,
    this.lastReadAt,
    this.peerLastReadAt,
    this.memberReads = const [],
  });

  final String id;
  final String title;
  final bool isGroup;
  final PrivetUser? peer;
  final ChatMessage? lastMessage;
  final int memberCount;
  final String? ownerId;
  final bool muted;
  final bool pinned;
  final int unreadCount;
  final DateTime? lastReadAt;
  final DateTime? peerLastReadAt;
  final List<MemberRead> memberReads;

  bool isOwnedBy(String? userId) =>
      isGroup && userId != null && ownerId == userId;

  bool isReadByPeer(ChatMessage message, {String? selfId}) {
    // Compare at second precision (server timestamps have no ms).
    final sent = message.createdAt.millisecondsSinceEpoch ~/ 1000;
    if (!isGroup) {
      if (peerLastReadAt == null) return false;
      final read = peerLastReadAt!.millisecondsSinceEpoch ~/ 1000;
      return read >= sent;
    }
    // Group: read if at least one other member has caught up.
    for (final r in memberReads) {
      if (selfId != null && r.userId == selfId) continue;
      if (r.userId == message.sender.id) continue;
      if (r.lastReadAt == null) continue;
      final read = r.lastReadAt!.millisecondsSinceEpoch ~/ 1000;
      if (read >= sent) return true;
    }
    return false;
  }

  List<String> seenByUserIds(ChatMessage message, {String? selfId}) {
    final sent = message.createdAt.millisecondsSinceEpoch ~/ 1000;
    final ids = <String>[];
    for (final r in memberReads) {
      if (selfId != null && r.userId == selfId) continue;
      if (r.userId == message.sender.id) continue;
      if (r.lastReadAt == null) continue;
      final read = r.lastReadAt!.millisecondsSinceEpoch ~/ 1000;
      if (read >= sent) ids.add(r.userId);
    }
    return ids;
  }

  Conversation copyWith({
    bool? muted,
    bool? pinned,
    int? unreadCount,
    DateTime? lastReadAt,
    DateTime? peerLastReadAt,
    ChatMessage? lastMessage,
    List<MemberRead>? memberReads,
  }) =>
      Conversation(
        id: id,
        title: title,
        isGroup: isGroup,
        peer: peer,
        lastMessage: lastMessage ?? this.lastMessage,
        memberCount: memberCount,
        ownerId: ownerId,
        muted: muted ?? this.muted,
        pinned: pinned ?? this.pinned,
        unreadCount: unreadCount ?? this.unreadCount,
        lastReadAt: lastReadAt ?? this.lastReadAt,
        peerLastReadAt: peerLastReadAt ?? this.peerLastReadAt,
        memberReads: memberReads ?? this.memberReads,
      );

  factory Conversation.fromJson(Map<String, dynamic> json) {
    final last = json['lastMessage'] as Map<String, dynamic>?;
    DateTime? parseTs(dynamic v) {
      if (v == null) return null;
      return DateTime.tryParse('$v'.replaceFirst(' ', 'T'));
    }

    final readsRaw = (json['memberReads'] as List?) ?? const [];

    return Conversation(
      id: json['id'] as String,
      title: json['title'] as String,
      isGroup: json['isGroup'] == true,
      memberCount: (json['memberCount'] as num?)?.toInt() ?? 2,
      ownerId: json['ownerId'] as String?,
      muted: json['muted'] == true,
      pinned: json['pinned'] == true,
      unreadCount: (json['unreadCount'] as num?)?.toInt() ?? 0,
      lastReadAt: parseTs(json['lastReadAt']),
      peerLastReadAt: parseTs(json['peerLastReadAt']),
      memberReads: readsRaw
          .whereType<Map>()
          .map((e) => MemberRead.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      peer: json['peer'] == null
          ? null
          : PrivetUser.fromJson(json['peer'] as Map<String, dynamic>),
      lastMessage: last == null
          ? null
          : ChatMessage(
              id: last['id'] as String,
              conversationId: json['id'] as String,
              body: (last['body'] as String?) ?? '',
              kind: (last['kind'] as String?) ?? 'text',
              mediaUrl: last['mediaUrl'] as String?,
              createdAt: parseTs(last['createdAt']) ?? DateTime.now(),
              sender: PrivetUser(
                id: last['senderId'] as String? ?? '',
                handle: '',
                displayName: last['senderName'] as String? ?? '',
                avatarHue: 160,
              ),
            ),
    );
  }
}

class SearchChatHit {
  SearchChatHit({
    required this.conversationId,
    required this.title,
    required this.isGroup,
    this.snippet,
    this.avatarHue,
    this.avatarUrl,
    this.peerHandle,
  });

  final String conversationId;
  final String title;
  final bool isGroup;
  final String? snippet;
  final int? avatarHue;
  final String? avatarUrl;
  final String? peerHandle;

  factory SearchChatHit.fromJson(Map<String, dynamic> json) => SearchChatHit(
        conversationId: json['conversationId'] as String,
        title: (json['title'] as String?) ?? 'Chat',
        isGroup: json['isGroup'] == true,
        snippet: json['snippet'] as String?,
        avatarHue: (json['avatarHue'] as num?)?.toInt(),
        avatarUrl: json['avatarUrl'] as String?,
        peerHandle: json['peerHandle'] as String?,
      );
}

class SearchResults {
  SearchResults({
    required this.chats,
    required this.people,
    required this.messages,
    required this.media,
  });

  /// Chats matching by name/handle or by message content.
  final List<SearchChatHit> chats;
  final List<PrivetUser> people;
  final List<ChatMessage> messages;
  final List<ChatMessage> media;

  bool get isEmpty =>
      chats.isEmpty && people.isEmpty && messages.isEmpty && media.isEmpty;

  factory SearchResults.fromJson(Map<String, dynamic> json) => SearchResults(
        chats: ((json['chats'] as List?) ?? [])
            .map((e) => SearchChatHit.fromJson(e as Map<String, dynamic>))
            .toList(),
        people: ((json['people'] as List?) ?? [])
            .map((e) => PrivetUser.fromJson(e as Map<String, dynamic>))
            .toList(),
        messages: ((json['messages'] as List?) ?? [])
            .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
            .toList(),
        media: ((json['media'] as List?) ?? [])
            .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  static SearchResults empty() => SearchResults(
        chats: const [],
        people: const [],
        messages: const [],
        media: const [],
      );
}

class MediaUpload {
  MediaUpload({
    required this.mediaUrl,
    required this.mimeType,
    required this.fileName,
    required this.fileSize,
    required this.kind,
  });

  final String mediaUrl;
  final String mimeType;
  final String fileName;
  final int fileSize;
  final String kind;

  factory MediaUpload.fromJson(Map<String, dynamic> json) => MediaUpload(
        mediaUrl: json['mediaUrl'] as String,
        mimeType: json['mimeType'] as String,
        fileName: json['fileName'] as String,
        fileSize: (json['fileSize'] as num).toInt(),
        kind: json['kind'] as String,
      );
}

class CallInfo {
  CallInfo({
    required this.id,
    required this.conversationId,
    required this.mode,
    required this.fromUserId,
    required this.toUserId,
  });

  final String id;
  final String conversationId;
  final String mode; // audio | video | screen
  final String fromUserId;
  final String toUserId;

  factory CallInfo.fromJson(Map<String, dynamic> json) => CallInfo(
        id: json['id'] as String,
        conversationId: json['conversationId'] as String,
        mode: (json['mode'] as String?) ?? 'video',
        fromUserId: json['fromUserId'] as String,
        toUserId: json['toUserId'] as String,
      );
}

enum CallPhase { idle, outgoing, incoming, connecting, active }

class ActiveCall {
  ActiveCall({
    required this.call,
    required this.phase,
    required this.peer,
    required this.isCaller,
    this.withVideo = true,
  });

  final CallInfo call;
  final CallPhase phase;
  final PrivetUser peer;
  final bool isCaller;
  final bool withVideo;

  ActiveCall copyWith({CallPhase? phase, bool? withVideo}) => ActiveCall(
        call: call,
        phase: phase ?? this.phase,
        peer: peer,
        isCaller: isCaller,
        withVideo: withVideo ?? this.withVideo,
      );
}
