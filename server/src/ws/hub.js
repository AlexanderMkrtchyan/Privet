/** @typedef {{ userId: string, socket: import('ws').WebSocket }} Client */

/** @type {Map<string, Set<import('ws').WebSocket>>} */
const socketsByUser = new Map();

/** Most recently active socket per user — only this one may play message sound. */
/** @type {Map<string, import('ws').WebSocket>} */
const primarySocketByUser = new Map();

function liveSockets(userId) {
  const set = socketsByUser.get(userId);
  if (!set) return [];
  return [...set].filter((s) => s.readyState === 1);
}

function resolvePrimary(userId) {
  const live = liveSockets(userId);
  if (live.length === 0) {
    primarySocketByUser.delete(userId);
    return null;
  }
  const cur = primarySocketByUser.get(userId);
  if (cur && live.includes(cur)) return cur;
  const next = live[live.length - 1];
  primarySocketByUser.set(userId, next);
  return next;
}

export function bindSocket(userId, socket) {
  if (!socketsByUser.has(userId)) socketsByUser.set(userId, new Set());
  socketsByUser.get(userId).add(socket);
  // Newest connection becomes primary so the tab you just opened owns the ding.
  primarySocketByUser.set(userId, socket);
  socket.on('close', () => unbindSocket(userId, socket));
}

/** Mark this socket as the one that should play notification sounds. */
export function touchSocket(userId, socket) {
  if (!userId || !socket) return;
  const set = socketsByUser.get(userId);
  if (!set?.has(socket)) return;
  if (socket.readyState === 1) primarySocketByUser.set(userId, socket);
}

export function unbindSocket(userId, socket) {
  const set = socketsByUser.get(userId);
  if (!set) return;
  set.delete(socket);
  if (primarySocketByUser.get(userId) === socket) {
    primarySocketByUser.delete(userId);
  }
  if (set.size === 0) {
    socketsByUser.delete(userId);
    primarySocketByUser.delete(userId);
    return true; // became offline
  }
  resolvePrimary(userId);
  return false;
}

export function isOnline(userId) {
  return liveSockets(userId).length > 0;
}

export function onlineUserIds() {
  return [...socketsByUser.keys()].filter((id) => liveSockets(id).length > 0);
}

/** lastSeenByUserId snapshot for presence payloads (updated by handlers). */
/** @type {Map<string, string>} */
const lastSeenCache = new Map();

export function noteLastSeen(userId, at) {
  if (userId && at) lastSeenCache.set(userId, at);
}

export function lastSeenMap(userIds) {
  /** @type {Record<string, string>} */
  const out = {};
  for (const id of userIds) {
    if (lastSeenCache.has(id)) out[id] = lastSeenCache.get(id);
  }
  return out;
}

export function seedLastSeenFromDb(rows) {
  for (const row of rows) {
    if (row?.id && row.last_seen_at) {
      lastSeenCache.set(row.id, row.last_seen_at);
    }
  }
}

/**
 * @param {string} userId
 * @param {object} payload
 * @param {{ soundOnce?: boolean }} [opts]
 *   When soundOnce is set on a `message` payload, only the primary socket
 *   receives playSound:true — other tabs/browsers still get the message UI
 *   update but must not ding.
 */
export function sendToUser(userId, payload, opts = {}) {
  const live = liveSockets(userId);
  if (live.length === 0) return;
  const primary = resolvePrimary(userId);
  const soundOnce = opts.soundOnce === true && payload?.type === 'message';
  for (const socket of live) {
    const body = soundOnce
      ? { ...payload, playSound: socket === primary }
      : payload;
    socket.send(JSON.stringify(body));
  }
}

/**
 * @param {string[]} userIds
 * @param {object} payload
 * @param {string|null} [exceptUserId]
 * @param {{ soundOnce?: boolean }} [opts]
 */
export function broadcastToUsers(userIds, payload, exceptUserId = null, opts = {}) {
  for (const id of userIds) {
    if (exceptUserId && id === exceptUserId) continue;
    sendToUser(id, payload, opts);
  }
}

/** Dev/debug: open socket counts per user (no secrets). */
export function socketStats() {
  /** @type {Record<string, { sockets: number, primary: boolean }>} */
  const out = {};
  for (const userId of socketsByUser.keys()) {
    const live = liveSockets(userId);
    out[userId] = {
      sockets: live.length,
      primary: live.includes(primarySocketByUser.get(userId)),
    };
  }
  return out;
}
