const RETRYABLE = new Set([500, 502, 503, 504]);
const MAX_ATTEMPTS = 3;

export function loadGeminiApiKeys() {
  const multi = process.env.GEMINI_API_KEYS;
  if (multi) {
    return multi
      .split(',')
      .map((k) => k.trim())
      .filter(Boolean);
  }
  const single = process.env.GEMINI_API_KEY?.trim();
  return single ? [single] : [];
}

/**
 * @param {string} prompt
 * @param {{ apiKey?: string, model?: string, maxTokens?: number, temperature?: number, disableThinking?: boolean }} [opts]
 * @returns {Promise<string>}
 */
export async function generateGeminiText(prompt, opts = {}) {
  const override = opts.apiKey?.trim();
  const keys = override ? [override] : loadGeminiApiKeys();
  if (keys.length === 0) {
    throw new Error('AI is not configured (set GEMINI_API_KEY on the server)');
  }

  const model =
    opts.model?.trim() ||
    process.env.GEMINI_MODEL?.trim() ||
    'gemini-2.5-flash-lite';
  const maxTokens = Number(opts.maxTokens) > 0 ? Number(opts.maxTokens) : 1024;
  const temperature =
    typeof opts.temperature === 'number' && Number.isFinite(opts.temperature)
      ? opts.temperature
      : 0.4;
  const disableThinking = opts.disableThinking === true;
  let lastError;

  for (const [i, apiKey] of keys.entries()) {
    for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt += 1) {
      try {
        return await callGemini({
          apiKey,
          model,
          prompt,
          maxTokens,
          temperature,
          disableThinking,
        });
      } catch (err) {
        lastError = err;
        const status = err.status ?? null;
        if (status === 429) break;
        if (!status || !RETRYABLE.has(status) || attempt === MAX_ATTEMPTS) {
          break;
        }
        await sleep(Math.min(2 ** attempt * 500, 8000));
      }
    }
    if (i < keys.length - 1 && lastError?.status === 429) continue;
  }

  throw lastError ?? new Error('Gemini request failed');
}

async function callGemini({
  apiKey,
  model,
  prompt,
  maxTokens,
  temperature,
  disableThinking,
}) {
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent?key=${encodeURIComponent(apiKey)}`;
  const generationConfig = {
    temperature,
    maxOutputTokens: maxTokens,
  };
  // Gemini 2.5* may spend the whole output budget on "thinking" and return
  // empty visible text when maxOutputTokens is small.
  if (disableThinking) {
    generationConfig.thinkingConfig = { thinkingBudget: 0 };
  }
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      contents: [{ role: 'user', parts: [{ text: prompt }] }],
      generationConfig,
    }),
  });

  const raw = await res.text();
  if (!res.ok) {
    const err = new Error(
      `Gemini ${res.status}: ${raw.slice(0, 280)}`,
    );
    err.status = res.status;
    throw err;
  }

  let json;
  try {
    json = JSON.parse(raw);
  } catch {
    throw new Error('Gemini returned invalid JSON');
  }

  const candidate = json?.candidates?.[0];
  const parts = candidate?.content?.parts;
  let text = '';
  if (Array.isArray(parts)) {
    text = parts
      .filter((p) => p && !p.thought && typeof p.text === 'string')
      .map((p) => p.text)
      .join('')
      .trim();
    if (!text) {
      text = parts
        .filter((p) => p && typeof p.text === 'string')
        .map((p) => p.text)
        .join('')
        .trim();
    }
  } else if (typeof parts?.[0]?.text === 'string') {
    text = parts[0].text.trim();
  }
  if (!text) {
    const reason = candidate?.finishReason || json?.promptFeedback?.blockReason || 'unknown';
    throw new Error(`Gemini returned empty text (${reason})`);
  }
  return text;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
