import { v4 as uuid } from 'uuid';
import { db, publicUser } from '../db.js';
import { getUserById, listUsersExcept } from '../auth/users.js';

function peerForDm(conversationId, selfId) {
  const row = db
    .prepare(
      `
      SELECT u.* FROM conversation_members cm
      JOIN users u ON u.id = cm.user_id
      WHERE cm.conversation_id = ? AND cm.user_id != ?
      LIMIT 1
    `,
    )
    .get(conversationId, selfId);
  return publicUser(row);
}

function parseLinkPreview(raw) {
  if (!raw) return null;
  try {
    const parsed = typeof raw === 'string' ? JSON.parse(raw) : raw;
    if (!parsed || typeof parsed !== 'object') return null;
    const url = parsed.url ? String(parsed.url) : null;
    if (!url) return null;
    return {
      url,
      title: parsed.title ? String(parsed.title) : null,
      description: parsed.description ? String(parsed.description) : null,
      image: parsed.image ? String(parsed.image) : null,
      siteName: parsed.siteName ? String(parsed.siteName) : null,
    };
  } catch {
    return null;
  }
}

function parseAttachments(raw, fallback = null) {
  if (raw) {
    try {
      const parsed = JSON.parse(raw);
      if (Array.isArray(parsed) && parsed.length > 0) {
        return parsed
          .map((item) => ({
            mediaUrl: item.mediaUrl ? String(item.mediaUrl) : null,
            mimeType: item.mimeType ? String(item.mimeType) : null,
            fileName: item.fileName ? String(item.fileName) : null,
            fileSize:
              typeof item.fileSize === 'number' ? item.fileSize : null,
            kind: item.kind ? String(item.kind) : 'file',
          }))
          .filter((item) => item.mediaUrl);
      }
    } catch {
      // ignore bad JSON
    }
  }
  if (fallback?.mediaUrl) {
    return [
      {
        mediaUrl: fallback.mediaUrl,
        mimeType: fallback.mimeType || null,
        fileName: fallback.fileName || null,
        fileSize: fallback.fileSize ?? null,
        kind: fallback.kind || 'file',
      },
    ];
  }
  return [];
}

function mapMessage(m, { reactions = [], replyTo = null, forwardedTo = [] } = {}) {
  const deleted = !!m.deleted_at;
  const attachments = deleted
    ? []
    : parseAttachments(m.attachments, {
        mediaUrl: m.media_url || null,
        mimeType: m.mime_type || null,
        fileName: m.file_name || null,
        fileSize: m.file_size ?? null,
        kind: m.kind,
      });
  const forwardedFrom =
    !deleted && m.forwarded_from_id
      ? {
          messageId: m.forwarded_from_id,
          displayName: m.forwarded_from_name || null,
          handle: m.forwarded_from_handle || null,
        }
      : null;
  return {
    id: m.id,
    conversationId: m.conversation_id,
    body: deleted ? '' : m.body,
    kind: deleted ? 'deleted' : m.kind,
    mediaUrl: deleted ? null : m.media_url || attachments[0]?.mediaUrl || null,
    mimeType: deleted ? null : m.mime_type || attachments[0]?.mimeType || null,
    fileName: deleted ? null : m.file_name || attachments[0]?.fileName || null,
    fileSize: deleted ? null : m.file_size ?? attachments[0]?.fileSize ?? null,
    attachments,
    replyToId: m.reply_to_id || null,
    replyTo: deleted ? null : replyTo,
    forwardedFrom,
    forwardedTo: deleted ? [] : forwardedTo,
    linkPreview: deleted ? null : parseLinkPreview(m.link_preview),
    reactions: deleted ? [] : reactions,
    createdAt: m.created_at,
    editedAt: m.edited_at || null,
    deletedAt: m.deleted_at || null,
    sender: {
      id: m.sender_id,
      handle: m.sender_handle,
      displayName: m.sender_name,
      avatarHue: m.avatar_hue,
      avatarUrl: m.sender_avatar_url || null,
    },
  };
}

function nowSql() {
  return new Date().toISOString().replace('T', ' ').slice(0, 19);
}

function memberState(conversationId, userId) {
  return (
    db
      .prepare(
        `
        SELECT muted, last_read_message_id, last_read_at, hidden, pinned, pinned_at
        FROM conversation_members
        WHERE conversation_id = ? AND user_id = ?
      `,
      )
      .get(conversationId, userId) || {
      muted: 0,
      last_read_message_id: null,
      last_read_at: null,
      hidden: 0,
      pinned: 0,
      pinned_at: null,
    }
  );
}

function memberReadsForConversation(conversationId) {
  return db
    .prepare(
      `
      SELECT user_id AS userId, last_read_at AS lastReadAt,
             last_read_message_id AS lastReadMessageId
      FROM conversation_members
      WHERE conversation_id = ?
    `,
    )
    .all(conversationId)
    .map((r) => ({
      userId: r.userId,
      lastReadAt: r.lastReadAt || null,
      lastReadMessageId: r.lastReadMessageId || null,
    }));
}

function unreadCount(conversationId, userId, lastReadAt) {
  if (lastReadAt) {
    return db
      .prepare(
        `
        SELECT COUNT(*) AS n FROM messages
        WHERE conversation_id = ?
          AND sender_id != ?
          AND deleted_at IS NULL
          AND created_at > ?
      `,
      )
      .get(conversationId, userId, lastReadAt).n;
  }
  return db
    .prepare(
      `
      SELECT COUNT(*) AS n FROM messages
      WHERE conversation_id = ?
        AND sender_id != ?
        AND deleted_at IS NULL
    `,
    )
    .get(conversationId, userId).n;
}

