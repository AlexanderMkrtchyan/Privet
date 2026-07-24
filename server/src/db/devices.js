import { db } from '../db.js';

function nowSql() {
  return new Date().toISOString().replace('T', ' ').slice(0, 19);
}

export function upsertDeviceToken(userId, token, platform = 'android') {
  const clean = String(token || '').trim();
  if (!clean || clean.length < 8) throw new Error('token required');
  const plat = String(platform || 'android').toLowerCase().slice(0, 32);
  db.prepare(
    `
    INSERT INTO device_tokens (token, user_id, platform, updated_at)
    VALUES (?, ?, ?, ?)
    ON CONFLICT(token) DO UPDATE SET
      user_id = excluded.user_id,
      platform = excluded.platform,
      updated_at = excluded.updated_at
  `,
  ).run(clean, userId, plat, nowSql());
  return { ok: true };
}

export function removeDeviceToken(token, userId = null) {
  const clean = String(token || '').trim();
  if (!clean) return { ok: true };
  if (userId) {
    db.prepare(
      'DELETE FROM device_tokens WHERE token = ? AND user_id = ?',
    ).run(clean, userId);
  } else {
    db.prepare('DELETE FROM device_tokens WHERE token = ?').run(clean);
  }
  return { ok: true };
}

export function listDeviceTokensForUser(userId) {
  return db
    .prepare(
      'SELECT token, platform FROM device_tokens WHERE user_id = ?',
    )
    .all(userId);
}
