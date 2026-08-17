import fs from 'node:fs';
import path from 'node:path';
import { pipeline } from 'node:stream/promises';
import { createWriteStream } from 'node:fs';
import { v4 as uuid } from 'uuid';
import multipart from '@fastify/multipart';
import bcrypt from 'bcryptjs';
import { publicUser, uploadsDir, db } from '../db.js';
import {
  allowQuickJoin,
  createUser,
  generatePassword,
  generateUniqueHandle,
  normalizeHandle,
  validateHandle,
  validatePassword,
} from '../auth/register.js';
import {
  getUserByHandle,
  getUserById,
  listUsersExcept,
  requireUser,
  updateProfile,
  canMessageUser,
} from '../auth/users.js';
import {
  addGroupMember,
  createGroup,
  createMessage,
  deleteConversation,
  editMessage,
  findOrCreateDm,
  getMessage,
  hideConversation,
  listConversationsForUser,
  listMembers,
  listMessages,
  markConversationRead,
  memberIds,
  removeGroupMember,
  searchAll,
  searchMessagesInConversation,
  setConversationMuted,
  setConversationPinned,
  setMessageLinkPreview,
  softDeleteMessage,
  toggleReaction,
  userInConversation,
  isConversationMuted,
} from '../db/chat.js';
import {
  blockUser,
  unblockUser,
  listBlockedUsers,
} from '../db/blocks.js';
import { upsertDeviceToken, removeDeviceToken } from '../db/devices.js';
import {
  clearDoneTaskItems,
  createTaskItem,
  deleteTaskItem,
  listDoneTaskItems,
  listTaskActivity,
  listTaskItems,
  unpinAllTasks,
  updateTaskItem,
} from '../db/tasks.js';
import {
  createExpense,
  createReminder,
  deleteExpense,
  deleteReminder,
  listReminders,
  listReminderHistory,
  updateExpense,
  updateReminder,
} from '../db/reminders.js';
import {
  extractFirstUrl,
  fetchLinkPreview,
} from '../media/linkPreview.js';
import { broadcastToUsers, isOnline, onlineUserIds, socketStats } from '../ws/hub.js';
import { noteConversationMessage, shouldAcceptMarkRead } from '../readGate.js';
import { pushToUser } from '../push/fcm.js';
import { runPrivetAi } from '../ai/chat.js';
import { serverAiStatus } from '../ai/llm.js';

function broadcastReminders(conversationId) {
  broadcastToUsers(memberIds(conversationId), {
    type: 'reminders.updated',
    conversationId,
    items: listReminders(conversationId),
  });
}

function broadcastTasks(conversationId) {
  broadcastToUsers(memberIds(conversationId), {
    type: 'tasks.updated',
    conversationId,
    items: listTaskItems(conversationId),
  });
}

const MEDIA_KINDS = new Set(['image', 'video', 'audio', 'voice', 'file', 'album']);
const MAX_UPLOAD_BYTES = 80 * 1024 * 1024; // 80MB

function kindFromMime(mime, fallback = 'file') {
  if (!mime) return fallback;
  if (mime.startsWith('image/')) return 'image';
  if (mime.startsWith('video/')) return 'video';
  if (mime.startsWith('audio/')) return fallback === 'voice' ? 'voice' : 'audio';
  return 'file';
}