function formatCallDuration(totalSec) {
  const s = Math.max(0, Math.floor(Number(totalSec) || 0));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const r = s % 60;
  if (h > 0) {
    return `${h}:${String(m).padStart(2, '0')}:${String(r).padStart(2, '0')}`;
  }
  return `${m}:${String(r).padStart(2, '0')}`;
}

function callModeLabel(mode) {
  switch (mode) {
    case 'audio':
      return 'Audio call';
    case 'screen':
      return 'Screen share';
    case 'control':
      return 'Remote control';
    default:
      return 'Video call';
  }
}

/** Teams-style label for kind=call JSON bodies (and plain fallbacks). */
export function callHistoryLabel(body) {
  try {
    const parsed = JSON.parse(body || '');
    if (!parsed || typeof parsed !== 'object') {
      return body || 'Call';
    }
    const modeLabel = callModeLabel(parsed.mode);
    const lower = modeLabel.toLowerCase();
    switch (parsed.outcome) {
      case 'missed':
        return `Missed ${lower}`;
      case 'declined':
        return `Declined ${lower}`;
      case 'canceled':
        return `Canceled ${lower}`;
      default:
        return `${modeLabel} · ${formatCallDuration(parsed.durationSec)}`;
    }
  } catch {
    return body || 'Call';
  }
}

function previewBody(kind, body, attachmentCount = 0) {
  switch (kind) {
    case 'image':
      return body || '📷 Photo';
    case 'video':
      return body || '🎬 Video';
    case 'audio':
      return body || '🎵 Audio';
    case 'voice':
      return '🎤 Voice message';
    case 'file':
      return body || '📎 File';
    case 'album':
      return body || `📎 ${attachmentCount || 2} attachments`;
    case 'call':
      return callHistoryLabel(body);
    case 'task_event': {
      try {
        const parsed = JSON.parse(body || '');
        if (parsed && typeof parsed === 'object' && parsed.summary) {
          return `📋 ${String(parsed.summary).slice(0, 160)}`;
        }
      } catch {
        /* plain body */
      }
      return body ? `📋 ${body}` : '📋 Task update';
    }
    case 'ai': {
      try {
        const parsed = JSON.parse(body || '');
        if (parsed && typeof parsed === 'object') {
          const q = String(parsed.q || '').trim();
          const a = String(parsed.a || '').trim();
          if (a) return `✦ ${a.slice(0, 120)}`;
          if (q) return `✦ ${q.slice(0, 120)}`;
        }
      } catch {
        /* plain body */
      }
      return body ? `✦ ${body}` : '✦ Privet AI';
    }
    default:
      return body;
  }
}

function reactionsForMessage(messageId) {
  const rows = db
    .prepare(
      `
      SELECT emoji, user_id AS userId
      FROM message_reactions
      WHERE message_id = ?
      ORDER BY created_at ASC
    `,
    )
    .all(messageId);

  /** @type {Map<string, { emoji: string, userIds: string[], count: number }>} */
  const grouped = new Map();
  for (const row of rows) {
    const cur = grouped.get(row.emoji) || {
      emoji: row.emoji,
      userIds: [],
      count: 0,
    };
    cur.userIds.push(row.userId);
    cur.count += 1;
    grouped.set(row.emoji, cur);
  }
  return [...grouped.values()];
}

function conversationTitleFor(conversationId, viewerId) {
  const meta = db
    .prepare(
      'SELECT is_group, title FROM conversations WHERE id = ?',
    )
    .get(conversationId);
  if (!meta) return 'Chat';
  if (meta.is_group) {
    const title = (meta.title || '').trim();
    return title || 'Group';
  }
  const peer = peerForDm(conversationId, viewerId);
  const name = (peer?.displayName || '').trim();
  if (name) return name;
  const handle = (peer?.handle || '').trim();
  if (handle) return `@${handle}`;
  return 'Chat';
}

function forwardsForMessage(messageId) {
  return db
    .prepare(
      `
      SELECT
        forwarded_message_id AS forwardedMessageId,
        to_conversation_id AS conversationId,
        target_title AS title,
        target_is_group AS isGroup,
        by_user_id AS byUserId,
        created_at AS createdAt
      FROM message_forwards
      WHERE source_message_id = ?
      ORDER BY created_at ASC
    `,
    )
    .all(messageId)
    .map((row) => ({
      forwardedMessageId: row.forwardedMessageId,
      conversationId: row.conversationId,
      title: row.title || 'Chat',
      isGroup: !!row.isGroup,
      byUserId: row.byUserId,
      createdAt: row.createdAt,
    }));
}

function recordMessageForward({
  sourceMessageId,
  forwardedMessageId,
  toConversationId,
  byUserId,
}) {
  const title = conversationTitleFor(toConversationId, byUserId);
  const meta = db
    .prepare('SELECT is_group FROM conversations WHERE id = ?')
    .get(toConversationId);
  db.prepare(
    `
    INSERT OR REPLACE INTO message_forwards (
      forwarded_message_id, source_message_id, to_conversation_id,
      by_user_id, target_title, target_is_group, created_at
    )
    VALUES (?, ?, ?, ?, ?, ?, ?)
  `,
  ).run(
    forwardedMessageId,
    sourceMessageId,
    toConversationId,
    byUserId,
    title,
    meta?.is_group ? 1 : 0,
    nowSql(),
  );
}

