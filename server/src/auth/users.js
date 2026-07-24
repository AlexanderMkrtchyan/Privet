import { db, publicUser } from '../db.js';
import { listBlockedIds, isBlockedEitherWay } from '../db/blocks.js';

const findByHandle = db.prepare('SELECT * FROM users WHERE handle = ? COLLATE NOCASE');
const findById = db.prepare('SELECT * FROM users WHERE id = ?');

export function getUserByHandle(handle) {
  return findByHandle.get(handle);
}

export function getUserById(id) {
  return findById.get(id);
}

export function listUsersExcept(userId) {
  const blocked = listBlockedIds(userId);
  // Also hide people who blocked me.
  const blockedMe = new Set(
    db
      .prepare('SELECT blocker_id FROM user_blocks WHERE blocked_id = ?')
      .all(userId)
      .map((r) => r.blocker_id),
  );
  return db
    .prepare('SELECT * FROM users WHERE id != ? ORDER BY display_name COLLATE NOCASE')
    .all(userId)
    .map(publicUser)
    .filter((u) => !blocked.has(u.id) && !blockedMe.has(u.id));
}

export function updateProfile(userId, { displayName, avatarUrl, avatarHue } = {}) {
  const row = getUserById(userId);
  if (!row) throw new Error('User not found');

  let name = row.display_name;
  if (displayName !== undefined) {
    const clean = String(displayName || '').trim().slice(0, 64);
    if (!clean) throw new Error('display name required');
    name = clean;
  }

  let url = row.avatar_url || null;
  if (avatarUrl !== undefined) {
    if (avatarUrl === null || avatarUrl === '') {
      url = null;
    } else {
      const cleanUrl = String(avatarUrl);
      if (!cleanUrl.startsWith('/media/')) {
        throw new Error('invalid avatarUrl');
      }
      url = cleanUrl;
    }
  }

  let hue = row.avatar_hue;
  if (avatarHue !== undefined && avatarHue !== null) {
    const n = Number(avatarHue);
    if (!Number.isFinite(n)) throw new Error('invalid avatarHue');
    hue = ((Math.round(n) % 360) + 360) % 360;
  }

  db.prepare(
    `
    UPDATE users
    SET display_name = ?, avatar_url = ?, avatar_hue = ?
    WHERE id = ?
  `,
  ).run(name, url, hue, userId);

  return publicUser(getUserById(userId));
}

export function touchLastSeen(userId) {
  if (!userId) return;
  const at = new Date().toISOString().replace('T', ' ').slice(0, 19);
  db.prepare('UPDATE users SET last_seen_at = ? WHERE id = ?').run(at, userId);
}

export function canMessageUser(fromUserId, toUserId) {
  return !isBlockedEitherWay(fromUserId, toUserId);
}

export async function authenticate(request) {
  try {
    const decoded = await request.jwtVerify();
    const user = getUserById(decoded.sub);
    if (!user) return null;
    return publicUser(user);
  } catch {
    return null;
  }
}

export async function requireUser(request, reply) {
  const user = await authenticate(request);
  if (!user) {
    reply.code(401).send({ error: 'unauthorized' });
    return null;
  }
  return user;
}