export async function registerRoutes(app) {
  await app.register(multipart, {
    limits: { fileSize: MAX_UPLOAD_BYTES, files: 1 },
  });

  app.get('/health', async () => ({ ok: true, name: 'privet' }));

  app.get('/debug/sockets', async () => {
    const byUser = socketStats();
    const users = db
      .prepare('SELECT id, handle FROM users')
      .all()
      .reduce((acc, row) => {
        acc[row.id] = row.handle;
        return acc;
      }, /** @type {Record<string, string>} */ ({}));
    return {
      totalLive: Object.values(byUser).reduce((n, s) => n + s.sockets, 0),
      users: Object.entries(byUser).map(([id, info]) => ({
        handle: users[id] || id.slice(0, 8),
        sockets: info.sockets,
        hasPrimary: info.primary,
      })),
    };
  });

  app.get('/ai/status', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    return serverAiStatus();
  });

  app.get('/ice', async () => ({
    iceServers: [
      { urls: 'stun:stun.l.google.com:19302' },
      { urls: 'stun:stun1.l.google.com:19302' },
      ...(process.env.PRIVET_TURN_URL
        ? [
            {
              urls: process.env.PRIVET_TURN_URL,
              username: process.env.PRIVET_TURN_USER || '',
              credential: process.env.PRIVET_TURN_PASS || '',
            },
          ]
        : []),
    ],
  }));

  app.get('/auth/check-handle', async (request) => {
    const handle = normalizeHandle(request.query.handle);
    const formatError = validateHandle(handle);
    if (formatError) {
      return { handle, available: false, reason: formatError };
    }
    const taken = !!getUserByHandle(handle);
    return {
      handle,
      available: !taken,
      reason: taken ? 'Handle is already taken' : null,
    };
  });

  app.post('/auth/register', async (request, reply) => {
    const handle = normalizeHandle(request.body?.handle);
    const password = String(request.body?.password || '');
    const displayName = String(request.body?.displayName || '').trim();

    const handleError = validateHandle(handle);
    if (handleError) return reply.code(400).send({ error: handleError });

    const passwordError = validatePassword(password);
    if (passwordError) return reply.code(400).send({ error: passwordError });

    if (getUserByHandle(handle)) {
      return reply.code(409).send({ error: 'Handle is already taken' });
    }

    const user = createUser({
      handle,
      displayName: displayName || handle,
      password,
    });
    const token = app.jwt.sign({ sub: user.id, handle: user.handle });
    return { token, user };
  });

  // Public invite preview — used by the join page before creating an account.
  app.get('/auth/invite/:handle', async (request, reply) => {
    const handle = normalizeHandle(request.params.handle);
    const formatError = validateHandle(handle);
    if (formatError) return reply.code(404).send({ error: 'Invite not found' });
    const row = getUserByHandle(handle);
    if (!row) return reply.code(404).send({ error: 'Invite not found' });
    const inviter = publicUser(row);
    return {
      id: inviter.id,
      handle: inviter.handle,
      displayName: inviter.displayName,
      avatarHue: inviter.avatarHue,
      avatarUrl: inviter.avatarUrl,
    };
  });

  app.post('/auth/quick-join', async (request, reply) => {
    const ip = request.ip;
    if (!allowQuickJoin(ip)) {
      return reply.code(429).send({ error: 'Too many quick joins — try again in a minute' });
    }

    const inviteHandle = normalizeHandle(request.body?.inviteHandle);
    let inviter = null;
    if (inviteHandle) {
      const row = getUserByHandle(inviteHandle);
      if (row) inviter = publicUser(row);
    }

    const handle = generateUniqueHandle();
    const password = generatePassword();
    const pretty = handle
      .split('_')
      .map((p) => p.charAt(0).toUpperCase() + p.slice(1))
      .join(' ');

    const user = createUser({
      handle,
      displayName: pretty,
      password,
    });

    let conversationId = null;
    if (inviter) {
      conversationId = findOrCreateDm(user.id, inviter.id);
    }

    const token = app.jwt.sign({ sub: user.id, handle: user.handle });
    return {
      token,
      user,
      credentials: { handle, password },
      tip: 'Save your handle and password — you will need them to sign in again.',
      invitedBy: inviter,
      conversationId,
    };
  });

  app.post('/auth/login', async (request, reply) => {
    const handle = normalizeHandle(request.body?.handle);
    const password = String(request.body?.password || '');
    const row = getUserByHandle(handle);
    if (!row || !bcrypt.compareSync(password, row.password_hash)) {
      return reply.code(401).send({ error: 'Invalid handle or password' });
    }
    const user = publicUser(row);
    const token = app.jwt.sign({ sub: user.id, handle: user.handle });
    return { token, user };
  });

  app.get('/me', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    return { user, online: onlineUserIds() };
  });

  app.patch('/me', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    try {
      const updated = updateProfile(user.id, {
        displayName: request.body?.displayName,
        avatarUrl:
          request.body?.avatarUrl === undefined
            ? undefined
            : request.body.avatarUrl,
        avatarHue: request.body?.avatarHue,
      });
      return { user: updated };
    } catch (err) {
      return reply.code(400).send({ error: err.message || 'update failed' });
    }
  });

  app.post('/devices', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    try {
      upsertDeviceToken(
        user.id,
        request.body?.token,
        request.body?.platform || 'android',
      );
      return { ok: true };
    } catch (err) {
      return reply.code(400).send({ error: err.message || 'register failed' });
    }
  });

  app.delete('/devices', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    removeDeviceToken(request.body?.token || request.query?.token, user.id);
    return { ok: true };
  });

  app.get('/blocks', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    return { users: listBlockedUsers(user.id) };
  });

  app.post('/blocks', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    const userId = String(request.body?.userId || '');
    if (!userId) return reply.code(400).send({ error: 'userId required' });
    try {
      blockUser(user.id, userId);
      return { ok: true, users: listBlockedUsers(user.id) };
    } catch (err) {
      return reply.code(400).send({ error: err.message || 'block failed' });
    }
  });

  app.delete('/blocks/:userId', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    unblockUser(user.id, request.params.userId);
    return { ok: true, users: listBlockedUsers(user.id) };
  });

  app.get('/users', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    return {
      users: listUsersExcept(user.id).map((u) => ({
        ...u,
        online: isOnline(u.id),
      })),
    };
  });

  app.post('/conversations/:id/pin', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    const { id } = request.params;
    const pinned = request.body?.pinned !== false && request.body?.pinned !== 0;
    try {
      const result = setConversationPinned(id, user.id, pinned);
      return { ok: true, ...result };
    } catch (err) {
      const message = err.message || 'could not pin conversation';
      const code = message === 'forbidden' ? 403 : 400;
      return reply.code(code).send({ error: message });
    }
  });

  app.get('/conversations', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    return { conversations: listConversationsForUser(user.id) };
  });

  app.post('/conversations/dm', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    const { userId } = request.body || {};
    if (!userId) return reply.code(400).send({ error: 'userId required' });
    if (!canMessageUser(user.id, userId)) {
      return reply.code(403).send({ error: 'User is blocked' });
    }
    const id = findOrCreateDm(user.id, userId);
    const conversations = listConversationsForUser(user.id);
    return { conversation: conversations.find((c) => c.id === id) };
  });

  app.post('/conversations/group', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    const title = String(request.body?.title || '').trim();
    const members = Array.isArray(request.body?.memberIds)
      ? request.body.memberIds.map(String)
      : [];
    if (members.length < 1) {
      return reply.code(400).send({ error: 'Pick at least one member' });
    }
    try {
      const id = createGroup({
        title,
        creatorId: user.id,
        memberIds: members,
      });
      const conversations = listConversationsForUser(user.id);
      const conversation = conversations.find((c) => c.id === id);
      broadcastToUsers(memberIds(id), {
        type: 'conversation.upsert',
        conversationId: id,
      });
      return { conversation };
    } catch (err) {
      return reply.code(400).send({ error: err.message || 'could not create group' });
    }
  });

  app.get('/conversations/:id/members', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    const { id } = request.params;
    if (!userInConversation(id, user.id)) {
      return reply.code(403).send({ error: 'forbidden' });
    }
    return {
      members: listMembers(id).map((u) => ({
        ...u,
        online: isOnline(u.id),
      })),
    };
  });

  app.post('/conversations/:id/members', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    const { id } = request.params;
    if (!userInConversation(id, user.id)) {
      return reply.code(403).send({ error: 'forbidden' });
    }
    const userId = String(request.body?.userId || '');
    if (!userId) return reply.code(400).send({ error: 'userId required' });
    try {
      const before = memberIds(id);
      const members = addGroupMember(id, userId);
      const notify = [...new Set([...before, userId])];
      broadcastToUsers(notify, {
        type: 'members.changed',
        conversationId: id,
        action: 'added',
        userId,
        byUserId: user.id,
      });
      broadcastToUsers(notify, {
        type: 'conversation.upsert',
        conversationId: id,
      });
      return {
        members: members.map((u) => ({
          ...u,
          online: isOnline(u.id),
        })),
      };
    } catch (err) {
      return reply.code(400).send({ error: err.message || 'could not add member' });
    }
  });

  app.delete('/conversations/:id/members/:userId', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    const { id, userId } = request.params;
    if (!userInConversation(id, user.id)) {
      return reply.code(403).send({ error: 'forbidden' });
    }
    try {
      const before = memberIds(id);
      const members = removeGroupMember(id, userId);
      broadcastToUsers(before, {
        type: 'members.changed',
        conversationId: id,
        action: 'removed',
        userId,
        byUserId: user.id,
      });
      // Remaining members refresh inbox; removed user drops the chat.
      broadcastToUsers(
        members.map((m) => m.id),
        { type: 'conversation.upsert', conversationId: id },
      );
      broadcastToUsers([userId], {
        type: 'conversation.removed',
        conversationId: id,
      });
      return {
        members: members.map((u) => ({
          ...u,
          online: isOnline(u.id),
        })),
      };
    } catch (err) {
      return reply.code(400).send({ error: err.message || 'could not remove member' });
    }
  });

  app.delete('/conversations/:id', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    const { id } = request.params;
    if (!userInConversation(id, user.id)) {
      return reply.code(403).send({ error: 'forbidden' });
    }
    try {
      const result = deleteConversation(id, user.id);
      if (result.mode === 'deleted') {
        broadcastToUsers(result.userIds, {
          type: 'conversation.removed',
          conversationId: id,
        });
      } else {
        broadcastToUsers(result.userIds, {
          type: 'members.changed',
          conversationId: id,
          action: 'removed',
          userId: result.leftUserId,
          byUserId: user.id,
        });
        broadcastToUsers(
          result.userIds.filter((uid) => uid !== result.leftUserId),
          { type: 'conversation.upsert', conversationId: id },
        );
        broadcastToUsers([result.leftUserId], {
          type: 'conversation.removed',
          conversationId: id,
        });
      }
      return { ok: true, mode: result.mode };
    } catch (err) {
      const message = err.message || 'could not delete conversation';
      const code =
        message.includes('Only the group owner') || message === 'forbidden'
          ? 403
          : 400;
      return reply.code(code).send({ error: message });
    }
  });

  app.post('/conversations/:id/hide', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    const { id } = request.params;
    try {
      hideConversation(id, user.id);
      return { ok: true };
    } catch (err) {
      const message = err.message || 'could not hide conversation';
      const code = message === 'forbidden' ? 403 : 400;
      return reply.code(code).send({ error: message });
    }
  });

  app.post('/conversations/:id/mute', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    const { id } = request.params;
    const muted = request.body?.muted !== false && request.body?.muted !== 0;
    try {
      const result = setConversationMuted(id, user.id, muted);
      return { ok: true, ...result };
    } catch (err) {
      const message = err.message || 'could not mute conversation';
      const code = message === 'forbidden' ? 403 : 400;
      return reply.code(code).send({ error: message });
    }
  });

  app.post('/conversations/:id/forward', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    const { id } = request.params;
    const messageId = String(request.body?.messageId || '');
    if (!messageId) return reply.code(400).send({ error: 'messageId required' });
    if (!userInConversation(id, user.id)) {
      return reply.code(403).send({ error: 'forbidden' });
    }
    try {
      const message = createMessage({
        conversationId: id,
        senderId: user.id,
        body: '',
        forwardFromId: messageId,
      });
      broadcastToUsers(memberIds(id), { type: 'message', message }, null, {
        soundOnce: true,
      });
      noteConversationMessage(id);
      // Source chat sees "Forwarded to …" on the original bubble.
      const sourceMessage = getMessage(messageId);
      if (sourceMessage) {
        broadcastToUsers(memberIds(sourceMessage.conversationId), {
          type: 'message.updated',
          message: sourceMessage,
        });
      }
      // Inline notify (same as WS path).
      const title = message.sender.displayName || message.sender.handle || 'Privet';
      const body =
        message.kind === 'text'
          ? message.body.slice(0, 140)
          : message.fileName || 'Forwarded message';
      for (const uid of memberIds(id)) {
        if (uid === user.id) continue;
        if (isConversationMuted(id, uid)) continue;
        broadcastToUsers([uid], {
          type: 'notify',
          conversationId: id,
          title,
          body,
          messageId: message.id,
        });
        if (!isOnline(uid)) {
          void pushToUser(uid, {
            title,
            body,
            data: { conversationId: id, messageId: message.id },
          });
        }
      }
      return { message, sourceMessage: sourceMessage || null };
    } catch (err) {
      return reply.code(400).send({ error: err.message || 'forward failed' });
    }
  });

  app.post('/conversations/:id/read', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    const { id } = request.params;
    const messageId = request.body?.messageId
      ? String(request.body.messageId)
      : null;
    const focused = request.body?.focused === true;
    if (!shouldAcceptMarkRead(id, { focused })) {
      return { ok: true, ignored: true, reason: 'stale_auto_ack' };
    }
    try {
      const result = markConversationRead(id, user.id, messageId);
      broadcastToUsers(memberIds(id), {
        type: 'conversation.read',
        ...result,
      });
      return result;
    } catch (err) {
      const message = err.message || 'could not mark read';
      const code = message === 'forbidden' ? 403 : 400;
      return reply.code(code).send({ error: message });
    }
  });

  app.get('/search', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    const q = String(request.query.q || '').trim();
    return searchAll(user.id, q, { limit: request.query.limit });
  });

  app.patch('/messages/:id', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    const { id } = request.params;
    const existing = getMessage(id);
    if (!existing) return reply.code(404).send({ error: 'not found' });
    if (!userInConversation(existing.conversationId, user.id)) {
      return reply.code(403).send({ error: 'forbidden' });
    }
    try {
      const message = editMessage({
        messageId: id,
        userId: user.id,
        body: request.body?.body,
      });
      broadcastToUsers(memberIds(message.conversationId), {
        type: 'message.updated',
        message,
      });
      return { message };
    } catch (err) {
      const message = err.message || 'edit failed';
      const code =
        message === 'forbidden'
          ? 403
          : message === 'message not found'
            ? 404
            : 400;
      return reply.code(code).send({ error: message });
    }
  });

  app.delete('/messages/:id', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    const { id } = request.params;
    const existing = getMessage(id);
    if (!existing) return reply.code(404).send({ error: 'not found' });
    if (!userInConversation(existing.conversationId, user.id)) {
      return reply.code(403).send({ error: 'forbidden' });
    }
    try {
      const message = softDeleteMessage({
        messageId: id,
        userId: user.id,
      });
      broadcastToUsers(memberIds(message.conversationId), {
        type: 'message.updated',
        message,
      });
      return { message };
    } catch (err) {
      const message = err.message || 'delete failed';
      const code = message === 'forbidden' ? 403 : 400;
      return reply.code(code).send({ error: message });
    }
  });

  app.post('/conversations/:id/ai', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    const { id } = request.params;
    if (!userInConversation(id, user.id)) {
      return reply.code(403).send({ error: 'forbidden' });
    }
    const input = String(request.body?.input || '').trim();
    if (!input.startsWith('#')) {
      return reply.code(400).send({ error: 'AI commands must start with #' });
    }
    try {
      const result = await runPrivetAi({
        conversationId: id,
        userId: user.id,
        input,
        since: request.body?.since ? String(request.body.since) : null,
        apiKey: request.body?.apiKey ? String(request.body.apiKey) : null,
        model: request.body?.model ? String(request.body.model) : null,
        baseUrl: request.body?.baseUrl ? String(request.body.baseUrl) : null,
      });
      return result;
    } catch (err) {
      const message = err.message || 'AI request failed';
      const code =
        message.includes('not configured') ||
        message.includes('Slow down')
          ? 503
          : 502;
      return reply.code(code).send({ error: message });
    }
  });

  app.get('/conversations/:id/messages', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    const { id } = request.params;
    if (!userInConversation(id, user.id)) {
      return reply.code(403).send({ error: 'forbidden' });
    }
    return {
      messages: listMessages(id, {
        limit: request.query.limit,
        before: request.query.before,
      }),
    };
  });

  app.get('/conversations/:id/messages/search', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    const { id } = request.params;
    if (!userInConversation(id, user.id)) {
      return reply.code(403).send({ error: 'forbidden' });
    }
    const q = String(request.query.q || '').trim();
    return {
      messages: searchMessagesInConversation(id, q, {
        limit: request.query.limit,
      }),
    };
  });

  app.post('/conversations/:id/messages', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    const { id } = request.params;
    if (!userInConversation(id, user.id)) {
      return reply.code(403).send({ error: 'forbidden' });
    }
    const kind = String(request.body?.kind || 'text');
    const body = String(request.body?.body || '').trim();
    const mediaUrl = request.body?.mediaUrl ? String(request.body.mediaUrl) : null;
    if (!body && !mediaUrl) {
      return reply.code(400).send({ error: 'empty message' });
    }
    if (MEDIA_KINDS.has(kind) && !mediaUrl) {
      return reply.code(400).send({ error: 'mediaUrl required' });
    }

    const message = createMessage({
      conversationId: id,
      senderId: user.id,
      body,
      kind,
      mediaUrl,
      mimeType: request.body?.mimeType ? String(request.body.mimeType) : null,
      fileName: request.body?.fileName ? String(request.body.fileName) : null,
      fileSize:
        typeof request.body?.fileSize === 'number'
          ? request.body.fileSize
          : null,
      replyToId: request.body?.replyToId
        ? String(request.body.replyToId)
        : null,
      replyQuote: request.body?.replyQuote
        ? String(request.body.replyQuote)
        : null,
    });

    broadcastToUsers(memberIds(id), { type: 'message', message }, null, {
      soundOnce: true,
    });
    noteConversationMessage(id);

    // Async OG unfurl (same path as websocket sends).
    if (kind === 'text' && body) {
      const url = extractFirstUrl(body);
      if (url) {
        void fetchLinkPreview(url).then((preview) => {
          if (!preview) return;
          const updated = setMessageLinkPreview(message.id, preview);
          if (!updated) return;
          broadcastToUsers(memberIds(id), {
            type: 'message.updated',
            message: updated,
          });
        });
      }
    }

    return { message };
  });

  app.post('/messages/:id/reactions', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    const { id } = request.params;
    const emoji = String(request.body?.emoji || '').trim();
    if (!emoji) return reply.code(400).send({ error: 'emoji required' });

    const existing = getMessage(id);
    if (!existing) return reply.code(404).send({ error: 'not found' });
    if (!userInConversation(existing.conversationId, user.id)) {
      return reply.code(403).send({ error: 'forbidden' });
    }

    try {
      const result = toggleReaction({
        messageId: id,
        userId: user.id,
        emoji,
      });
      broadcastToUsers(memberIds(result.conversationId), {
        type: 'message.updated',
        message: result.message,
      });
      return { message: result.message };
    } catch (err) {
      return reply.code(400).send({ error: err.message || 'reaction failed' });
    }
  });

  app.get('/conversations/:id/tasks', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    const { id } = request.params;
    if (!userInConversation(id, user.id)) {
      return reply.code(403).send({ error: 'forbidden' });
    }
    return { items: listTaskItems(id) };
  });

  app.get('/conversations/:id/tasks/history', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    const { id } = request.params;
    if (!userInConversation(id, user.id)) return reply.code(403).send({ error: 'forbidden' });
    const limit = request.query?.limit;
    const before = request.query?.before ? String(request.query.before) : null;
    const result = listDoneTaskItems(id, { limit, before });
    return result;
  });

  app.post('/conversations/:id/tasks', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    const { id } = request.params;
    if (!userInConversation(id, user.id)) {
      return reply.code(403).send({ error: 'forbidden' });
    }
    try {
      const item = createTaskItem({
        conversationId: id,
        createdBy: user.id,
        body: request.body?.body,
        messageId: request.body?.messageId ? String(request.body.messageId) : null,
        mediaUrl: request.body?.mediaUrl ? String(request.body.mediaUrl) : null,
        mimeType: request.body?.mimeType ? String(request.body.mimeType) : null,
        fileName: request.body?.fileName ? String(request.body.fileName) : null,
        attachments: Array.isArray(request.body?.attachments) ? request.body.attachments : null,
        assignedTo: request.body?.assignedTo ? String(request.body.assignedTo) : null,
        parentId: request.body?.parentId ? String(request.body.parentId) : null,
        status: request.body?.status ? String(request.body.status) : 'todo',
        priority: request.body?.priority ? String(request.body.priority) : 'medium',
      });
      broadcastTasks(id);
      return { item, items: listTaskItems(id) };
    } catch (err) {
      const message = err.message || 'could not create task';
      const code = message === 'forbidden' ? 403 : 400;
      return reply.code(code).send({ error: message });
    }
  });

  app.patch('/tasks/:id', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    const { id } = request.params;
    const before = db.prepare('SELECT * FROM task_items WHERE id = ?').get(id);
    try {
      const item = updateTaskItem(id, user.id, {
        body: request.body?.body,
        done: request.body?.done,
        doneConfirmed: request.body?.doneConfirmed,
        status: request.body?.status,
        priority: request.body?.priority,
        assignedTo: request.body?.assignedTo,
        pinned: request.body?.pinned,
        mediaUrl: request.body?.mediaUrl,
        mimeType: request.body?.mimeType,
        fileName: request.body?.fileName,
        attachments: Array.isArray(request.body?.attachments)
          ? request.body.attachments
          : request.body?.attachments === null
            ? []
            : undefined,
        clearMedia: request.body?.clearMedia === true,
      });
      broadcastTasks(item.conversationId);

      // Notify a newly assigned member (not the actor themselves).
      const newAssignee = request.body?.assignedTo
        ? String(request.body.assignedTo)
        : null;
      if (
        newAssignee &&
        before &&
        String(before.assigned_to || '') !== newAssignee &&
        newAssignee !== user.id
      ) {
        const assignee = getUserById(newAssignee);
        const actorName = user.displayName || user.handle || 'Someone';
        const assigneeName = assignee?.display_name || assignee?.handle || '';
        const title = assigneeName
          ? `${actorName} assigned you a task`
          : 'You were assigned a task';
        const bodyText = (item.body || '').slice(0, 120);
        broadcastToUsers([newAssignee], {
          type: 'notify',
          conversationId: item.conversationId,
          taskId: item.id,
          title,
          body: bodyText,
          kind: 'task.assigned',
        });
        if (!isOnline(newAssignee)) {
          void pushToUser(newAssignee, {
            title,
            body: bodyText,
            data: {
              type: 'task.assigned',
              conversationId: item.conversationId,
              taskId: item.id,
            },
          });
        }
      }

      return { item, items: listTaskItems(item.conversationId) };
    } catch (err) {
      const message = err.message || 'could not update task';
      const code =
        message === 'forbidden' ? 403 : message === 'not found' ? 404 : 400;
      return reply.code(code).send({ error: message });
    }
  });

  app.delete('/tasks/:id', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    const { id } = request.params;
    try {
      const result = deleteTaskItem(id, user.id);
      broadcastTasks(result.conversationId);
      return { ok: true, items: listTaskItems(result.conversationId) };
    } catch (err) {
      const message = err.message || 'could not delete task';
      const code =
        message === 'forbidden' ? 403 : message === 'not found' ? 404 : 400;
      return reply.code(code).send({ error: message });
    }
  });

  app.get('/tasks/:id/activity', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    const { id } = request.params;
    const task = db.prepare('SELECT * FROM task_items WHERE id = ?').get(id);
    if (!task) return reply.code(404).send({ error: 'not found' });
    if (!userInConversation(task.conversation_id, user.id)) {
      return reply.code(403).send({ error: 'forbidden' });
    }
    const limit = request.query?.limit;
    return { items: listTaskActivity(id, { limit }) };
  });

  app.post('/conversations/:id/tasks/clear-done', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    const { id } = request.params;
    try {
      const items = clearDoneTaskItems(id, user.id);
      broadcastTasks(id);
      return { items };
    } catch (err) {
      const message = err.message || 'could not clear tasks';
      const code = message === 'forbidden' ? 403 : 400;
      return reply.code(code).send({ error: message });
    }
  });

  app.post('/conversations/:id/tasks/unpin-all', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    const { id } = request.params;
    try {
      const items = unpinAllTasks(id, user.id);
      broadcastTasks(id);
      return { items };
    } catch (err) {
      const message = err.message || 'could not unpin tasks';
      const code = message === 'forbidden' ? 403 : 400;
      return reply.code(code).send({ error: message });
    }
  });

  // Payment reminders
  app.get('/conversations/:id/reminders', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    const { id } = request.params;
    if (!userInConversation(id, user.id)) return reply.code(403).send({ error: 'forbidden' });
    return { items: listReminders(id) };
  });

  app.get('/conversations/:id/reminders/history', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    const { id } = request.params;
    if (!userInConversation(id, user.id)) return reply.code(403).send({ error: 'forbidden' });
    return { items: listReminderHistory(id) };
  });

  app.post('/conversations/:id/reminders', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    const { id } = request.params;
    try {
      const kind = request.body?.kind === 'reminder' ? 'reminder' : 'payment';
      const rawCents = request.body?.amountCents;
      const item = createReminder({
        conversationId: id,
        createdBy: user.id,
        kind,
        amountCents: kind === 'payment' && rawCents != null ? Number(rawCents) : null,
        currency: request.body?.currency || 'USD',
        direction: request.body?.direction || 'owe',
        note: request.body?.note || '',
        dueDate: String(request.body?.dueDate || ''),
      });
      broadcastReminders(id);
      return { item, items: listReminders(id) };
    } catch (err) {
      const message = err.message || 'could not create reminder';
      const code = message === 'forbidden' ? 403 : 400;
      return reply.code(code).send({ error: message });
    }
  });

  app.patch('/reminders/:id', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    const { id } = request.params;
    try {
      const item = updateReminder(id, user.id, {
        amountCents: request.body?.amountCents !== undefined ? Number(request.body.amountCents) : undefined,
        currency: request.body?.currency,
        direction: request.body?.direction,
        note: request.body?.note,
        dueDate: request.body?.dueDate,
        paid: request.body?.paid,
        paidBy: user.id,
        snoozedUntil: request.body?.snoozedUntil,
        pinned: request.body?.pinned,
      });
      broadcastReminders(item.conversationId);
      return { item, items: listReminders(item.conversationId) };
    } catch (err) {
      const message = err.message || 'could not update reminder';
      const code = message === 'forbidden' ? 403 : message === 'not found' ? 404 : 400;
      return reply.code(code).send({ error: message });
    }
  });

  app.delete('/reminders/:id', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    const { id } = request.params;
    try {
      const result = deleteReminder(id, user.id);
      broadcastReminders(result.conversationId);
      return { ok: true, items: listReminders(result.conversationId) };
    } catch (err) {
      const message = err.message || 'could not delete reminder';
      const code = message === 'forbidden' ? 403 : message === 'not found' ? 404 : 400;
      return reply.code(code).send({ error: message });
    }
  });

  app.post('/reminders/:id/expenses', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    const { id } = request.params;
    try {
      const result = createExpense({
        paymentId: id,
        userId: user.id,
        label: request.body?.label || '',
        amountCents: request.body?.amountCents,
      });
      broadcastReminders(result.conversationId);
      return {
        expense: result.expense,
        items: listReminders(result.conversationId),
        history: listReminderHistory(result.conversationId),
      };
    } catch (err) {
      const message = err.message || 'could not create expense';
      const code = message === 'forbidden' ? 403 : message === 'not found' ? 404 : 400;
      return reply.code(code).send({ error: message });
    }
  });

  app.patch('/expenses/:id', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    const { id } = request.params;
    try {
      const result = updateExpense(id, user.id, {
        label: request.body?.label,
        amountCents: request.body?.amountCents !== undefined
          ? Number(request.body.amountCents)
          : undefined,
      });
      broadcastReminders(result.conversationId);
      return {
        expense: result.expense,
        items: listReminders(result.conversationId),
        history: listReminderHistory(result.conversationId),
      };
    } catch (err) {
      const message = err.message || 'could not update expense';
      const code = message === 'forbidden' ? 403 : message === 'not found' ? 404 : 400;
      return reply.code(code).send({ error: message });
    }
  });

  app.delete('/expenses/:id', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;
    const { id } = request.params;
    try {
      const result = deleteExpense(id, user.id);
      broadcastReminders(result.conversationId);
      return {
        ok: true,
        items: listReminders(result.conversationId),
        history: listReminderHistory(result.conversationId),
      };
    } catch (err) {
      const message = err.message || 'could not delete expense';
      const code = message === 'forbidden' ? 403 : message === 'not found' ? 404 : 400;
      return reply.code(code).send({ error: message });
    }
  });

  app.post('/uploads', async (request, reply) => {
    const user = await requireUser(request, reply);
    if (!user) return;

    const file = await request.file();
    if (!file) return reply.code(400).send({ error: 'file required' });

    const mime = file.mimetype || 'application/octet-stream';
    const original = path.basename(file.filename || 'file').slice(0, 180);
    const ext = path.extname(original).slice(0, 16);
    const stored = `${uuid()}${ext}`;
    const dest = path.join(uploadsDir, stored);

    try {
      await pipeline(file.file, createWriteStream(dest));
    } catch (err) {
      try {
        fs.unlinkSync(dest);
      } catch {
        /* ignore */
      }
      if (err.code === 'FST_REQ_FILE_TOO_LARGE') {
        return reply.code(413).send({ error: 'File too large (max 80MB)' });
      }
      throw err;
    }

    if (file.file.truncated) {
      try {
        fs.unlinkSync(dest);
      } catch {
        /* ignore */
      }
      return reply.code(413).send({ error: 'File too large (max 80MB)' });
    }

    const stat = fs.statSync(dest);
    const asVoice = String(request.query.as || '') === 'voice';
    const kind = kindFromMime(mime, asVoice ? 'voice' : 'file');
    const mediaUrl = `/media/${stored}`;

    return {
      mediaUrl,
      mimeType: mime,
      fileName: original,
      fileSize: stat.size,
      kind,
    };
  });
}
