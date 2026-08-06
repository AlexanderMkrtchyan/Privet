import 'util/call_history.dart';
import 'util/server_time.dart';

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
    return PrivetUser(
      id: json['id'] as String,
      handle: json['handle'] as String,
      displayName: json['displayName'] as String,
      avatarHue: (json['avatarHue'] as num?)?.toInt() ?? 160,
      avatarUrl: json['avatarUrl'] as String?,
      lastSeenAt: parseServerUtc(json['lastSeenAt']),
      online: json['online'] == true,
      lastReadAt: parseServerUtc(json['lastReadAt']),
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
    return MemberRead(
      userId: json['userId'] as String,
      lastReadAt: parseServerUtc(json['lastReadAt']),
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

/// One outbound forward of a message into another conversation.
class ForwardedTo {
  ForwardedTo({
    required this.conversationId,
    required this.title,
    this.isGroup = false,
    this.forwardedMessageId,
    this.byUserId,
    this.createdAt,
  });

  final String conversationId;
  final String title;
  final bool isGroup;
  final String? forwardedMessageId;
  final String? byUserId;
  final DateTime? createdAt;

  factory ForwardedTo.fromJson(Map<String, dynamic> json) => ForwardedTo(
        conversationId: (json['conversationId'] as String?) ?? '',
        title: ((json['title'] as String?) ?? '').trim().isNotEmpty
            ? (json['title'] as String).trim()
            : 'Chat',
        isGroup: json['isGroup'] == true,
        forwardedMessageId: json['forwardedMessageId'] as String?,
        byUserId: json['byUserId'] as String?,
        createdAt: parseServerUtc(json['createdAt']),
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
    this.mediaUrl,
    this.fileName,
    this.mimeType,
    this.mediaThumbnails = const [],
  });

  final String id;
  final String body;
  final String kind;
  final String senderName;
  final String senderHandle;

  /// First image attachment of the replied-to message, when it has one —
  /// used to render a small thumbnail inside the reply quote.
  final String? mediaUrl;
  final String? fileName;
  final String? mimeType;

  /// All image thumbnails from the replied-to message (server includes all,
  /// not just the first). Falls back to [mediaUrl] when the server does not
  /// supply this field (old messages or legacy clients).
  final List<ReplyThumbnail> mediaThumbnails;

  /// All image thumbnail URLs for use in reply rendering. Combines
  /// [mediaThumbnails] (new server field) with a legacy fallback from
  /// [mediaUrl].
  List<ReplyThumbnail> get allThumbnails {
    if (mediaThumbnails.isNotEmpty) return mediaThumbnails;
    if (mediaUrl != null && mediaUrl!.isNotEmpty) {
      return [ReplyThumbnail(mediaUrl: mediaUrl!, fileName: fileName, mimeType: mimeType)];
    }
    return const [];
  }

  factory ReplyPreview.fromJson(Map<String, dynamic> json) => ReplyPreview(
        id: json['id'] as String,
        body: (json['body'] as String?) ?? '',
        kind: (json['kind'] as String?) ?? 'text',
        senderName: (json['senderName'] as String?) ?? '',
        senderHandle: (json['senderHandle'] as String?) ?? '',
        mediaUrl: json['mediaUrl'] as String?,
        fileName: json['fileName'] as String?,
        mimeType: json['mimeType'] as String?,
        mediaThumbnails: (json['mediaThumbnails'] as List<dynamic>?)
                ?.map((e) =>
                    ReplyThumbnail.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
      );

  factory ReplyPreview.fromMessage(
    ChatMessage m, {
    String? bodyOverride,
  }) {
    final images = m.mediaItems.where((e) => e.kind == 'image').toList();
    final firstImage = images.isNotEmpty ? images.first : null;
    return ReplyPreview(
      id: m.id,
      body: (bodyOverride != null && bodyOverride.isNotEmpty)
          ? bodyOverride
          : m.kind == 'call'
              ? CallHistoryPayload.preview(m.body)
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
      mediaUrl: firstImage?.mediaUrl,
      fileName: firstImage?.fileName,
      mimeType: firstImage?.mimeType,
      mediaThumbnails: images
          .map((a) => ReplyThumbnail(
                mediaUrl: a.mediaUrl,
                fileName: a.fileName,
                mimeType: a.mimeType,
              ))
          .toList(),
    );
  }
}

/// A single image thumbnail inside a reply preview.
class ReplyThumbnail {
  const ReplyThumbnail({
    required this.mediaUrl,
    this.fileName,
    this.mimeType,
  });

  final String mediaUrl;
  final String? fileName;
  final String? mimeType;

  factory ReplyThumbnail.fromJson(Map<String, dynamic> json) =>
      ReplyThumbnail(
        mediaUrl: (json['mediaUrl'] as String?) ?? '',
        fileName: json['fileName'] as String?,
        mimeType: json['mimeType'] as String?,
      );
}

/// Shared checklist for a conversation (DM or group). Anyone in the chat can edit.
class TaskItem {
  TaskItem({
    required this.id,
    required this.conversationId,
    required this.body,
    required this.done,
    required this.doneConfirmed,
    required this.sortOrder,
    required this.createdAt,
    this.parentId,
    this.messageId,
    this.mediaUrl,
    this.mimeType,
    this.fileName,
    this.attachments = const [],
    this.createdBy,
    this.assignedTo,
    this.pinned = false,
    this.updatedAt,
    this.subtaskDone,
    this.subtaskTotal,
  });

  final String id;
  final String conversationId;
  /// Null for top-level tasks; set for subtasks.
  final String? parentId;
  final String body;
  final bool done;
  /// True only when creator (setter) has confirmed the task is done — it disappears from active list.
  final bool doneConfirmed;
  final int sortOrder;
  final String? messageId;
  final String? mediaUrl;
  final String? mimeType;
  final String? fileName;
  final List<MediaAttachment> attachments;
  final PrivetUser? createdBy;
  final PrivetUser? assignedTo;
  final bool pinned;
  final DateTime createdAt;
  final DateTime? updatedAt;
  /// Subtask progress counts (set on parent tasks from server).
  final int? subtaskDone;
  final int? subtaskTotal;

  bool get isSubtask => parentId != null && parentId!.isNotEmpty;

  bool get hasMedia =>
      attachments.isNotEmpty || (mediaUrl != null && mediaUrl!.isNotEmpty);

  List<MediaAttachment> get mediaItems {
    if (attachments.isNotEmpty) return attachments;
    if (mediaUrl == null || mediaUrl!.isEmpty) return const [];
    return [
      MediaAttachment(
        mediaUrl: mediaUrl!,
        kind: isImage ? 'image' : 'file',
        mimeType: mimeType,
        fileName: fileName,
      ),
    ];
  }

  bool get isImage {
    if (mimeType != null && mimeType!.startsWith('image/')) return true;
    final name = (fileName ?? mediaUrl ?? '').toLowerCase();
    return name.endsWith('.png') ||
        name.endsWith('.jpg') ||
        name.endsWith('.jpeg') ||
        name.endsWith('.gif') ||
        name.endsWith('.webp');
  }

  factory TaskItem.fromJson(Map<String, dynamic> json) {
    final attachmentsRaw = (json['attachments'] as List?) ?? const [];
    final parsed = attachmentsRaw
        .whereType<Map>()
        .map((e) => MediaAttachment.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    return TaskItem(
      id: json['id'] as String,
      conversationId: json['conversationId'] as String,
      parentId: json['parentId'] as String?,
      body: (json['body'] as String?) ?? '',
      done: json['done'] == true,
      doneConfirmed: json['doneConfirmed'] == true,
      sortOrder: (json['sortOrder'] as num?)?.toInt() ?? 0,
      messageId: json['messageId'] as String?,
      mediaUrl: json['mediaUrl'] as String?,
      mimeType: json['mimeType'] as String?,
      fileName: json['fileName'] as String?,
      attachments: parsed,
      createdBy: json['createdBy'] is Map<String, dynamic>
          ? PrivetUser.fromJson(json['createdBy'] as Map<String, dynamic>)
          : null,
      assignedTo: json['assignedTo'] is Map<String, dynamic>
          ? PrivetUser.fromJson(json['assignedTo'] as Map<String, dynamic>)
          : null,
      pinned: json['pinned'] == true,
      createdAt: parseServerUtc(json['createdAt']) ?? DateTime.now(),
      updatedAt: parseServerUtc(json['updatedAt']),
      subtaskDone: (json['subtaskDone'] as num?)?.toInt(),
      subtaskTotal: (json['subtaskTotal'] as num?)?.toInt(),
    );
  }

  TaskItem copyWith({
    String? body,
    bool? done,
    bool? doneConfirmed,
    String? mediaUrl,
    String? mimeType,
    String? fileName,
    List<MediaAttachment>? attachments,
    bool? pinned,
    int? subtaskDone,
    int? subtaskTotal,
    bool clearMedia = false,
  }) =>
      TaskItem(
        id: id,
        conversationId: conversationId,
        parentId: parentId,
        body: body ?? this.body,
        done: done ?? this.done,
        doneConfirmed: doneConfirmed ?? this.doneConfirmed,
        sortOrder: sortOrder,
        messageId: messageId,
        mediaUrl: clearMedia ? null : (mediaUrl ?? this.mediaUrl),
        mimeType: clearMedia ? null : (mimeType ?? this.mimeType),
        fileName: clearMedia ? null : (fileName ?? this.fileName),
        attachments: clearMedia ? const [] : (attachments ?? this.attachments),
        createdBy: createdBy,
        assignedTo: assignedTo,
        pinned: pinned ?? this.pinned,
        createdAt: createdAt,
        updatedAt: updatedAt,
        subtaskDone: subtaskDone ?? this.subtaskDone,
        subtaskTotal: subtaskTotal ?? this.subtaskTotal,
      );
}

class ConversationTasks {
  ConversationTasks({required this.items});

  final List<TaskItem> items;

  /// Top-level tasks only (excludes subtasks).
  List<TaskItem> get rootItems =>
      items.where((i) => !i.isSubtask).toList();

  /// Root tasks still on the board — everything not confirmed done.
  /// Tasks marked done stay visible until the creator approves them.
  List<TaskItem> get activeItems =>
      rootItems.where((i) => !i.doneConfirmed).toList();

  /// Undone subtasks only (for remaining-work counts).
  List<TaskItem> activeSubtasksOf(String parentId) => items
      .where((i) =>
          i.parentId == parentId && !i.done && !i.doneConfirmed)
      .toList();

  /// All subtasks under a parent (includes done — shown until group completes).
  List<TaskItem> subtasksOf(String parentId) =>
      items.where((i) => i.parentId == parentId).toList();

  TaskItem? get pinnedTask {
    for (final t in activeItems) {
      if (t.pinned) return t;
    }
    return null;
  }

  /// Progress for a pinned/active parent (includes done subtasks in counts).
  ({int done, int total}) progressFor(TaskItem parent) {
    if (parent.subtaskTotal != null && parent.subtaskTotal! > 0) {
      return (
        done: parent.subtaskDone ?? 0,
        total: parent.subtaskTotal!,
      );
    }
    final kids = activeSubtasksOf(parent.id);
    if (kids.isNotEmpty) {
      return (done: 0, total: kids.length);
    }
    return (done: parent.done ? 1 : 0, total: 1);
  }

  /// Board total: work units across every active (non-confirmed) root.
  int get total {
    var n = 0;
    for (final t in activeItems) {
      final kids = subtasksOf(t.id);
      n += kids.isEmpty ? 1 : kids.length;
    }
    return n;
  }

  int get doneCount {
    var n = 0;
    for (final t in activeItems) {
      final kids = subtasksOf(t.id);
      if (kids.isEmpty) {
        if (t.done) n += 1;
      } else {
        n += kids.where((s) => s.done).length;
      }
    }
    return n;
  }

  bool get isComplete => total == 0;
  double get progress {
    if (total == 0) return 1.0;
    return doneCount / total;
  }

  factory ConversationTasks.fromJsonList(List<dynamic> list) =>
      ConversationTasks(
        items: list
            .map((e) => TaskItem.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// Line item spent from a payment wallet (beer, taxi, etc.).
class PaymentExpense {
  PaymentExpense({
    required this.id,
    required this.paymentId,
    required this.label,
    required this.amountCents,
    this.createdAt,
    this.sortOrder = 0,
  });

  final String id;
  final String paymentId;
  final String label;
  final int amountCents;
  final DateTime? createdAt;
  final int sortOrder;

  double get amountDouble => amountCents / 100.0;

  factory PaymentExpense.fromJson(Map<String, dynamic> json) => PaymentExpense(
        id: json['id'] as String,
        paymentId: json['paymentId'] as String,
        label: (json['label'] as String?) ?? '',
        amountCents: (json['amountCents'] as num?)?.toInt() ?? 0,
        createdAt: parseServerUtc(json['createdAt']),
        sortOrder: (json['sortOrder'] as num?)?.toInt() ?? 0,
      );
}

/// Payment or generic reminder attached to a conversation (visible to creator only).
class PaymentReminder {
  PaymentReminder({
    required this.id,
    required this.conversationId,
    required this.kind,
    required this.currency,
    required this.direction,
    required this.dueDate,
    required this.paid,
    required this.createdAt,
    this.amountCents,
    this.note = '',
    this.paidAt,
    this.paidBy,
    this.snoozedUntil,
    this.createdBy,
    this.updatedAt,
    this.pinned = false,
    this.expenses = const [],
  });

  final String id;
  final String conversationId;

  /// 'payment' or 'reminder' (plain text reminder without amount).
  final String kind;
  final int? amountCents;
  final String currency;

  /// 'owe' = I owe them, 'owed' = they owe me (only relevant for payment kind).
  final String direction;
  final String note;
  final String dueDate; // ISO date yyyy-MM-dd
  final bool paid;
  final DateTime? paidAt;
  final PrivetUser? paidBy;
  final DateTime? snoozedUntil;
  final PrivetUser? createdBy;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final bool pinned;
  final List<PaymentExpense> expenses;

  bool get isPayment => kind == 'payment';

  double? get amountDouble => amountCents != null ? amountCents! / 100.0 : null;

  int get spentCents => expenses.fold<int>(0, (sum, e) => sum + e.amountCents);

  int? get remainingCents =>
      amountCents == null ? null : amountCents! - spentCents;

  String get currencySymbol {
    const symbols = {'USD': '\$', 'EUR': '€', 'GBP': '£', 'RUB': '₽', 'UAH': '₴'};
    return symbols[currency] ?? currency;
  }

  String formatMoney(int cents) {
    final a = cents / 100.0;
    final sym = currencySymbol;
    return a % 1 == 0 ? '$sym${a.toInt()}' : '$sym${a.toStringAsFixed(2)}';
  }

  String get formattedAmount {
    final a = amountDouble;
    if (a == null) return currencySymbol;
    return a % 1 == 0 ? '$currencySymbol${a.toInt()}' : '$currencySymbol${a.toStringAsFixed(2)}';
  }

  /// Amount squeezed into the pinned header chip — at most 4 digits, using
  /// k/M suffixes so even large sums fit the compact pill.
  String get compactAmount {
    final a = amountDouble;
    final sym = currencySymbol;
    if (a == null) return sym;
    final abs = a.abs();
    if (abs >= 1000000) {
      final m = (a / 1000000).toStringAsFixed(1);
      return '$sym${_trimZero(m)}M';
    }
    if (abs >= 10000) {
      final k = (a / 1000).toStringAsFixed(1);
      return '$sym${_trimZero(k)}k';
    }
    if (abs >= 100) return '$sym${a.toInt()}';
    return a % 1 == 0 ? '$sym${a.toInt()}' : '$sym${a.toStringAsFixed(2)}';
  }

  String _trimZero(String s) =>
      s.endsWith('.0') ? s.substring(0, s.length - 2) : s;

  bool get isOverdue {
    if (paid) return false;
    final due = DateTime.tryParse(dueDate);
    if (due == null) return false;
    return DateTime.now().isAfter(due.add(const Duration(days: 1)));
  }

  factory PaymentReminder.fromJson(Map<String, dynamic> json) => PaymentReminder(
        id: json['id'] as String,
        conversationId: json['conversationId'] as String,
        kind: (json['kind'] as String?) ?? 'payment',
        amountCents: json['amountCents'] != null ? (json['amountCents'] as num).toInt() : null,
        currency: (json['currency'] as String?) ?? 'USD',
        direction: (json['direction'] as String?) ?? 'owe',
        note: (json['note'] as String?) ?? '',
        dueDate: json['dueDate'] as String,
        paid: json['paid'] == true,
        paidAt: parseServerUtc(json['paidAt']),
        paidBy: json['paidBy'] is Map<String, dynamic>
            ? PrivetUser.fromJson(json['paidBy'] as Map<String, dynamic>)
            : null,
        snoozedUntil: parseServerUtc(json['snoozedUntil']),
        createdBy: json['createdBy'] is Map<String, dynamic>
            ? PrivetUser.fromJson(json['createdBy'] as Map<String, dynamic>)
            : null,
        createdAt: parseServerUtc(json['createdAt']) ?? DateTime.now(),
        updatedAt: parseServerUtc(json['updatedAt']),
        pinned: json['pinned'] == true,
        expenses: (json['expenses'] as List?)
                ?.whereType<Map>()
                .map((e) => PaymentExpense.fromJson(Map<String, dynamic>.from(e)))
                .toList() ??
            const [],
      );

  PaymentReminder copyWith({
    int? amountCents,
    String? currency,
    String? direction,
    String? note,
    String? dueDate,
    bool? paid,
    DateTime? paidAt,
    DateTime? snoozedUntil,
    List<PaymentExpense>? expenses,
  }) =>
      PaymentReminder(
        id: id,
        conversationId: conversationId,
        kind: kind,
        amountCents: amountCents ?? this.amountCents,
        currency: currency ?? this.currency,
        direction: direction ?? this.direction,
        note: note ?? this.note,
        dueDate: dueDate ?? this.dueDate,
        paid: paid ?? this.paid,
        paidAt: paidAt ?? this.paidAt,
        paidBy: paidBy,
        snoozedUntil: snoozedUntil ?? this.snoozedUntil,
        createdBy: createdBy,
        createdAt: createdAt,
        updatedAt: updatedAt,
        pinned: pinned,
        expenses: expenses ?? this.expenses,
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
    this.forwardedTo = const [],
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

  /// Chats this message was forwarded into (outbound notes on the source).
  final List<ForwardedTo> forwardedTo;
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

  bool get isCallHistory => kind == 'call';

  bool get hasAccentWrap =>
      !isDeleted &&
      (replyTo != null ||
          linkPreview != null ||
          forwardedFrom != null ||
          forwardedTo.isNotEmpty);

  /// e.g. "Forwarded to Jon", "Forwarded to Jon, Team", "Forwarded to 3 chats".
  String? get forwardedToLabel {
    if (forwardedTo.isEmpty) return null;
    if (forwardedTo.length == 1) {
      return 'Forwarded to ${forwardedTo.first.title}';
    }
    if (forwardedTo.length == 2) {
      return 'Forwarded to ${forwardedTo[0].title}, ${forwardedTo[1].title}';
    }
    return 'Forwarded to ${forwardedTo.length} chats';
  }

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
    List<ForwardedTo>? forwardedTo,
    LinkPreview? linkPreview,
    bool? pending,
    DateTime? editedAt,
    DateTime? deletedAt,
    bool? aiLocal,
    String? kind,
    List<MediaAttachment>? attachments,
    String? mediaUrl,
    String? mimeType,
    String? fileName,
    int? fileSize,
  }) =>
      ChatMessage(
        id: id,
        conversationId: conversationId,
        body: body ?? this.body,
        kind: kind ?? this.kind,
        createdAt: createdAt,
        sender: sender,
        mediaUrl: mediaUrl ?? this.mediaUrl,
        mimeType: mimeType ?? this.mimeType,
        fileName: fileName ?? this.fileName,
        fileSize: fileSize ?? this.fileSize,
        attachments: attachments ?? this.attachments,
        replyToId: replyToId,
        replyTo: replyTo ?? this.replyTo,
        forwardedFrom: forwardedFrom ?? this.forwardedFrom,
        forwardedTo: forwardedTo ?? this.forwardedTo,
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
    final forwardedToRaw = (json['forwardedTo'] as List?) ?? const [];

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
      forwardedTo: forwardedToRaw
          .whereType<Map>()
          .map((e) => ForwardedTo.fromJson(Map<String, dynamic>.from(e)))
          .where((e) => e.conversationId.isNotEmpty)
          .toList(),
      linkPreview: linkRaw == null ? null : LinkPreview.fromJson(linkRaw),
      reactions: reactionsRaw
          .map((e) => MessageReaction.fromJson(e as Map<String, dynamic>))
          .toList(),
      createdAt: parseServerUtc(json['createdAt']) ?? DateTime.now(),
      editedAt: parseServerUtc(json['editedAt']),
      deletedAt: parseServerUtc(json['deletedAt']),
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
      lastReadAt: parseServerUtc(json['lastReadAt']),
      peerLastReadAt: parseServerUtc(json['peerLastReadAt']),
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
              createdAt: parseServerUtc(last['createdAt']) ?? DateTime.now(),
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
