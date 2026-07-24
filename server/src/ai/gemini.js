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
 * @param {{ apiKey?: string, model?: string }} [opts]
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
  let lastError;

  for (const [i, apiKey] of keys.entries()) {
    for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt += 1) {
      try {
        return await callGemini({ apiKey, model, prompt });
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

async function callGemini({ apiKey, model, prompt }) {
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent?key=${encodeURIComponent(apiKey)}`;
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      contents: [{ role: 'user', parts: [{ text: prompt }] }],
      generationConfig: {
        temperature: 0.4,
        maxOutputTokens: 1024,
      },
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

  const text = json?.candidates?.[0]?.content?.parts?.[0]?.text;
  if (!text?.trim()) {
    throw new Error('Gemini returned empty text');
  }
  return text.trim();
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
