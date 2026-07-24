import {
  generateOpenAiCompatText,
  hasOpenAiCompat,
} from './openai_compat.js';
import { generateGeminiText, loadGeminiApiKeys } from './gemini.js';

/**
 * Gemini keys look like AIza…; everything else is OpenAI-compatible
 * (OpenAI, DeepSeek, Groq, OpenRouter, local servers, …) and needs a base URL.
 * @param {string} key
 * @returns {'gemini' | 'openai'}
 */
export function detectAiProvider(key) {
  const k = String(key || '').trim();
  if (k.startsWith('AIza')) return 'gemini';
  return 'openai';
}

function serverCompatModel() {
  return (
    process.env.OPENAI_COMPAT_MODEL?.trim() ||
    process.env.DEEPSEEK_MODEL?.trim() ||
    'deepseek-v4-flash'
  );
}

/** Server env AI availability (no secrets). */
export function serverAiStatus() {
  const openai = hasOpenAiCompat();
  const gemini = loadGeminiApiKeys().length > 0;
  const prefer = (process.env.PRIVET_AI_PROVIDER || 'auto').toLowerCase();
  let activeProvider = null;
  // deepseek / openai both mean the OpenAI-compatible server path
  const preferCompat =
    prefer === 'deepseek' || prefer === 'openai' || prefer === 'openai_compat';
  if (preferCompat && openai) activeProvider = 'openai';
  else if (prefer === 'gemini' && gemini) activeProvider = 'gemini';
  else if (prefer === 'auto' || !prefer) {
    if (openai) activeProvider = 'openai';
    else if (gemini) activeProvider = 'gemini';
  } else if (openai) activeProvider = 'openai';
  else if (gemini) activeProvider = 'gemini';

  return {
    // Legacy field names kept for older clients
    deepseek: openai,
    openai,
    gemini,
    configured: openai || gemini,
    activeProvider,
    deepseekModel: serverCompatModel(),
    openaiModel: serverCompatModel(),
    geminiModel: process.env.GEMINI_MODEL?.trim() || 'gemini-2.5-flash-lite',
    defaultCompatBaseUrl:
      process.env.OPENAI_COMPAT_BASE_URL?.trim() ||
      process.env.DEEPSEEK_BASE_URL?.trim() ||
      'https://api.deepseek.com',
  };
}

/**
 * Prefer a user-supplied key when present; otherwise OpenAI-compat env then Gemini.
 * @param {string} prompt
 * @param {{ apiKey?: string | null, model?: string | null, baseUrl?: string | null }} [opts]
 * @returns {Promise<{ text: string, provider: string, model: string }>}
 */
export async function generateText(prompt, opts = {}) {
  const userKey = opts.apiKey?.trim() || '';
  const modelOverride = opts.model?.trim() || '';
  const baseUrl = opts.baseUrl?.trim() || '';

  if (userKey) {
    const provider = detectAiProvider(userKey);
    if (provider === 'gemini') {
      const model =
        modelOverride ||
        process.env.GEMINI_MODEL?.trim() ||
        'gemini-2.5-flash-lite';
      const text = await generateGeminiText(prompt, {
        apiKey: userKey,
        model,
      });
      return { text, provider: 'gemini', model };
    }
    if (!modelOverride) {
      throw new Error('Model id is required for OpenAI-compatible providers');
    }
    if (!baseUrl) {
      throw new Error(
        'Base URL is required for OpenAI-compatible providers (e.g. https://api.openai.com/v1 or https://api.deepseek.com)',
      );
    }
    const text = await generateOpenAiCompatText(prompt, {
      apiKey: userKey,
      model: modelOverride,
      baseUrl,
    });
    return { text, provider: 'openai', model: modelOverride };
  }

  const prefer = (process.env.PRIVET_AI_PROVIDER || 'auto').toLowerCase();
  const openaiOk = hasOpenAiCompat();
  const geminiOk = loadGeminiApiKeys().length > 0;
  const preferCompat =
    prefer === 'deepseek' || prefer === 'openai' || prefer === 'openai_compat';

  if (!openaiOk && !geminiOk) {
    throw new Error(
      'AI is not configured — paste an API key in Profile settings',
    );
  }

  if (preferCompat || (prefer === 'auto' && openaiOk)) {
    try {
      const model = modelOverride || serverCompatModel();
      const text = await generateOpenAiCompatText(prompt, {
        model,
        baseUrl: baseUrl || undefined,
      });
      return { text, provider: 'openai', model };
    } catch (err) {
      if (preferCompat || !geminiOk) throw err;
      console.warn(
        `[privet-ai] OpenAI-compatible provider failed (${err.message?.slice(0, 80)}); trying Gemini`,
      );
    }
  }

  if (prefer === 'gemini' || geminiOk) {
    try {
      const model =
        modelOverride ||
        process.env.GEMINI_MODEL?.trim() ||
        'gemini-2.5-flash-lite';
      const text = await generateGeminiText(prompt, { model });
      return { text, provider: 'gemini', model };
    } catch (err) {
      if (openaiOk && prefer !== 'gemini') {
        console.warn(
          `[privet-ai] Gemini failed (${err.message?.slice(0, 80)}); trying OpenAI-compatible provider`,
        );
        const model = modelOverride || serverCompatModel();
        const text = await generateOpenAiCompatText(prompt, {
          model,
          baseUrl: baseUrl || undefined,
        });
        return { text, provider: 'openai', model };
      }
      throw err;
    }
  }

  throw new Error('No AI provider available');
}
