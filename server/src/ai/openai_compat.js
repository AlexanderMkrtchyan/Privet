/**
 * OpenAI-compatible chat completions client.
 * Works with OpenAI, DeepSeek, Groq, OpenRouter, Ollama, LM Studio, etc.
 * POST {baseUrl}/chat/completions
 */

/**
 * @param {string} url
 * @returns {string}
 */
export function normalizeCompatBaseUrl(url) {
  let base = String(url || '')
    .trim()
    .replace(/\/$/, '');
  base = base.replace(/\/chat\/completions\/?$/i, '');
  return base;
}

/**
 * Default host for server-env DeepSeek / OPENAI_COMPAT_* fallbacks only.
 * User-supplied keys must pass their own baseUrl.
 */
function serverDefaultBaseUrl() {
  return normalizeCompatBaseUrl(
    process.env.OPENAI_COMPAT_BASE_URL?.trim() ||
      process.env.DEEPSEEK_BASE_URL?.trim() ||
      'https://api.deepseek.com',
  );
}

function serverDefaultModel() {
  return (
    process.env.OPENAI_COMPAT_MODEL?.trim() ||
    process.env.DEEPSEEK_MODEL?.trim() ||
    'deepseek-v4-flash'
  );
}

function serverApiKey() {
  return (
    process.env.OPENAI_COMPAT_API_KEY?.trim() ||
    process.env.DEEPSEEK_API_KEY?.trim() ||
    ''
  );
}

/**
 * @param {string} prompt
 * @param {{ apiKey?: string, model?: string, baseUrl?: string, maxTokens?: number, temperature?: number, json?: boolean, disableThinking?: boolean }} [opts]
 */
export async function generateOpenAiCompatText(prompt, opts = {}) {
  const userKey = opts.apiKey?.trim() || '';
  const apiKey = userKey || serverApiKey();
  if (!apiKey) {
    throw new Error(
      'API key is not set — paste a key in Profile settings or configure the server',
    );
  }

  const userBase = opts.baseUrl?.trim()
    ? normalizeCompatBaseUrl(opts.baseUrl)
    : '';
  // User keys must target an explicit host; only server env may use DeepSeek default.
  const base = userKey
    ? userBase
    : userBase || serverDefaultBaseUrl();
  if (!base) {
    throw new Error(
      'Base URL is required for OpenAI-compatible providers (e.g. https://api.openai.com/v1 or https://api.deepseek.com)',
    );
  }

  const model =
    opts.model?.trim() ||
    (userKey ? '' : serverDefaultModel());
  if (!model) {
    throw new Error('Model id is required');
  }

  const maxTokens = Number(opts.maxTokens) > 0 ? Number(opts.maxTokens) : 1024;
  const temperature =
    typeof opts.temperature === 'number' && Number.isFinite(opts.temperature)
      ? opts.temperature
      : 0.4;

  const systemContent = opts.json
    ? 'You are Privet AI. Reply with a single valid JSON object only — no markdown fences, no preamble.'
    : 'You are Privet AI, a private messenger assistant. Be concise.';

  const disableThinking = opts.disableThinking === true;

  const post = (jsonMode, thinkingOff) =>
    fetch(`${base}/chat/completions`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model,
        messages: [
          {
            role: 'system',
            content: systemContent,
          },
          { role: 'user', content: prompt },
        ],
        temperature,
        max_tokens: maxTokens,
        ...(jsonMode ? { response_format: { type: 'json_object' } } : {}),
        // DeepSeek V4 Flash otherwise spends max_tokens on hidden reasoning
        // and returns empty `content` ~most of the time on longer prompts.
        ...(thinkingOff ? { thinking: { type: 'disabled' } } : {}),
      }),
    });

  const tryPost = async (jsonMode, thinkingOff) => {
    const res = await post(jsonMode, thinkingOff);
    // Hosts that do not know `thinking` reject it with 400 — retry plain.
    if (thinkingOff && res.status === 400) return post(jsonMode, false);
    return res;
  };

  let res = await tryPost(!!opts.json, disableThinking);
  // Some OpenAI-compatible hosts reject response_format — the prompt still asks for JSON.
  if (opts.json && res.status === 400) res = await tryPost(false, disableThinking);

  const readBody = async (response) => {
    const raw = await response.text();
    if (!response.ok) {
      const err = new Error(`AI provider ${response.status}: ${raw.slice(0, 280)}`);
      err.status = response.status;
      throw err;
    }
    let json;
    try {
      json = JSON.parse(raw);
    } catch {
      throw new Error('AI provider returned invalid JSON');
    }
    return extractCompatMessageText(json);
  };

  let text = await readBody(res);
  // DeepSeek / some compat models occasionally return empty content on the
  // first try (especially longer prompts). One plain retry usually recovers.
  if (!text) {
    res = await post(false);
    text = await readBody(res);
  }
  if (!text) {
    throw new Error('Coach came back empty-handed — try again');
  }
  return text;
}

/**
 * Pull assistant text from OpenAI-compat chat.completions payloads.
 * Handles string content, multipart content arrays, and a few vendor quirks.
 * @param {any} json
 * @returns {string}
 */
function extractCompatMessageText(json) {
  const msg = json?.choices?.[0]?.message;
  if (!msg || typeof msg !== 'object') return '';
  const content = msg.content;
  if (typeof content === 'string' && content.trim()) return content.trim();
  if (Array.isArray(content)) {
    const joined = content
      .map((part) => {
        if (typeof part === 'string') return part;
        if (part && typeof part.text === 'string') return part.text;
        if (part && typeof part.content === 'string') return part.content;
        return '';
      })
      .join('');
    if (joined.trim()) return joined.trim();
  }
  // Rare: some gateways put the final answer in a sibling field.
  // Reasoning models often leave `content` empty and park JSON in
  // reasoning_content when the output budget ran out.
  for (const key of ['output_text', 'result', 'answer', 'reasoning_content']) {
    const v = msg[key];
    if (typeof v === 'string' && v.trim() && v.includes('{')) return v.trim();
  }
  if (Array.isArray(msg.reasoning)) {
    const joined = msg.reasoning
      .map((part) => {
        if (typeof part === 'string') return part;
        if (part && typeof part.text === 'string') return part.text;
        return '';
      })
      .join('');
    if (joined.trim() && joined.includes('{')) return joined.trim();
  }
  return '';
}

/** True when server env has an OpenAI-compatible key (DeepSeek or OPENAI_COMPAT_*). */
export function hasOpenAiCompat() {
  return !!serverApiKey();
}

/** @deprecated Use generateOpenAiCompatText / hasOpenAiCompat */
export async function generateDeepSeekText(prompt, opts = {}) {
  return generateOpenAiCompatText(prompt, opts);
}

/** @deprecated Use hasOpenAiCompat */
export function hasDeepSeek() {
  return hasOpenAiCompat();
}
