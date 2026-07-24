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
 * @param {{ apiKey?: string, model?: string, baseUrl?: string }} [opts]
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

  const res = await fetch(`${base}/chat/completions`, {
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
          content:
            'You are Privet AI, a private messenger assistant. Be concise.',
        },
        { role: 'user', content: prompt },
      ],
      temperature: 0.4,
      max_tokens: 1024,
    }),
  });

  const raw = await res.text();
  if (!res.ok) {
    const err = new Error(`AI provider ${res.status}: ${raw.slice(0, 280)}`);
    err.status = res.status;
    throw err;
  }

  let json;
  try {
    json = JSON.parse(raw);
  } catch {
    throw new Error('AI provider returned invalid JSON');
  }

  const text = json?.choices?.[0]?.message?.content;
  if (!text?.trim()) {
    throw new Error('AI provider returned empty text');
  }
  return text.trim();
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