function replyPreview(replyToId, quoteOverride = null) {
  if (!replyToId) return null;
  const row = db
    .prepare(
      `
      SELECT m.id, m.body, m.kind, m.file_name, m.attachments, m.deleted_at,
             u.display_name AS sender_name, u.handle AS sender_handle
      FROM messages m
      JOIN users u ON u.id = m.sender_id
      WHERE m.id = ?
    `,
    )
    .get(replyToId);
  if (!row) return null;
  if (row.deleted_at) {
    return {
      id: row.id,
      body: 'Message deleted',
      kind: 'deleted',
      senderName: row.sender_name,
      senderHandle: row.sender_handle,
    };
  }
  const count = parseAttachments(row.attachments).length;
  const atts = parseAttachments(row.attachments, {
    mediaUrl: row.media_url || null,
    mimeType: row.mime_type || null,
    fileName: row.file_name || null,
    fileSize: row.file_size ?? null,
    kind: row.kind,
  });
  const images = atts.filter((a) => a.kind === 'image');
  const quote =
    typeof quoteOverride === 'string' && quoteOverride.trim()
      ? quoteOverride.trim()
      : null;
  return {
    id: row.id,
    body: quote || previewBody(row.kind, row.body || row.file_name || '', count),
    kind: row.kind,
    senderName: row.sender_name,
    senderHandle: row.sender_handle,
    // Legacy single-image fields (first image)
    mediaUrl: images.length > 0 ? images[0].mediaUrl : null,
    fileName: images.length > 0 ? images[0].fileName : null,
    mimeType: images.length > 0 ? images[0].mimeType : null,
    // All image thumbnails for replies
    mediaThumbnails: images.map((a) => ({
      mediaUrl: a.mediaUrl,
      fileName: a.fileName,
      mimeType: a.mimeType,
    })),
  };
}

function hydrateMessage(row) {
  return mapMessage(row, {
    reactions: reactionsForMessage(row.id),
    replyTo: replyPreview(row.reply_to_id, row.reply_quote),
    forwardedTo: forwardsForMessage(row.id),
  });
}

export function listConversationsForUser(userId) {
  const rows = db
    .prepare(
      `
      SELECT c.*,
             IFNULL(cm.pinned, 0) AS pinned,
             cm.pinned_at AS pinned_at
      FROM conversations c
      JOIN conversation_members cm ON cm.conversation_id = c.id
      WHERE cm.user_id = ? AND IFNULL(cm.hidden, 0) = 0
      ORDER BY
        IFNULL(cm.pinned, 0) DESC,
        CASE WHEN IFNULL(cm.pinned, 0) = 1 THEN cm.pinned_at END DESC,
        (
          SELECT m.created_at FROM messages m
          WHERE m.conversation_id = c.id
          ORDER BY m.created_at DESC LIMIT 1
        ) DESC
    `,
    )
    .all(userId);

  return rows.map((c) => {
    const last = db
      .prepare(
        `
        SELECT m.*, u.display_name AS sender_name, u.handle AS sender_handle,
               u.avatar_hue, u.avatar_url AS sender_avatar_url
        FROM messages m
        JOIN users u ON u.id = m.sender_id
        WHERE m.conversation_id = ?
        ORDER BY m.created_at DESC
        LIMIT 1
      `,
      )
      .get(c.id);

    const peer = c.is_group ? null : peerForDm(c.id, userId);
    const memberCount = c.is_group
      ? db
          .prepare(
            'SELECT COUNT(*) AS n FROM conversation_members WHERE conversation_id = ?',
          )
          .get(c.id).n
      : 2;

    const mine = memberState(c.id, userId);
    let peerLastReadAt = null;
    if (!c.is_group && peer) {
      peerLastReadAt = memberState(c.id, peer.id).last_read_at || null;
    }
    const memberReads = memberReadsForConversation(c.id);

    let lastMessage = null;
    if (last) {
      if (last.deleted_at) {
        lastMessage = {
          id: last.id,
          body: 'Message deleted',
          kind: 'deleted',
          mediaUrl: null,
          createdAt: last.created_at,
          senderId: last.sender_id,
          senderName: last.sender_name,
        };
      } else {
        lastMessage = {
          id: last.id,
          body: previewBody(
            last.kind,
            last.body,
            parseAttachments(last.attachments).length,
          ),
          kind: last.kind,
          mediaUrl: last.media_url || null,
          createdAt: last.created_at,
          senderId: last.sender_id,
          senderName: last.sender_name,
        };
      }
    }

    return {
      id: c.id,
      isGroup: !!c.is_group,
      title: c.title || peer?.displayName || 'Chat',
      memberCount,
      ownerId: c.is_group ? c.owner_id || null : null,
      peer,
      muted: !!mine.muted,
      pinned: !!c.pinned,
      unreadCount: unreadCount(c.id, userId, mine.last_read_at),
      lastReadAt: mine.last_read_at || null,
      peerLastReadAt,
      memberReads,
      lastMessage,
    };
  });
}

