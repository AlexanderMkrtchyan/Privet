import { db, publicUser } from '../db.js';

export function blockUser(blockerId, blockedId) {
  if (!blockerId || !blockedId) throw new Error('user required');
  if (blockerId === blockedId) throw new Error('cannot block yourself');
  const target = db.prepare('SELECT id FROM users WHERE id = ?').get(blockedId);
  if (!target) throw new Error('User not found');
  db.prepare(
    `
    INSERT INTO user_blocks (blocker_id, blocked_id)
    VALUES (?, ?)
    ON CONFLICT(blocker_id, blocked_id) DO NOTHING
  `,
  ).run(blockerId, blockedId);
  return { ok: true };
}

export function unblockUser(blockerId, blockedId) {
  db.prepare(
    'DELETE FROM user_blocks WHERE blocker_id = ? AND blocked_id = ?',
  ).run(blockerId, blockedId);
  return { ok: true };
}

export function isBlockedEitherWay(userA, userB) {
  if (!userA || !userB || userA === userB) return false;
  return !!db
    .prepare(
      `
      SELECT 1 FROM user_blocks
      WHERE (blocker_id = ? AND blocked_id = ?)
         OR (blocker_id = ? AND blocked_id = ?)
      LIMIT 1
    `,
    )
    .get(userA, userB, userB, userA);
}

export function isBlockedBy(blockerId, blockedId) {
  return !!db
    .prepare(
      'SELECT 1 FROM user_blocks WHERE blocker_id = ? AND blocked_id = ?',
    )
    .get(blockerId, blockedId);
}

export function listBlockedUsers(blockerId) {
  return db
    .prepare(
      `
      SELECT u.* FROM user_blocks b
      JOIN users u ON u.id = b.blocked_id
      WHERE b.blocker_id = ?
      ORDER BY u.display_name COLLATE NOCASE
    `,
    )
    .all(blockerId)
    .map(publicUser);
}

export function listBlockedIds(blockerId) {
  return new Set(
    db
      .prepare('SELECT blocked_id FROM user_blocks WHERE blocker_id = ?')
      .all(blockerId)
      .map((r) => r.blocked_id),
  );
}
