import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { uploadsDir } from '../db.js';

// Real sound levels for chat bubbles. The bars used to be a hash of the file
// name, so they had nothing to do with what the speaker actually said. Here
// ffmpeg decodes the clip to mono PCM and we keep one RMS value per bar, which
// the client draws as a Telegram-style waveform.

const BAR_COUNT = 48;
const SAMPLE_RATE = 4000; // plenty for an envelope, cheap to decode
const MAX_SECONDS = 900; // ignore the tail of very long recordings
const DECODE_TIMEOUT_MS = 20000;
const MAX_PCM_BYTES = 48 * 1024 * 1024;
const CACHE_VERSION = 1;

/** Cache directory lives next to the uploads, so it dies with the media. */
function cacheDir() {
  return path.join(path.dirname(uploadsDir), 'waveforms');
}

function cacheKey(filePath) {
  const st = fs.statSync(filePath);
  return crypto
    .createHash('sha1')
    .update(`${CACHE_VERSION}:${filePath}:${st.size}:${st.mtimeMs}`)
    .digest('hex');
}

function decodePcm(filePath) {
  return new Promise((resolve, reject) => {
    const args = [
      '-v', 'error',
      '-nostdin',
      '-i', filePath,
      '-t', String(MAX_SECONDS),
      '-ac', '1',
      '-ar', String(SAMPLE_RATE),
      '-f', 's16le',
      'pipe:1',
    ];
    const child = spawn('ffmpeg', args, { stdio: ['ignore', 'pipe', 'pipe'] });
    const chunks = [];
    let bytes = 0;
    let stderr = '';
    let settled = false;
    const finish = (err, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (err) reject(err);
      else resolve(value);
    };
    const timer = setTimeout(() => {
      child.kill('SIGKILL');
      finish(new Error('ffmpeg timed out'));
    }, DECODE_TIMEOUT_MS);

    child.stdout.on('data', (buf) => {
      bytes += buf.length;
      if (bytes > MAX_PCM_BYTES) {
        child.kill('SIGKILL');
        return;
      }
      chunks.push(buf);
    });
    child.stderr.on('data', (buf) => {
      if (stderr.length < 4000) stderr += buf.toString();
    });
    child.on('error', (err) => finish(err));
    child.on('close', (code) => {
      if (code !== 0) {
        finish(new Error(stderr.trim() || `ffmpeg exited ${code}`));
        return;
      }
      finish(null, Buffer.concat(chunks));
    });
  });
}

/** RMS per bar, normalised so the loudest passages reach the top of the track. */
export function peaksFromPcm(pcm) {
  const samples = Math.floor(pcm.length / 2);
  if (samples <= 0) return [];
  const rms = [];
  for (let bar = 0; bar < BAR_COUNT; bar += 1) {
    const start = Math.floor((bar * samples) / BAR_COUNT);
    const end = Math.floor(((bar + 1) * samples) / BAR_COUNT);
    if (end <= start) {
      rms.push(0);
      continue;
    }
    let sum = 0;
    for (let i = start; i < end; i += 1) {
      const v = pcm.readInt16LE(i * 2) / 32768;
      sum += v * v;
    }
    rms.push(Math.sqrt(sum / (end - start)));
  }
  // A single cough should not flatten the rest of the clip: normalise against
  // the 95th percentile instead of the absolute peak.
  const sorted = [...rms].sort((a, b) => a - b);
  const reference = sorted[Math.floor(sorted.length * 0.95)] || sorted.at(-1) || 0;
  if (!(reference > 0.0005)) return rms.map(() => 0);
  return rms.map((v) => Math.min(1, Math.pow(v / reference, 0.75)));
}

const memory = new Map(); // cacheKey -> {peaks, duration} | Promise

export async function computeWaveform(filePath) {
  let key;
  try {
    key = cacheKey(filePath);
  } catch {
    return { peaks: [], duration: 0 };
  }
  const hit = memory.get(key);
  if (hit) return hit;

  const pending = (async () => {
    const jsonPath = path.join(cacheDir(), `${key}.json`);
    try {
      const cached = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
      if (Array.isArray(cached?.peaks) && cached.peaks.length) return cached;
    } catch {
      /* no cache yet */
    }
    const pcm = await decodePcm(filePath);
    const peaks = peaksFromPcm(pcm);
    const duration = Math.floor(pcm.length / 2) / SAMPLE_RATE;
    const result = { peaks, duration: Math.round(duration * 10) / 10 };
    try {
      fs.mkdirSync(path.dirname(jsonPath), { recursive: true });
      fs.writeFileSync(jsonPath, JSON.stringify(result));
    } catch {
      /* cache is best-effort */
    }
    return result;
  })();

  memory.set(key, pending);
  try {
    return await pending;
  } catch (err) {
    memory.delete(key);
    throw err;
  }
}