export function userInConversation(conversationId, userId) {
  return !!db
    .prepare(
      'SELECT 1 FROM conversation_members WHERE conversation_id = ? AND user_id = ?',
    )
    .get(conversationId, userId);
}

export function listMessages(conversationId, { limit = 80, before } = {}) {
  const lim = Math.min(Math.max(Number(limit) || 80, 1), 200);
  let rows;
  if (before) {
    rows = db
      .prepare(
        `
        SELECT m.*, u.display_name AS sender_name, u.handle AS sender_handle,
               u.avatar_hue, u.avatar_url AS sender_avatar_url
        FROM messages m
        JOIN users u ON u.id = m.sender_id
        WHERE m.conversation_id = ? AND m.created_at < ?
        ORDER BY m.created_at DESC
        LIMIT ?
      `,
      )
      .all(conversationId, before, lim);
  } else {
    rows = db
      .prepare(
        `
        SELECT m.*, u.display_name AS sender_name, u.handle AS sender_handle,
               u.avatar_hue, u.avatar_url AS sender_avatar_url
        FROM messages m
        JOIN users u ON u.id = m.sender_id
        WHERE m.conversation_id = ?
        ORDER BY m.created_at DESC
        LIMIT ?
      `,
      )
      .all(conversationId, lim);
  }

  return rows.reverse().map(hydrateMessage);
}

/// Every media item shared in a conversation's messages (files, images,
/// videos, audio…), newest first, so the Shared Media browser can show the
/// full history instead of only whatever page of messages is loaded.
export function listSharedMedia(conversationId, { limit = 500 } = {}) {
  const lim = Math.min(Math.max(Number(limit) || 500, 1), 2000);
  const rows = db
    .prepare(
      `
      SELECT m.*, u.display_name AS sender_name, u.handle AS sender_handle
      FROM messages m
      JOIN users u ON u.id = m.sender_id
      WHERE m.conversation_id = ?
        AND m.deleted_at IS NULL
        AND (m.media_url IS NOT NULL OR m.attachments IS NOT NULL)
      ORDER BY m.created_at DESC
      LIMIT ?
    `,
    )
    .all(conversationId, lim);

  const items = [];
  for (const row of rows) {
    const atts = parseAttachments(row.attachments, {
      mediaUrl: row.media_url || null,
      mimeType: row.mime_type || null,
      fileName: row.file_name || null,
      fileSize: row.file_size ?? null,
      kind: row.kind,
    });
    for (const a of atts) {
      if (!a.mediaUrl) continue;
      items.push({
        mediaUrl: a.mediaUrl,
        kind: a.kind,
        mimeType: a.mimeType,
        fileName: a.fileName,
        fileSize: a.fileSize,
        createdAt: row.created_at,
        senderId: row.sender_id,
        senderName: row.sender_name,
        source: 'message',
        messageId: row.id,
      });
    }
  }
  return items;
}

export function getMessage(messageId) {
  const row = db
    .prepare(
      `
      SELECT m.*, u.display_name AS sender_name, u.handle AS sender_handle,
             u.avatar_hue, u.avatar_url AS sender_avatar_url
      FROM messages m
      JOIN users u ON u.id = m.sender_id
      WHERE m.id = ?
    `,
    )
    .get(messageId);
  return row ? hydrateMessage(row) : null;
}

