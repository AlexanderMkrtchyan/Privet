import { db } from '../db.js';
import { generateText } from './llm.js';

const HELP_TEXT = `Privet AI

# summarize — unread (shared with chat)
# summarize 40 — last 40 messages (shared)
# <question> — ask about this chat (shared)
# greet [Name] — short English greeting draft (Name optional)
# greet-draft [Name] — short encouraging greeting from recent chat

#me summarize — private (only you)
#me <question> — private answer only for you

Enable AI in Profile & settings and add your API key.

Examples:
# what did we decide about the meeting?
#me draft a short reply
# greet Alex`;

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
  if (lower === 'greet' || lower.startsWith('greet ')) {
    const name = rest.slice(5).trim(); // after "greet"
    return { type: 'greet', name: name || null };
  }
  // Composer "AI" chip — short encouraging draft from recent chat.
  if (lower === 'greet-draft' || lower.startsWith('greet-draft ')) {
    const name = rest.slice('greet-draft'.length).trim();
    return { type: 'greet_draft', name: name || null };
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

  if (parsed.type === 'greet') {
    const name = String(parsed.name || '').trim();
    const address = name
      ? `Start with "Hi, ${name}," (use that exact first name).`
      : `Start with "Hi there," — do not use a personal name.`;
    const prompt = `You draft a short chat greeting the user will send themselves.

${address}
Then add one brief warm line: a light work nudge, a short wise quote, OR a gentle joke (pick one at random).

Rules:
- English only.
- 1–2 sentences total.
- Plain text only — no quotation marks around the whole message, no labels, no preamble like "Here is a greeting".
- Sound natural, like a human typed it.
- No "As an AI" disclaimers.`;

    const { text, provider, model: usedModel } = await generateText(prompt, {
      apiKey,
      model,
      baseUrl,
      maxTokens: 80,
      temperature: 0.7,
    });
    return {
      text,
      meta: {
        kind: 'greet',
        messageCount: 0,
        provider,
        model: usedModel,
      },
    };
  }

  if (parsed.type === 'greet_draft') {
    const name = String(parsed.name || '').trim();
    const address = name
      ? `Start with "Hi, ${name}," (that exact first name).`
      : `Start with "Hi there," — do not invent a personal name.`;
    contextLines = messagesForAiContext(conversationId, userId, {
      unreadOnly: false,
      limit: 24,
    });
    const prompt = `You are drafting a short chat message the USER will send to someone else.
The named person is the recipient — not the person being coached.

${address}
Optionally add one light, NEUTRAL line that nods at recent chat mood/topic (plans, jokes, stress, wins).

POINT OF VIEW:
- Write AS the user, TO the recipient.
- Do NOT tell the recipient what they should do, keep doing, or work on ("keep the wins rolling", "you've got this on X", "don't forget to…").
- Do NOT assign tasks or pep-talk the recipient about their progress.
- Prefer a shared/neutral vibe ("nice to see the FAQs sorted") or a brief note about the sender's own situation if that fits — never a coach talking down to the addressee.

HARD RULES:
- English only.
- At most 2 short sentences total (~25 words). One sentence after Hi is ideal.
- Output ONLY the greeting text — no quotes around it, no preamble, no markdown, no bullets.
- Do not volunteer product names for coding tools or assistants (Cursor, VS Code, ChatGPT, Claude, Copilot, etc.).
- No poems, essays, speeches, or long pep talks.
- Do not invent private facts that are not in the chat.

Recent chat (${contextLines.length} lines):
${contextLines.length ? contextLines.join('\n') : '(empty — keep a simple warm hi)'}`;

    // Gemini 2.5 thinking can eat a tiny maxOutputTokens budget and return
    // empty text — keep headroom and disable thinking for this short draft.
    const { text, provider, model: usedModel } = await generateText(prompt, {
      apiKey,
      model,
      baseUrl,
      maxTokens: 512,
      temperature: 0.75,
      disableThinking: true,
    });
    return {
      text,
      meta: {
        kind: 'greet_draft',
        messageCount: contextLines.length,
        provider,
        model: usedModel,
      },
    };
  }

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
