import { db } from '../db.js';
import { generateText } from './llm.js';

const HELP_TEXT = `Privet AI

# summarize — unread (shared with chat)
# summarize 40 — last 40 messages (shared)
# <question> — ask about this chat (shared)

#me summarize — private (only you)
#me <question> — private answer only for you

Enable AI in Profile & settings and add your API key.

Examples:
# what did we decide about the meeting?
#me draft a short reply`;

/** @type {Map<string, number>} */
const lastCallByUser = new Map();
const MIN_GAP_MS = 4000;

export function aiHelpText() {
  return HELP_TEXT;
}

/**
 * @param {string} input — full line including leading #
 */
export function parseAiInput(input) {
  const raw = String(input || '').trim();
  if (!raw.startsWith('#')) return null;
  let rest = raw.slice(1).trim();
  // Client normally strips #me; accept it here too.
  rest = rest.replace(/^me\b\s*/i, '').trim();
  if (!rest) return { type: 'help' };
  const lower = rest.toLowerCase();
  if (lower === 'help' || lower === '?') return { type: 'help' };
  if (
    lower === 'summarize' ||
    lower === 'summarize unread' ||
    lower.startsWith('summarize unread')
  ) {
    return { type: 'summarize_unread' };
  }
  const recent = lower.match(/^summarize\s+(\d+)\s*$/);
  if (recent) {
    const n = Math.min(Math.max(parseInt(recent[1], 10) || 40, 5), 120);
    return { type: 'summarize_recent', limit: n };
  }
  return { type: 'ask', question: rest };
}

/**
 * @param {string} conversationId
 * @param {string} userId
 * @param {{ unreadOnly?: boolean, limit?: number, since?: string | null }} opts
 */
export function messagesForAiContext(conversationId, userId, opts = {}) {
  const { unreadOnly = false, limit = 80, since = null } = opts;
  const lim = Math.min(Math.max(Number(limit) || 80, 1), 120);

  let lastReadAt = since ? normalizeSince(since) : null;
  if (unreadOnly && !lastReadAt) {
    const member = db
      .prepare(
        `
      SELECT last_read_at AS lastReadAt
      FROM conversation_members
      WHERE conversation_id = ? AND user_id = ?
    `,
      )
      .get(conversationId, userId);
    lastReadAt = member?.lastReadAt || null;
  }

  let rows;
  if (unreadOnly) {
    if (lastReadAt) {
      rows = db
        .prepare(
          `
          SELECT m.body, m.kind, m.created_at AS createdAt,
                 u.display_name AS senderName, u.handle AS senderHandle
          FROM messages m
          JOIN users u ON u.id = m.sender_id
          WHERE m.conversation_id = ?
            AND m.deleted_at IS NULL
            AND m.sender_id != ?
            AND m.created_at > ?
          ORDER BY m.created_at ASC
          LIMIT ?
        `,
        )
        .all(conversationId, userId, lastReadAt, lim);
    } else {
      rows = db
        .prepare(
          `
          SELECT m.body, m.kind, m.created_at AS createdAt,
                 u.display_name AS senderName, u.handle AS senderHandle
          FROM messages m
          JOIN users u ON u.id = m.sender_id
          WHERE m.conversation_id = ?
            AND m.deleted_at IS NULL
            AND m.sender_id != ?
          ORDER BY m.created_at ASC
          LIMIT ?
        `,
        )
        .all(conversationId, userId, lim);
    }
  } else {
    rows = db
      .prepare(
        `
        SELECT m.body, m.kind, m.created_at AS createdAt,
               u.display_name AS senderName, u.handle AS senderHandle
        FROM messages m
        JOIN users u ON u.id = m.sender_id
        WHERE m.conversation_id = ?
          AND m.deleted_at IS NULL
        ORDER BY m.created_at DESC
        LIMIT ?
      `,
      )
      .all(conversationId, lim);
    rows.reverse();
  }

  return rows.map(formatLineForPrompt).filter(Boolean);
}

function normalizeSince(since) {
  if (!since) return null;
  return String(since).trim().replace('T', ' ').slice(0, 19);
}

function formatLineForPrompt(row) {
  const who =
    row.senderHandle?.trim()
      ? `@${row.senderHandle}`
      : row.senderName || 'Someone';
  let body = String(row.body || '').trim();
  if (!body || row.kind !== 'text') {
    const label =
      row.kind === 'image'
        ? '[photo]'
        : row.kind === 'video'
          ? '[video]'
          : row.kind === 'voice'
            ? '[voice]'
            : row.kind === 'audio'
              ? '[audio]'
              : row.kind === 'file' || row.kind === 'album'
                ? '[attachment]'
                : '';
    body = body || label;
  }
  if (!body) return null;
  const ts = String(row.createdAt || '').slice(0, 16);
  return `[${ts}] ${who}: ${body}`;
}

function assertRateLimit(userId) {
  const now = Date.now();
  const prev = lastCallByUser.get(userId) ?? 0;
  if (now - prev < MIN_GAP_MS) {
    throw new Error('Slow down — wait a few seconds between AI requests');
  }
  lastCallByUser.set(userId, now);
}

/**
 * @param {{ conversationId: string, userId: string, input: string, since?: string | null, apiKey?: string | null, model?: string | null, baseUrl?: string | null }} params
 */
export async function runPrivetAi({
  conversationId,
  userId,
  input,
  since = null,
  apiKey = null,
  model = null,
  baseUrl = null,
}) {
  const parsed = parseAiInput(input);
  if (!parsed) {
    throw new Error('Use a # command (try # help)');
  }
  if (parsed.type === 'help') {
    return { text: HELP_TEXT, meta: { kind: 'help' } };
  }

  assertRateLimit(userId);

  let contextLines;
  let userTask;

  if (parsed.type === 'summarize_unread') {
    contextLines = messagesForAiContext(conversationId, userId, {
      unreadOnly: true,
      limit: 100,
      since,
    });
    if (contextLines.length === 0) {
      return {
        text: 'Nothing unread in this chat — you are caught up.',
        meta: { kind: 'summarize_unread', messageCount: 0 },
      };
    }
    userTask =
      'Summarize the unread messages below for the reader. Use short bullet points. Mention who said what when it matters. If there are action items, list them at the end.';
  } else if (parsed.type === 'summarize_recent') {
    contextLines = messagesForAiContext(conversationId, userId, {
      unreadOnly: false,
      limit: parsed.limit,
    });
    if (contextLines.length === 0) {
      return {
        text: 'No messages in this chat yet.',
        meta: { kind: 'summarize_recent', messageCount: 0 },
      };
    }
    userTask = `Summarize the last ${contextLines.length} messages. Use short bullet points.`;
  } else {
    contextLines = messagesForAiContext(conversationId, userId, {
      unreadOnly: false,
      limit: 60,
    });
    userTask = `Answer the user's question using the chat context when helpful. Be concise.\n\nQuestion: ${parsed.question}`;
  }

  const prompt = `You are Privet AI, a private assistant inside a messenger app. Replies are shown only to the user who asked.

Rules:
- Be concise and practical (under ~180 words unless summarizing a long thread).
- Do not invent messages that are not in the context.
- No "As an AI" disclaimers.

${userTask}

Chat context (${contextLines.length} lines):
${contextLines.join('\n')}`;

  const { text, provider, model: usedModel } = await generateText(prompt, {
    apiKey,
    model,
    baseUrl,
  });
  return {
    text,
    meta: {
      kind: parsed.type,
      messageCount: contextLines.length,
      provider,
      model: usedModel,
    },
  };
}