export function createMessage({
  conversationId,
  senderId,
  body,
  kind = 'text',
  mediaUrl = null,
  mimeType = null,
  fileName = null,
  fileSize = null,
  replyToId = null,
  replyQuote = null,
  attachments = null,
  forwardFromId = null,
}) {
  const id = uuid();
  const createdAt = new Date().toISOString().replace('T', ' ').slice(0, 19);

  let safeReplyTo = null;
  let safeReplyQuote = null;
  if (replyToId) {
    const parent = db
      .prepare(
        'SELECT id, conversation_id FROM messages WHERE id = ?',
      )
      .get(replyToId);
    if (parent && parent.conversation_id === conversationId) {
      safeReplyTo = parent.id;
      if (typeof replyQuote === 'string') {
        const q = replyQuote.trim().slice(0, 500);
        if (q) safeReplyQuote = q;
      }
    }
  }

  let forwardMeta = {
    forwarded_from_id: null,
    forwarded_from_name: null,
    forwarded_from_handle: null,
  };
  let resolvedBody = body ?? '';
  let resolvedKind = kind;
  let resolvedMediaUrl = mediaUrl;
  let resolvedMime = mimeType;
  let resolvedName = fileName;
  let resolvedSize = fileSize;
  let resolvedAttachments = attachments;

  if (forwardFromId) {
    const src = db
      .prepare(
        `
        SELECT m.*, u.display_name AS sender_name, u.handle AS sender_handle
        FROM messages m
        JOIN users u ON u.id = m.sender_id
        WHERE m.id = ?
      `,
      )
      .get(forwardFromId);
    if (!src || src.deleted_at) {
      throw new Error('source message not found');
    }
    if (!userInConversation(src.conversation_id, senderId)) {
      throw new Error('forbidden');
    }
    forwardMeta = {
      forwarded_from_id: src.id,
      forwarded_from_name: src.sender_name,
      forwarded_from_handle: src.sender_handle,
    };
    resolvedBody = src.body ?? '';
    resolvedKind = src.kind || 'text';
    resolvedMediaUrl = src.media_url;
    resolvedMime = src.mime_type;
    resolvedName = src.file_name;
    resolvedSize = src.file_size;
    if (src.attachments) {
      try {
        resolvedAttachments = JSON.parse(src.attachments);
      } catch {
        resolvedAttachments = null;
      }
    } else {
      resolvedAttachments = null;
    }
    // Forward is a fresh message — no reply chain from source.
    safeReplyTo = null;
    safeReplyQuote = null;
  }

  const cleanAttachments = Array.isArray(resolvedAttachments)
    ? resolvedAttachments
        .map((item) => ({
          mediaUrl: item.mediaUrl ? String(item.mediaUrl) : null,
          mimeType: item.mimeType ? String(item.mimeType) : null,
          fileName: item.fileName ? String(item.fileName) : null,
          fileSize:
            typeof item.fileSize === 'number' ? item.fileSize : null,
          kind: item.kind ? String(item.kind) : 'file',
        }))
        .filter((item) => item.mediaUrl && item.mediaUrl.startsWith('/media/'))
    : [];

  const primary = cleanAttachments[0] || null;
  const storedMediaUrl = resolvedMediaUrl || primary?.mediaUrl || null;
  const storedMime = resolvedMime || primary?.mimeType || null;
  const storedName = resolvedName || primary?.fileName || null;
  const storedSize =
    typeof resolvedSize === 'number' ? resolvedSize : primary?.fileSize ?? null;
  const attachmentsJson =
    cleanAttachments.length > 0 ? JSON.stringify(cleanAttachments) : null;

  db.prepare(
    `
    INSERT INTO messages (
      id, conversation_id, sender_id, body, kind,
      media_url, mime_type, file_name, file_size, reply_to_id, reply_quote, attachments,
      forwarded_from_id, forwarded_from_name, forwarded_from_handle, created_at
    )
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `,
  ).run(
    id,
    conversationId,
    senderId,
    resolvedBody ?? '',
    resolvedKind,
    storedMediaUrl,
    storedMime,
    storedName,
    storedSize,
    safeReplyTo,
    safeReplyQuote,
    attachmentsJson,
    forwardMeta.forwarded_from_id,
    forwardMeta.forwarded_from_name,
    forwardMeta.forwarded_from_handle,
    createdAt,
  );

  // New activity brings the chat back for anyone who hid it.
  db.prepare(
    'UPDATE conversation_members SET hidden = 0 WHERE conversation_id = ?',
  ).run(conversationId);

  // Sender has already seen their own message.
  markConversationRead(conversationId, senderId, id);

  if (forwardMeta.forwarded_from_id) {
    recordMessageForward({
      sourceMessageId: forwardMeta.forwarded_from_id,
      forwardedMessageId: id,
      toConversationId: conversationId,
      byUserId: senderId,
    });
  }

  return getMessage(id);
}

/** Persist Open Graph / link card metadata and return the hydrated message. */
export function setMessageLinkPreview(messageId, preview) {
  if (!messageId || !preview?.url) return null;
  const existing = db
    .prepare('SELECT id FROM messages WHERE id = ?')
    .get(messageId);
  if (!existing) return null;
  const payload = JSON.stringify({
    url: String(preview.url),
    title: preview.title ? String(preview.title) : null,
    description: preview.description ? String(preview.description) : null,
    image: preview.image ? String(preview.image) : null,
    siteName: preview.siteName ? String(preview.siteName) : null,
  });
  db.prepare('UPDATE messages SET link_preview = ? WHERE id = ?').run(
    payload,
    messageId,
  );
  return getMessage(messageId);
}

export function toggleReaction({ messageId, userId, emoji }) {
  const clean = String(emoji || '').trim().slice(0, 16);
  if (!clean) throw new Error('emoji required');

  const message = db
    .prepare('SELECT id, conversation_id FROM messages WHERE id = ?')
    .get(messageId);
  if (!message) throw new Error('message not found');

  const existing = db
    .prepare(
      `
      SELECT 1 FROM message_reactions
      WHERE message_id = ? AND user_id = ? AND emoji = ?
    `,
    )
    .get(messageId, userId, clean);

  if (existing) {
    db.prepare(
      `
      DELETE FROM message_reactions
      WHERE message_id = ? AND user_id = ? AND emoji = ?
    `,
    ).run(messageId, userId, clean);
  } else {
    // One reaction emoji per user per message — replace previous.
    db.prepare(
      'DELETE FROM message_reactions WHERE message_id = ? AND user_id = ?',
    ).run(messageId, userId);
    db.prepare(
      `
      INSERT INTO message_reactions (message_id, user_id, emoji)
      VALUES (?, ?, ?)
    `,
    ).run(messageId, userId, clean);
  }

  return {
    conversationId: message.conversation_id,
    message: getMessage(messageId),
  };
}

export function findOrCreateDm(userA, userB) {
  const existing = db
    .prepare(
      `
      SELECT c.id FROM conversations c
      JOIN conversation_members m1 ON m1.conversation_id = c.id AND m1.user_id = ?
      JOIN conversation_members m2 ON m2.conversation_id = c.id AND m2.user_id = ?
      WHERE c.is_group = 0
      LIMIT 1
    `,
    )
    .get(userA, userB);

  if (existing) {
    // Opening a DM again should bring it back if it was hidden.
    db.prepare(
      `
      UPDATE conversation_members
      SET hidden = 0
      WHERE conversation_id = ? AND user_id = ?
    `,
    ).run(existing.id, userA);
    return existing.id;
  }

  const id = uuid();
  db.prepare('INSERT INTO conversations (id, is_group) VALUES (?, 0)').run(id);
  const add = db.prepare(
    'INSERT INTO conversation_members (conversation_id, user_id) VALUES (?, ?)',
  );
  add.run(id, userA);
  add.run(id, userB);
  return id;
}

