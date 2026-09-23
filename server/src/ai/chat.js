import { db } from '../db.js';
import { generateText } from './llm.js';
import {
  looksLikeTrainerCheck,
  mergeTrainerReplies,
  splitTrainerChunks,
} from './trainer_json.js';

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
  // English trainer — pre-send grammar check (text after the command line).
  if (/^english-check(\s|$)/.test(lower)) {
    return {
      type: 'english_check',
      text: rest.slice('english-check'.length).trim(),
    };
  }
  // English trainer — CEFR level review (JSON payload after the command line).
  if (/^english-level(\s|$)/.test(lower)) {
    return {
      type: 'english_level',
      payload: rest.slice('english-level'.length).trim(),
    };
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

/** @type {Map<string, number>} */
const lastTrainerCallByUser = new Map();
// Pre-send checks run on every English message, so they get a shorter gap.
const TRAINER_MIN_GAP_MS = 1200;

function assertTrainerRateLimit(userId) {
  const now = Date.now();
  const prev = lastTrainerCallByUser.get(userId) ?? 0;
  if (now - prev < TRAINER_MIN_GAP_MS) {
    throw new Error('Slow down — the coach is still catching its breath');
  }
  lastTrainerCallByUser.set(userId, now);
}

const TRAINER_ISSUE_TYPES =
  'tense | article | preposition | agreement | word_order | word_choice | spelling | plural | punctuation | capitalization | missing_word | extra_word | other';

export function englishCheckPrompt(text) {
  return `You are "Coach", a witty, warm personal English trainer inside a chat app.
The user is a non-native speaker practising English by chatting. Check the message below BEFORE they send it.

Return ONLY a compact JSON object, no markdown:
{
  "issues": [               // [] when the message is fine. Max 8.
    {
      "wrong": string,      // exact substring copied from the ORIGINAL (shortest span)
      "right": string,      // replacement for that span
      "type": string,       // one of: ${TRAINER_ISSUE_TYPES}
      "severity": "major" | "minor",
      "why": string,        // plain-English rule, max 18 words
      "example": string     // one short NEW correct sentence using the same rule
    }
  ],
  "natural": string,        // how a native speaker would actually say THIS WHOLE message — same meaning, names, and line breaks, freer wording. "" only if it already sounds native. Example: "I need your help" → "Can you give me a hand?"
  "quip": string,           // one playful coach line, max 14 words
  "cefr": "A1" | "A2" | "B1" | "B2" | "C1" | "C2"
}

Rules:
- Do NOT include a "corrected" field. The app applies your replacements to the original.
- Always fill "natural" when a native speaker would word it differently. That is polish, not an error — do not list it as an issue.
- This is casual chat. Do NOT flag: missing final period, lowercase first letter of a message, emoji, common chat shorthand (lol, btw, u, ok, pls), contractions, informal tone.
- DO flag real grammar, spelling, word choice, articles, prepositions, tenses, agreement, word order — even in casual text.
- Lowercase "i" as a pronoun is severity "minor". Spelling slips and missing commas are "minor". Anything that breaks grammar or meaning is "major".
- Never invent issues. If unsure, leave it out. Names, brands, code, URLs and non-English words are not errors.
- One issue per distinct mistake. "wrong" must appear verbatim in the original, including newlines and punctuation as written.
- No preamble, no markdown fences.

Message:
<<<
${text}
>>>`;
}

export function englishCheckRetryPrompt(text) {
  return `Return ONLY JSON. No markdown.
{"issues":[{"wrong":"exact original substring","right":"fix","type":"spelling","severity":"major","why":"short rule","example":"A correct sentence."}],"quip":"kind one-liner","cefr":"B1","natural":"how a native would say the whole message"}
If the English is already native: {"issues":[],"quip":"","cefr":"B1","natural":""}
Max 6 issues. "wrong" must be copied verbatim from the message. Always include a native rewrite when a speaker would word it differently.

Message:
<<<
${text}
>>>`;
}

export function englishLevelPrompt(payload) {
  return `You are "Coach", a witty but honest personal English trainer.
Grade the user's written English on the CEFR scale (A1, A2, B1, B2, C1, C2 — C2 means fluent / near-native) from their recent chat messages below.
Judge grammar accuracy, vocabulary range, sentence complexity, and naturalness. Casual chat style is fine — do not punish shorthand or missing periods.
Each sample shows the original text and how many mistakes the checker found. Weigh recent samples a bit more.

Return ONLY a JSON object, no markdown, with exactly these keys:
{
  "level": "A1" | "A2" | "B1" | "B2" | "C1" | "C2",
  "progress": number,          // 0–100: how far through that level they are (80+ means close to the next)
  "title": string,             // a funny 2–4 word nickname for their current style, e.g. "Article Assassin in Training"
  "verdict": string,           // 2 short sentences: honest summary with a little humour
  "strengths": [string],       // 2–3 items, each max 12 words
  "weaknesses": [string],      // 2–3 items, each max 12 words, name the concrete rule
  "nextGoal": string,          // one concrete thing to master to reach the next level, max 20 words
  "drills": [                  // exactly 3 quick exercises targeting their weaknesses
    { "prompt": string, "answer": string, "tip": string }  // prompt is a fill-in-the-gap or fix-this sentence; tip max 14 words
  ]
}

Data (JSON):
${payload}`;
}

function clampTrainerText(text, max) {
  const s = String(text || '').trim();
  return s.length > max ? s.slice(0, max) : s;
}

/** Soft cap for one pre-send check — longer replies need a bigger token budget. */
const TRAINER_CHECK_MAX_CHARS = 6000;

function trainerCheckMaxTokens(bodyLen) {
  // Issues JSON + a full native rewrite of the message.
  return Math.min(4000, 1800 + Math.ceil(bodyLen / 2));
}

function isEmptyCoachError(err) {
  const msg = String(err?.message || err).toLowerCase();
  return (
    msg.includes('empty') ||
    msg.includes('empty-handed') ||
    msg.includes('unreadable')
  );
}

async function generateTrainerCheck(body, opts) {
  const gen = async (prompt, maxTokens) => {
    try {
      return await generateText(prompt, {
        apiKey: opts.apiKey,
        model: opts.model,
        baseUrl: opts.baseUrl,
        maxTokens,
        temperature: 0.2,
        disableThinking: true,
        json: false,
      });
    } catch (err) {
      if (!isEmptyCoachError(err)) throw err;
      return { text: '', provider: 'unknown', model: '', error: err };
    }
  };

  const tokens = trainerCheckMaxTokens(body.length);
  let last = await gen(englishCheckPrompt(body), tokens);
  if (looksLikeTrainerCheck(last.text)) return last;

  last = await gen(englishCheckRetryPrompt(body), Math.max(tokens, 2000));
  if (looksLikeTrainerCheck(last.text)) return last;

  if (body.length >= 360) {
    const chunks = splitTrainerChunks(body, 700);
    if (chunks.length > 1) {
      const parts = [];
      for (const chunk of chunks) {
        const one = await gen(
          englishCheckRetryPrompt(chunk),
          trainerCheckMaxTokens(chunk.length),
        );
        if (one.provider && one.provider !== 'unknown') last = one;
        if (looksLikeTrainerCheck(one.text)) parts.push(one.text);
      }
      if (parts.length) {
        return {
          text: mergeTrainerReplies(parts),
          provider: last.provider,
          model: last.model,
        };
      }
    }
  }
  if (last.error) throw last.error;
  return last;
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

  if (parsed.type === 'english_check' || parsed.type === 'english_level') {
    assertTrainerRateLimit(userId);
    const isCheck = parsed.type === 'english_check';
    const rawBody = String(
      (isCheck ? parsed.text : parsed.payload) || '',
    ).trim();
    if (!rawBody) throw new Error('Nothing to review');
    if (isCheck && rawBody.length > TRAINER_CHECK_MAX_CHARS) {
      throw new Error(
        `Message too long for Coach (max ${TRAINER_CHECK_MAX_CHARS} characters) — shorten it or turn Coach off`,
      );
    }
    const body = isCheck
      ? rawBody
      : clampTrainerText(rawBody, 24000);
    const { text, provider, model: usedModel } = isCheck
      ? await generateTrainerCheck(body, { apiKey, model, baseUrl })
      : await generateText(englishLevelPrompt(body), {
          apiKey,
          model,
          baseUrl,
          maxTokens: 1400,
          temperature: 0.5,
          disableThinking: true,
          json: false,
        });
    return {
      text,
      meta: { kind: parsed.type, messageCount: 0, provider, model: usedModel },
    };
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
