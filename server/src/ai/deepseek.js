/**
 * DeepSeek-named shim — prefer openai_compat.js.
 * Kept so older imports keep working.
 */
export {
  generateOpenAiCompatText as generateDeepSeekText,
  hasOpenAiCompat as hasDeepSeek,
  generateOpenAiCompatText,
  hasOpenAiCompat,
  normalizeCompatBaseUrl,
} from './openai_compat.js';