export function createGroup({ title, creatorId, memberIds }) {
  const unique = [...new Set([creatorId, ...memberIds])].filter(Boolean);
  if (unique.length < 2) {
    throw new Error('Group needs at least one other member');
  }
  const cleanTitle = String(title || '').trim() || 'Group chat';
  const id = uuid();
  const tx = db.transaction(() => {
    db.prepare(
      'INSERT INTO conversations (id, is_group, title, owner_id) VALUES (?, 1, ?, ?)',
    ).run(id, cleanTitle, creatorId);
    const add = db.prepare(
      'INSERT INTO conversation_members (conversation_id, user_id) VALUES (?, ?)',
    );
    for (const uid of unique) add.run(id, uid);
  });
  tx();
  return id;
}

export function listMembers(conversationId) {
  return db
    .prepare(
      `
      SELECT u.*, cm.last_read_at, cm.last_read_message_id
      FROM conversation_members cm
      JOIN users u ON u.id = cm.user_id
      WHERE cm.conversation_id = ?
      ORDER BY u.display_name COLLATE NOCASE
    `,
    )
    .all(conversationId)
    .map((row) => ({
      ...publicUser(row),
      lastReadAt: row.last_read_at || null,
      lastReadMessageId: row.last_read_message_id || null,
    }));
}

export function getConversationMeta(conversationId) {
  const row = db
    .prepare(
      'SELECT id, is_group, title, owner_id FROM conversations WHERE id = ?',
    )
    .get(conversationId);
  if (!row) return null;
  return {
    id: row.id,
    isGroup: !!row.is_group,
    title: row.title,
    ownerId: row.owner_id || null,
  };
}

export function addGroupMember(conversationId, userId) {
  const meta = getConversationMeta(conversationId);
  if (!meta?.isGroup) throw new Error('Not a group chat');
  if (!getUserById(userId)) throw new Error('User not found');
  if (userInConversation(conversationId, userId)) {
    throw new Error('Already in this group');
  }
  db.prepare(
    'INSERT INTO conversation_members (conversation_id, user_id) VALUES (?, ?)',
  ).run(conversationId, userId);
  return listMembers(conversationId);
}

export function removeGroupMember(conversationId, userId) {
  const meta = getConversationMeta(conversationId);
  if (!meta?.isGroup) throw new Error('Not a group chat');
  if (!userInConversation(conversationId, userId)) {
    throw new Error('User is not in this group');
  }
  const tx = db.transaction(() => {
    db.prepare(
      'DELETE FROM conversation_members WHERE conversation_id = ? AND user_id = ?',
    ).run(conversationId, userId);
    if (meta.ownerId === userId) {
      const next = db
        .prepare(
          `
          SELECT user_id FROM conversation_members
          WHERE conversation_id = ?
          ORDER BY joined_at ASC
          LIMIT 1
        `,
        )
        .get(conversationId);
      if (next) {
        db.prepare(
          'UPDATE conversations SET owner_id = ? WHERE id = ?',
        ).run(next.user_id, conversationId);
      }
    }
    // Empty group — drop the conversation entirely.
    const left = db
      .prepare(
        'SELECT COUNT(*) AS n FROM conversation_members WHERE conversation_id = ?',
      )
      .get(conversationId).n;
    if (left === 0) {
      db.prepare('DELETE FROM conversations WHERE id = ?').run(conversationId);
    }
  });
  tx();
  if (!getConversationMeta(conversationId)) {
    return [];
  }
  return listMembers(conversationId);
}

export function deleteGroup(conversationId, requesterId) {
  const meta = getConversationMeta(conversationId);
  if (!meta?.isGroup) throw new Error('Not a group chat');
  if (meta.ownerId !== requesterId) {
    throw new Error('Only the group owner can remove this group');
  }
  if (!userInConversation(conversationId, requesterId)) {
    throw new Error('forbidden');
  }
  const before = memberIds(conversationId);
  db.prepare('DELETE FROM conversations WHERE id = ?').run(conversationId);
  return before;
}

export function hideConversation(conversationId, userId) {
  if (!userInConversation(conversationId, userId)) {
    throw new Error('forbidden');
  }
  db.prepare(
    `
    UPDATE conversation_members
    SET hidden = 1
    WHERE conversation_id = ? AND user_id = ?
  `,
  ).run(conversationId, userId);
}

export function setConversationMuted(conversationId, userId, muted) {
  if (!userInConversation(conversationId, userId)) {
    throw new Error('forbidden');
  }
  db.prepare(
    `
    UPDATE conversation_members
    SET muted = ?
    WHERE conversation_id = ? AND user_id = ?
  `,
  ).run(muted ? 1 : 0, conversationId, userId);
  return { muted: !!muted };
}

