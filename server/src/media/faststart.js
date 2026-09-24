import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const FASTSTART_EXT = new Set(['.mp4', '.mov', '.m4v']);
const HEAD_BYTES = 2 * 1024 * 1024;

function indexOfBox(buf, name) {
  return buf.indexOf(Buffer.from(name));
}

function tailOf(filePath, size, max) {
  const fd = fs.openSync(filePath, 'r');
  try {
    const len = Math.min(max, size);
    const buf = Buffer.alloc(len);
    fs.readSync(fd, buf, 0, len, size - len);
    return buf;
  } finally {
    fs.closeSync(fd);
  }
}

function headOf(filePath, size, max) {
  const fd = fs.openSync(filePath, 'r');
  try {
    const len = Math.min(max, size);
    const buf = Buffer.alloc(len);
    fs.readSync(fd, buf, 0, len);
    return buf;
  } finally {
    fs.closeSync(fd);
  }
}

/// True when the MP4 index (`moov`) sits after `mdat`, so a player must
/// fetch the tail of the file before the first frame can start.
export function moovIsAtEnd(filePath) {
  let st;
  try {
    st = fs.statSync(filePath);
  } catch {
    return false;
  }
  if (st.size < 16) return false;
  const head = headOf(filePath, st.size, HEAD_BYTES);
  const tail = tailOf(filePath, st.size, HEAD_BYTES);
  const moovHead = indexOfBox(head, 'moov');
  const mdatHead = indexOfBox(head, 'mdat');
  if (moovHead >= 0 && (mdatHead < 0 || moovHead < mdatHead)) return false;
  const moovTail = tail.lastIndexOf(Buffer.from('moov'));
  return moovTail >= 0 || (mdatHead >= 0 && moovHead < 0);
}

function runFfmpeg(args, timeoutMs = 15000) {
  return new Promise((resolve, reject) => {
    const child = spawn('ffmpeg', args, { stdio: ['ignore', 'ignore', 'pipe'] });
    let err = '';
    const timer = setTimeout(() => {
      child.kill('SIGKILL');
      reject(new Error('ffmpeg timed out'));
    }, timeoutMs);
    child.stderr.on('data', (chunk) => {
      err += chunk;
      if (err.length > 4000) err = err.slice(-4000);
    });
    child.on('error', (e) => {
      clearTimeout(timer);
      reject(e);
    });
    child.on('close', (code) => {
      clearTimeout(timer);
      if (code === 0) resolve();
      else reject(new Error(err.trim() || `ffmpeg exited ${code}`));
    });
  });
}

/// Remux in place with `-c copy -movflags +faststart`. No re-encode, no WebM.
/// Returns true when the file was rewritten.
export async function remuxFaststart(filePath) {
  const ext = path.extname(filePath).toLowerCase();
  if (!FASTSTART_EXT.has(ext)) return false;
  if (!moovIsAtEnd(filePath)) return false;
  const tmp = `${filePath}.faststart${ext}`; // keep a real .mp4/.mov suffix so ffmpeg muxes
  try {
    await runFfmpeg([
      '-y',
      '-i',
      filePath,
      '-c',
      'copy',
      '-movflags',
      '+faststart',
      tmp,
    ]);
    const out = fs.statSync(tmp);
    if (out.size < 16) throw new Error('faststart remux produced empty file');
    fs.renameSync(tmp, filePath);
    return true;
  } catch (err) {
    try {
      fs.unlinkSync(tmp);
    } catch {
      /* ignore */
    }
    console.warn(`[faststart] skipped ${path.basename(filePath)}: ${err.message}`);
    return false;
  }
}
