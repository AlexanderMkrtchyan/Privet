/**
 * Recover a coach JSON object from a (possibly truncated) model reply.
 * Mirrors app/lib/util/english_trainer.dart decodeTrainerJson.
 */

export function stripTrainerFence(raw) {
  let s = String(raw || '').trim();
  if (s.startsWith('```')) {
    s = s.replace(/^```(?:json|JSON)?\s*/, '');
    const close = s.lastIndexOf('```');
    if (close >= 0) s = s.slice(0, close);
    s = s.trim();
  }
  return s;
}

export function repairTruncatedJson(raw) {
  const stack = [];
  let inString = false;
  let escape = false;
  for (let i = 0; i < raw.length; i += 1) {
    const c = raw[i];
    if (inString) {
      if (escape) {
        escape = false;
        continue;
      }
      if (c === '\\') {
        escape = true;
        continue;
      }
      if (c === '"') inString = false;
      continue;
    }
    if (c === '"') {
      inString = true;
      continue;
    }
    if (c === '{' || c === '[') stack.push(c);
    else if (c === '}' || c === ']') {
      const open = stack[stack.length - 1];
      if ((c === '}' && open === '{') || (c === ']' && open === '[')) {
        stack.pop();
      }
    }
  }

  let out = raw;
  if (inString) {
    if (escape) out = out.slice(0, -1);
    out += '"';
  }
  const stripComma = (s) => s.replace(/,\s*$/, '');
  out = stripComma(out);
  while (stack.length) {
    out = stripComma(out);
    out += stack.pop() === '{' ? '}' : ']';
  }
  return out;
}

function asTrainerMap(raw) {
  try {
    const decoded = JSON.parse(raw);
    if (decoded && typeof decoded === 'object' && !Array.isArray(decoded)) {
      return decoded;
    }
    if (Array.isArray(decoded)) {
      return { issues: decoded, corrected: '' };
    }
    return null;
  } catch {
    return null;
  }
}

export function decodeTrainerJson(raw) {
  const s = stripTrainerFence(raw);
  if (!s) return null;
  const objectAt = s.indexOf('{');
  const arrayAt = s.indexOf('[');
  if (objectAt < 0 && arrayAt < 0) return null;

  if (objectAt >= 0 && (arrayAt < 0 || objectAt < arrayAt)) {
    const end = s.lastIndexOf('}');
    if (end > objectAt) {
      const parsed = asTrainerMap(s.slice(objectAt, end + 1));
      if (parsed) return parsed;
    }
    return asTrainerMap(repairTruncatedJson(s.slice(objectAt)));
  }

  const end = s.lastIndexOf(']');
  if (end > arrayAt) {
    const parsed = asTrainerMap(s.slice(arrayAt, end + 1));
    if (parsed) return parsed;
  }
  return asTrainerMap(repairTruncatedJson(s.slice(arrayAt)));
}

/** True when the reply has enough shape for the client to show a check. */
export function looksLikeTrainerCheck(raw) {
  const map = decodeTrainerJson(raw);
  if (!map) return false;
  return Array.isArray(map.issues) || typeof map.corrected === 'string';
}

/** Split a long chat message so each piece stays cheap for the model. */
export function splitTrainerChunks(text, max = 700) {
  const trimmed = String(text || '').trim();
  if (!trimmed) return [];
  if (trimmed.length <= max) return [trimmed];

  const paras = trimmed.split(/\n{2,}/).map((p) => p.trim()).filter(Boolean);
  const chunks = [];
  let buf = '';
  const flush = () => {
    if (buf) {
      chunks.push(buf);
      buf = '';
    }
  };
  const append = (piece) => {
    if (!piece) return;
    const next = buf ? `${buf}\n\n${piece}` : piece;
    if (buf && next.length > max) {
      flush();
      buf = piece;
    } else {
      buf = next;
    }
  };

  for (const para of paras) {
    if (para.length <= max) {
      append(para);
      continue;
    }
    const sentences = para.split(/(?<=[.!?])\s+/);
    for (const sen of sentences) {
      if (sen.length <= max) {
        append(sen);
        continue;
      }
      flush();
      for (let i = 0; i < sen.length; i += max) {
        chunks.push(sen.slice(i, i + max));
      }
    }
  }
  flush();
  return chunks.length ? chunks : [trimmed];
}

export function mergeTrainerReplies(raws) {
  const issues = [];
  const naturals = [];
  let quip = '';
  let cefr = '';
  for (const raw of raws) {
    const map = decodeTrainerJson(raw);
    if (!map) continue;
    if (Array.isArray(map.issues)) {
      for (const item of map.issues) {
        if (item && (item.wrong || item.right)) issues.push(item);
      }
    }
    const natural = String(map.natural || '').trim();
    if (natural) naturals.push(natural);
    if (!quip && map.quip) quip = String(map.quip);
    if (map.cefr) cefr = String(map.cefr);
  }
  return JSON.stringify({
    issues: issues.slice(0, 8),
    natural: naturals.join('\n\n'),
    quip,
    cefr: cefr || 'B1',
  });
}