export function setConversationPinned(conversationId, userId, pinned) {
  if (!userInConversation(conversationId, userId)) {
    throw new Error('forbidden');
  }
  const pinnedAt = pinned ? nowSql() : null;
  db.prepare(
    `
    UPDATE conversation_members
    SET pinned = ?, pinned_at = ?
    WHERE conversation_id = ? AND user_id = ?
  `,
  ).run(pinned ? 1 : 0, pinnedAt, conversationId, userId);
  return { pinned: !!pinned, pinnedAt };
}

export function markConversationRead(conversationId, userId, messageId = null) {
  if (!userInConversation(conversationId, userId)) {
    throw new Error('forbidden');
  }

  let target = null;
  if (messageId) {
    target = db
      .prepare(
        `
        SELECT id, created_at FROM messages
        WHERE id = ? AND conversation_id = ?
      `,
      )
      .get(messageId, conversationId);
  }
  if (!target) {
    target = db
      .prepare(
        `
        SELECT id, created_at FROM messages
        WHERE conversation_id = ?
        ORDER BY created_at DESC
        LIMIT 1
      `,
      )
      .get(conversationId);
  }

  const readAt = target?.created_at || nowSql();
  const readId = target?.id || null;
  db.prepare(
    `
    UPDATE conversation_members
    SET last_read_message_id = ?, last_read_at = ?
    WHERE conversation_id = ? AND user_id = ?
  `,
  ).run(readId, readAt, conversationId, userId);

  return {
    conversationId,
    userId,
    lastReadMessageId: readId,
    lastReadAt: readAt,
  };
}

const MEDIA_EDITABLE_KINDS = new Set([
  'text',
  'image',
  'video',
  'audio',
  'file',
  'album',
]);

export function editMessage({ messageId, userId, body }) {
  const text = String(body || '').trim();
  if (!text) throw new Error('empty body');

  const row = db
    .prepare('SELECT * FROM messages WHERE id = ?')
    .get(messageId);
  if (!row) throw new Error('message not found');
  if (row.sender_id !== userId) throw new Error('forbidden');
  if (row.deleted_at) throw new Error('message deleted');
  // Allow editing text messages and captions on media.
  if (!MEDIA_EDITABLE_KINDS.has(row.kind)) {
    throw new Error('cannot edit this message type');
  }

  const editedAt = nowSql();
  db.prepare(
    `
    UPDATE messages
    SET body = ?, edited_at = ?
    WHERE id = ?
  `,
  ).run(text, editedAt, messageId);

  return getMessage(messageId);
}

export function softDeleteMessage({ messageId, userId }) {
  const row = db
    .prepare('SELECT * FROM messages WHERE id = ?')
    .get(messageId);
  if (!row) throw new Error('message not found');
  if (row.sender_id !== userId) throw new Error('forbidden');
  if (row.deleted_at) return getMessage(messageId);

  const deletedAt = nowSql();
  db.prepare(
    `
    UPDATE messages
    SET deleted_at = ?,
        body = '',
        media_url = NULL,
        mime_type = NULL,
        file_name = NULL,
        file_size = NULL,
        attachments = NULL,
        link_preview = NULL,
        forwarded_from_id = NULL,
        forwarded_from_name = NULL,
        forwarded_from_handle = NULL,
        kind = 'deleted'
    WHERE id = ?
  `,
  ).run(deletedAt, messageId);

  db.prepare('DELETE FROM message_reactions WHERE message_id = ?').run(
    messageId,
  );

  return getMessage(messageId);
}

export function isConversationMuted(conversationId, userId) {
  return !!memberState(conversationId, userId).muted;
}

export function searchMessagesInConversation(
  conversationId,
  query,
  { limit = 50 } = {},
) {
  const q = String(query || '').trim();
  if (q.length < 1) return [];
  const lim = Math.min(Math.max(Number(limit) || 50, 1), 100);
  const like = `%${q.replace(/[%_]/g, '')}%`;
  const rows = db
    .prepare(
      `
      SELECT m.*, u.display_name AS sender_name, u.handle AS sender_handle,
             u.avatar_hue, u.avatar_url AS sender_avatar_url
      FROM messages m
      JOIN users u ON u.id = m.sender_id
      WHERE m.conversation_id = ?
        AND m.deleted_at IS NULL
        AND (
          m.body LIKE ? COLLATE NOCASE
          OR IFNULL(m.file_name, '') LIKE ? COLLATE NOCASE
        )
      ORDER BY m.created_at DESC
      LIMIT ?
    `,
    )
    .all(conversationId, like, like, lim);
  return rows.map(hydrateMessage);
}

