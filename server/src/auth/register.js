import crypto from 'node:crypto';
import bcrypt from 'bcryptjs';
import { v4 as uuid } from 'uuid';
import { db, publicUser } from '../db.js';
import { getUserByHandle } from './users.js';

const HANDLE_RE = /^[a-z0-9_]{3,24}$/;

const ADJECTIVES = [
  'swift', 'calm', 'bright', 'quiet', 'bold', 'keen', 'lucky', 'noble',
  'clear', 'fresh', 'rapid', 'solid', 'vivid', 'amber', 'coral', 'misty',
];
const NOUNS = [
  'otter', 'falcon', 'cedar', 'river', 'ember', 'comet', 'maple', 'orchid',
  'pixel', 'harbor', 'nexus', 'prism', 'signal', 'vector', 'willow', 'zenith',
];

export function normalizeHandle(raw) {
  return String(raw || '').trim().toLowerCase();
}

export function validateHandle(handle) {
  if (!HANDLE_RE.test(handle)) {
    return 'Handle must be 3–24 chars: a-z, 0-9, underscore';
  }
  return null;
}

export function validatePassword(password) {
  if (!password || password.length < 8) {
    return 'Password must be at least 8 characters';
  }
  if (password.length > 128) {
    return 'Password is too long';
  }
  return null;
}

export function createUser({ handle, displayName, password }) {
  const id = uuid();
  const hue = Math.floor(Math.random() * 360);
  const name = (displayName || handle).trim().slice(0, 48) || handle;
  db.prepare(
    `
    INSERT INTO users (id, handle, display_name, password_hash, avatar_hue)
    VALUES (?, ?, ?, ?, ?)
  `,
  ).run(id, handle, name, bcrypt.hashSync(password, 12), hue);
  return publicUser(getUserByHandle(handle));
}

export function generatePassword(bytes = 9) {
  return crypto.randomBytes(bytes).toString('base64url');
}

export function generateUniqueHandle() {
  for (let i = 0; i < 40; i++) {
    const a = ADJECTIVES[Math.floor(Math.random() * ADJECTIVES.length)];
    const n = NOUNS[Math.floor(Math.random() * NOUNS.length)];
    const num = Math.floor(Math.random() * 90) + 10;
    const handle = `${a}_${n}_${num}`;
    if (!getUserByHandle(handle)) return handle;
  }
  return `user_${crypto.randomBytes(4).toString('hex')}`;
}

/** Very light IP throttle for quick-join abuse. */
const quickHits = new Map();
export function allowQuickJoin(ip) {
  const key = ip || 'unknown';
  const now = Date.now();
  const prev = quickHits.get(key) || [];
  const recent = prev.filter((t) => now - t < 60_000);
  if (recent.length >= 8) return false;
  recent.push(now);
  quickHits.set(key, recent);
  return true;
}