export function searchAll(userId, query, { limit = 40 } = {}) {
  const q = String(query || '').trim();
  if (q.length < 1) {
    return { chats: [], people: [], messages: [], media: [] };
  }
  const lim = Math.min(Math.max(Number(limit) || 40, 1), 80);
  const like = `%${q.replace(/[%_]/g, '')}%`;
  const byId = new Map();

  const nameRows = db
    .prepare(
      `
      SELECT c.id AS conversation_id, c.is_group, c.title,
             peer.display_name AS peer_name,
             peer.handle AS peer_handle,
             peer.avatar_hue AS peer_avatar_hue,
             peer.avatar_url AS peer_avatar_url
      FROM conversations c
      JOIN conversation_members cm
        ON cm.conversation_id = c.id AND cm.user_id = ?
      LEFT JOIN conversation_members cm2
        ON cm2.conversation_id = c.id AND cm2.user_id != ? AND c.is_group = 0
      LEFT JOIN users peer ON peer.id = cm2.user_id
      WHERE IFNULL(cm.hidden, 0) = 0
        AND (
          IFNULL(c.title, '') LIKE ? COLLATE NOCASE
          OR IFNULL(peer.display_name, '') LIKE ? COLLATE NOCASE
          OR IFNULL(peer.handle, '') LIKE ? COLLATE NOCASE
        )
      ORDER BY c.created_at DESC
      LIMIT ?
    `,
    )
    .all(userId, userId, like, like, like, lim);

  for (const row of nameRows) {
    const title =
      row.title ||
      row.peer_name ||
      (row.peer_handle ? `@${row.peer_handle}` : null) ||
      'Chat';
    byId.set(row.conversation_id, {
      conversationId: row.conversation_id,
      title,
      isGroup: !!row.is_group,
      snippet: null,
      avatarHue: row.is_group ? 90 : (row.peer_avatar_hue ?? 160),
      avatarUrl: row.is_group ? null : row.peer_avatar_url || null,
      peerHandle: row.peer_handle || null,
      _rank: 0,
    });
  }

  const messageRows = db
    .prepare(
      `
      SELECT m.body, m.file_name, m.kind, m.created_at,
             c.id AS conversation_id, c.is_group, c.title AS conversation_title,
             peer.display_name AS peer_name,
             peer.handle AS peer_handle,
             peer.avatar_hue AS peer_avatar_hue,
             peer.avatar_url AS peer_avatar_url
      FROM messages m
      JOIN conversations c ON c.id = m.conversation_id
      JOIN conversation_members cm
        ON cm.conversation_id = m.conversation_id AND cm.user_id = ?
      LEFT JOIN conversation_members cm2
        ON cm2.conversation_id = c.id AND cm2.user_id != ? AND c.is_group = 0
      LEFT JOIN users peer ON peer.id = cm2.user_id
      WHERE m.deleted_at IS NULL
        AND IFNULL(cm.hidden, 0) = 0
        AND (
          m.body LIKE ? COLLATE NOCASE
          OR IFNULL(m.file_name, '') LIKE ? COLLATE NOCASE
        )
      ORDER BY m.created_at DESC
      LIMIT ?
    `,
    )
    .all(userId, userId, like, like, lim * 3);

  for (const row of messageRows) {
    const snippet =
      (row.body && String(row.body).trim()) ||
      row.file_name ||
      row.kind ||
      '';
    const existing = byId.get(row.conversation_id);
    if (existing) {
      if (!existing.snippet) existing.snippet = snippet;
      continue;
    }
    const title =
      row.conversation_title ||
      row.peer_name ||
      (row.peer_handle ? `@${row.peer_handle}` : null) ||
      'Chat';
    byId.set(row.conversation_id, {
      conversationId: row.conversation_id,
      title,
      isGroup: !!row.is_group,
      snippet,
      avatarHue: row.is_group ? 90 : (row.peer_avatar_hue ?? 160),
      avatarUrl: row.is_group ? null : row.peer_avatar_url || null,
      peerHandle: row.peer_handle || null,
      _rank: 1,
    });
  }

  const chats = [...byId.values()]
    .sort((a, b) => a._rank - b._rank)
    .slice(0, lim)
    .map(({ _rank, ...hit }) => hit);

  const needle = q.replace(/[%_]/g, '').toLowerCase();
  const people = listUsersExcept(userId)
    .map((u) => {
      const handle = String(u.handle || '').toLowerCase();
      const name = String(u.displayName || '').toLowerCase();
      let score = 99;
      if (handle === needle) score = 0;
      else if (handle.startsWith(needle)) score = 1;
      else if (name.startsWith(needle)) score = 2;
      else if (handle.includes(needle)) score = 3;
      else if (name.includes(needle)) score = 4;
      else {
        for (const part of name.split(/[\s_\-]+/)) {
          if (part.startsWith(needle)) {
            score = 2;
            break;
          }
          if (part.includes(needle)) score = Math.min(score, 4);
        }
      }
      return score < 99 ? { user: u, score } : null;
    })
    .filter(Boolean)
    .sort((a, b) => a.score - b.score || String(a.user.displayName).localeCompare(String(b.user.displayName)))
    .slice(0, Math.min(20, lim))
    .map((row) => row.user);

  return { chats, people, messages: [], media: [] };
}

/** Delete/leave depending on chat type and role. Returns affected user ids. */
export function deleteConversation(conversationId, userId) {
  const meta = getConversationMeta(conversationId);
  if (!meta) throw new Error('Conversation not found');
  if (!userInConversation(conversationId, userId)) {
    throw new Error('forbidden');
  }

  if (meta.isGroup) {
    if (meta.ownerId === userId) {
      return { mode: 'deleted', userIds: deleteGroup(conversationId, userId) };
    }
    const before = memberIds(conversationId);
    removeGroupMember(conversationId, userId);
    return { mode: 'left', userIds: before, leftUserId: userId };
  }

  // DM: remove for everyone so both sides drop the chat.
  const before = memberIds(conversationId);
  db.prepare('DELETE FROM conversations WHERE id = ?').run(conversationId);
  return { mode: 'deleted', userIds: before };
}

export function memberIds(conversationId) {
  return db
    .prepare('SELECT user_id FROM conversation_members WHERE conversation_id = ?')
    .all(conversationId)
    .map((r) => r.user_id);
}
