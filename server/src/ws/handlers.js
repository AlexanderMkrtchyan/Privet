import { v4 as uuid } from 'uuid';
import {
  createMessage,
  editMessage,
  listMembers,
  listMessages,
  markConversationRead,
  memberIds,
  softDeleteMessage,
  toggleReaction,
  userInConversation,
  getMessage,
  setMessageLinkPreview,
  isConversationMuted,
} from '../db/chat.js';
import { publicUser, db } from '../db.js';
import { getUserById, touchLastSeen } from '../auth/users.js';
import { isBlockedEitherWay } from '../db/blocks.js';
import {
  bindSocket,
  broadcastToUsers,
  isOnline,
  lastSeenMap,
  noteLastSeen,
  onlineUserIds,
  sendToSocket,
  sendToUser,
  sendToUserPreferred,
  touchSocket,
} from './hub.js';
import {
  extractFirstUrl,
  fetchLinkPreview,
} from '../media/linkPreview.js';
import { noteConversationMessage, shouldAcceptMarkRead } from '../readGate.js';
import { pushToUser } from '../push/fcm.js';
import {
  buildControlSignalOutbound,
  canGrantControl,
  canRelayCallSignal,
  canRequestControl,
} from './call_auth.js';

const MEDIA_KINDS = new Set(['image', 'video', 'audio', 'voice', 'file', 'album']);

/** @type {Map<string, number>} */
const typingLastSent = new Map();
let presenceTimer = null;

function notifyMessage(message, { excludeUserId } = {}) {
  const title = message.sender.displayName || message.sender.handle || 'Privet';
  const body =
    message.kind === 'text'
      ? message.body.slice(0, 140)
      : message.kind === 'ai'
        ? (() => {
            try {
              const parsed = JSON.parse(message.body || '');
              const a = String(parsed?.a || '').trim();
              const q = String(parsed?.q || '').trim();
              const bit = a || q || 'Privet AI';
              return `✦ ${bit.slice(0, 120)}`;
            } catch {
              return `✦ ${(message.body || 'Privet AI').slice(0, 120)}`;
            }
          })()
        : message.kind === 'image'
          ? '📷 Photo'
          : message.kind === 'video'
            ? '🎬 Video'
            : message.kind === 'voice'
              ? '🎤 Voice message'
              : message.kind === 'audio'
                ? '🎵 Audio'
                : message.kind === 'album'
                  ? '📎 Album'
                  : message.fileName || '📎 File';

  const recipients = memberIds(message.conversationId).filter(
    (id) => id !== excludeUserId && id !== message.sender.id,
  );
  for (const uid of recipients) {
    if (isConversationMuted(message.conversationId, uid)) continue;
    if (isBlockedEitherWay(uid, message.sender.id)) continue;
    sendToUser(uid, {
      type: 'notify',
      conversationId: message.conversationId,
      title,
      body,
      messageId: message.id,
    });
    // Push when user has no live socket (background / killed app).
    if (!isOnline(uid)) {
      void pushToUser(uid, {
        title,
        body,
        data: {
          conversationId: message.conversationId,
          messageId: message.id,
        },
      });
    }
  }
}

async function maybeAttachLinkPreview(message) {
  if (!message || message.kind !== 'text' || !message.body) return;
  if (message.linkPreview) return;
  const url = extractFirstUrl(message.body);
  if (!url) return;
  const preview = await fetchLinkPreview(url);
  if (!preview) return;
  const updated = setMessageLinkPreview(message.id, preview);
  if (!updated) return;
  broadcastToUsers(memberIds(updated.conversationId), {
    type: 'message.updated',
    message: updated,
  });
}

/** @type {Map<string, {
 *   id: string,
 *   conversationId: string,
 *   mode: string,
 *   fromUserId: string,
 *   toUserId: string,
 *   createdAt: number,
 *   status: 'ringing' | 'active',
 *   fromSocket?: import('ws').WebSocket,
 *   toSocket?: import('ws').WebSocket,
 *   controlGrantedTo?: string | null,
 * }>} */
const calls = new Map();

/** @type {Map<string, ReturnType<typeof setTimeout>>} */
const ringTimers = new Map();

function clearRingTimer(callId) {
  const t = ringTimers.get(callId);
  if (t) {
    clearTimeout(t);
    ringTimers.delete(callId);
  }
}

/** Wire-safe call payload (never include timers or sockets). */
function publicCall(call) {
  return {
    id: call.id,
    conversationId: call.conversationId,
    mode: call.mode,
    fromUserId: call.fromUserId,
    toUserId: call.toUserId,
    createdAt: call.createdAt,
  };
}

function peerSocket(call, userId) {
  if (!call) return null;
  if (userId === call.fromUserId) return call.toSocket || null;
  if (userId === call.toUserId) return call.fromSocket || null;
  return null;
}

function clearControl(call) {
  if (call) call.controlGrantedTo = null;
}

function endCallForBoth(call, reason) {
  if (!call) return;
  clearRingTimer(call.id);
  clearControl(call);
  calls.delete(call.id);
  const ended = { type: 'call.ended', callId: call.id, reason };
  sendToUserPreferred(call.fromUserId, call.fromSocket, ended);
  sendToUserPreferred(call.toUserId, call.toSocket, ended);
}

export function registerWebsocket(app) {
  app.get('/ws', { websocket: true }, (socket, request) => {
    let userId = null;

    socket.on('message', async (raw) => {
      let msg;
      try {
        msg = JSON.parse(String(raw));
      } catch {
        socket.send(JSON.stringify({ type: 'error', error: 'bad json' }));
        return;
      }

      try {
        if (msg.type === 'auth') {
          const decoded = app.jwt.verify(msg.token);
          userId = decoded.sub;
          bindSocket(userId, socket);
          const online = onlineUserIds();
          socket.send(
            JSON.stringify({
              type: 'auth.ok',
              userId,
              online,
              lastSeen: lastSeenMap(
                db.prepare('SELECT id FROM users').all().map((r) => r.id),
              ),
            }),
          );
          broadcastPresence();
          return;
        }

        if (!userId) {
          socket.send(JSON.stringify({ type: 'error', error: 'auth required' }));
          return;
        }

        // Any inbound traffic from this tab makes it the sound primary.
        touchSocket(userId, socket);

        if (msg.type === 'typing') {
          const { conversationId } = msg;
          if (!conversationId || !userInConversation(conversationId, userId)) return;
          const key = `${userId}:${conversationId}`;
          const now = Date.now();
          const last = typingLastSent.get(key) || 0;
          // Stay under the client throttle (~800ms) so RTT cannot drop pulses.
          if (now - last < 500) return;
          typingLastSent.set(key, now);
          broadcastToUsers(
            memberIds(conversationId),
            { type: 'typing', conversationId, userId },
            userId,
          );
          return;
        }

        if (msg.type === 'message.send') {
          const {
            conversationId,
            body,
            kind = 'text',
            clientId,
            mediaUrl,
            mimeType,
            fileName,
            fileSize,
            replyToId,
            replyQuote,
            attachments,
            forwardFromId,
          } = msg;
          if (!conversationId || !userInConversation(conversationId, userId)) {
            socket.send(JSON.stringify({ type: 'error', error: 'forbidden' }));
            return;
          }
          const text = String(body || '').trim();
          const media = mediaUrl ? String(mediaUrl) : null;
          const cleanAttachments = Array.isArray(attachments)
            ? attachments
                .map((item) => ({
                  mediaUrl: item?.mediaUrl ? String(item.mediaUrl) : null,
                  mimeType: item?.mimeType ? String(item.mimeType) : null,
                  fileName: item?.fileName ? String(item.fileName) : null,
                  fileSize:
                    typeof item?.fileSize === 'number' ? item.fileSize : null,
                  kind: item?.kind ? String(item.kind) : 'file',
                }))
                .filter(
                  (item) =>
                    item.mediaUrl && item.mediaUrl.startsWith('/media/'),
                )
            : [];
          const forwarding = !!forwardFromId;
          if (!forwarding && !text && !media && cleanAttachments.length === 0) {
            return;
          }
          if (!forwarding && kind === 'album' && cleanAttachments.length < 2) {
            socket.send(
              JSON.stringify({
                type: 'error',
                error: 'album requires at least 2 attachments',
              }),
            );
            return;
          }
          if (
            !forwarding &&
            MEDIA_KINDS.has(kind) &&
            !media &&
            cleanAttachments.length === 0
          ) {
            socket.send(JSON.stringify({ type: 'error', error: 'mediaUrl required' }));
            return;
          }
          if (media && !media.startsWith('/media/')) {
            socket.send(JSON.stringify({ type: 'error', error: 'invalid mediaUrl' }));
            return;
          }

          try {
            const message = createMessage({
              conversationId,
              senderId: userId,
              body: text,
              kind,
              mediaUrl: media || cleanAttachments[0]?.mediaUrl || null,
              mimeType: mimeType
                ? String(mimeType)
                : cleanAttachments[0]?.mimeType || null,
              fileName: fileName
                ? String(fileName)
                : cleanAttachments[0]?.fileName || null,
              fileSize:
                typeof fileSize === 'number'
                  ? fileSize
                  : cleanAttachments[0]?.fileSize ?? null,
              replyToId: replyToId ? String(replyToId) : null,
              replyQuote: replyQuote ? String(replyQuote) : null,
              attachments: cleanAttachments,
              forwardFromId: forwardFromId ? String(forwardFromId) : null,
            });

            broadcastToUsers(
              memberIds(conversationId),
              {
                type: 'message',
                message,
                clientId,
              },
              null,
              { soundOnce: true },
            );
            noteConversationMessage(conversationId);
            notifyMessage(message, { excludeUserId: userId });
            // Teams-style: deliver text first, then unfurl OG metadata.
            void maybeAttachLinkPreview(message);
          } catch (err) {
            socket.send(
              JSON.stringify({
                type: 'error',
                error: err.message || 'send failed',
              }),
            );
          }
          return;
        }

        if (msg.type === 'message.edit') {
          const { messageId, body } = msg;
          if (!messageId) return;
          const existing = getMessage(messageId);
          if (!existing || !userInConversation(existing.conversationId, userId)) {
            socket.send(JSON.stringify({ type: 'error', error: 'forbidden' }));
            return;
          }
          try {
            const message = editMessage({
              messageId,
              userId,
              body,
            });
            broadcastToUsers(memberIds(message.conversationId), {
              type: 'message.updated',
              message,
            });
          } catch (err) {
            socket.send(
              JSON.stringify({
                type: 'error',
                error: err.message || 'edit failed',
              }),
            );
          }
          return;
        }

        if (msg.type === 'message.delete') {
          const { messageId } = msg;
          if (!messageId) return;
          const existing = getMessage(messageId);
          if (!existing || !userInConversation(existing.conversationId, userId)) {
            socket.send(JSON.stringify({ type: 'error', error: 'forbidden' }));
            return;
          }
          try {
            const message = softDeleteMessage({ messageId, userId });
            broadcastToUsers(memberIds(message.conversationId), {
              type: 'message.updated',
              message,
            });
          } catch (err) {
            socket.send(
              JSON.stringify({
                type: 'error',
                error: err.message || 'delete failed',
              }),
            );
          }
          return;
        }

        if (msg.type === 'conversation.read') {
          const { conversationId, messageId, focused } = msg;
          if (!conversationId || !userInConversation(conversationId, userId)) {
            return;
          }
          // Ignore instant auto-acks from idle windows (old clients mark-read
          // the moment a message arrives even when the tab isn't in use).
          if (
            !shouldAcceptMarkRead(conversationId, { focused: focused === true })
          ) {
            return;
          }
          try {
            const result = markConversationRead(
              conversationId,
              userId,
              messageId ? String(messageId) : null,
            );
            broadcastToUsers(memberIds(conversationId), {
              type: 'conversation.read',
              ...result,
            });
          } catch {
            // ignore
          }
          return;
        }

        if (msg.type === 'reaction.toggle') {
          const { messageId, emoji } = msg;
          if (!messageId || !emoji) return;
          const existing = getMessage(messageId);
          if (!existing || !userInConversation(existing.conversationId, userId)) {
            socket.send(JSON.stringify({ type: 'error', error: 'forbidden' }));
            return;
          }
          try {
            const result = toggleReaction({
              messageId,
              userId,
              emoji: String(emoji),
            });
            broadcastToUsers(memberIds(result.conversationId), {
              type: 'message.updated',
              message: result.message,
            });
          } catch (err) {
            socket.send(
              JSON.stringify({
                type: 'error',
                error: err.message || 'reaction failed',
              }),
            );
          }
          return;
        }

        if (msg.type === 'messages.sync') {
          const { conversationId } = msg;
          if (!conversationId || !userInConversation(conversationId, userId)) return;
          sendToUser(userId, {
            type: 'messages',
            conversationId,
            messages: listMessages(conversationId),
          });
          return;
        }

        // —— Call signaling (1:1) ——
        if (msg.type === 'call.invite') {
          const { conversationId, toUserId, mode = 'video' } = msg;
          if (!conversationId || !toUserId) return;
          if (!userInConversation(conversationId, userId)) {
            socket.send(JSON.stringify({ type: 'error', error: 'forbidden' }));
            return;
          }
          if (!userInConversation(conversationId, toUserId)) {
            socket.send(JSON.stringify({ type: 'error', error: 'peer not in chat' }));
            return;
          }
          const callId = uuid();
          const call = {
            id: callId,
            conversationId,
            mode:
              mode === 'audio'
                ? 'audio'
                : mode === 'screen'
                  ? 'screen'
                  : mode === 'control'
                    ? 'control'
                    : 'video',
            fromUserId: userId,
            toUserId,
            createdAt: Date.now(),
            status: 'ringing',
            fromSocket: socket,
            toSocket: undefined,
            controlGrantedTo: null,
          };
          // Auto-expire unanswered invites only — never kill an accepted call.
          // Timer kept in a separate map so JSON.stringify(call) never sees it
          // (Node Timeout is circular and would silently break invites).
          ringTimers.set(
            callId,
            setTimeout(() => {
              const c = calls.get(callId);
              if (!c || c.status !== 'ringing') return;
              endCallForBoth(c, 'timeout');
            }, 60000),
          );
          calls.set(callId, call);
          const from = publicUser(getUserById(userId));
          const payload = publicCall(call);
          // Ring all of callee's devices; media will bind the accepting socket.
          sendToUser(toUserId, {
            type: 'call.incoming',
            call: payload,
            from,
          });
          sendToSocket(socket, { type: 'call.ringing', call: payload });
          return;
        }

        if (msg.type === 'call.accept') {
          const call = calls.get(msg.callId);
          if (!call || call.toUserId !== userId) return;
          if (call.status !== 'ringing') return;
          call.status = 'active';
          call.toSocket = socket;
          clearRingTimer(call.id);
          const accepted = {
            type: 'call.accepted',
            callId: call.id,
            byUserId: userId,
          };
          sendToUserPreferred(call.fromUserId, call.fromSocket, accepted);
          sendToSocket(socket, accepted);
          return;
        }

        if (msg.type === 'call.reject') {
          const call = calls.get(msg.callId);
          if (!call) return;
          if (userId !== call.toUserId && userId !== call.fromUserId) return;
          endCallForBoth(call, 'rejected');
          return;
        }

        if (msg.type === 'call.hangup') {
          const call = calls.get(msg.callId);
          if (!call) {
            if (msg.toUserId) {
              sendToUser(msg.toUserId, {
                type: 'call.ended',
                callId: msg.callId,
                reason: 'hangup',
              });
            }
            return;
          }
          if (userId !== call.toUserId && userId !== call.fromUserId) return;
          endCallForBoth(call, 'hangup');
          return;
        }

        if (
          msg.type === 'call.offer' ||
          msg.type === 'call.answer' ||
          msg.type === 'call.ice' ||
          msg.type === 'call.share_stopped' ||
          msg.type === 'call.share_started'
        ) {
          const { toUserId, callId } = msg;
          if (!toUserId || !callId) return;
          const call = calls.get(callId);
          if (!canRelayCallSignal(call, userId, toUserId)) return;
          // Refresh the sender's bound socket so mid-call reconnects stick.
          if (userId === call.fromUserId) call.fromSocket = socket;
          if (userId === call.toUserId) call.toSocket = socket;
          if (msg.type === 'call.share_stopped') {
            clearControl(call);
          }
          const preferred = peerSocket(call, userId);
          sendToUserPreferred(toUserId, preferred, {
            ...msg,
            fromUserId: userId,
            callId,
          });
          return;
        }

        if (
          msg.type === 'call.control_request' ||
          msg.type === 'call.control_grant' ||
          msg.type === 'call.control_deny' ||
          msg.type === 'call.control_revoke'
        ) {
          const { toUserId, callId } = msg;
          if (!toUserId || !callId) return;
          const call = calls.get(callId);
          if (!canRelayCallSignal(call, userId, toUserId)) return;
          if (userId === call.fromUserId) call.fromSocket = socket;
          if (userId === call.toUserId) call.toSocket = socket;

          if (msg.type === 'call.control_request') {
            if (!canRequestControl(call, userId, toUserId)) return;
          }
          if (msg.type === 'call.control_grant') {
            if (!canGrantControl(call, userId, toUserId)) return;
            // Granting user is the host; controller is the peer.
            call.controlGrantedTo = toUserId;
          }
          if (msg.type === 'call.control_deny' || msg.type === 'call.control_revoke') {
            clearControl(call);
          }

          const preferred = peerSocket(call, userId);
          sendToUserPreferred(
            toUserId,
            preferred,
            buildControlSignalOutbound(msg, {
              callId,
              fromUserId: userId,
              toUserId,
            }),
          );
          return;
        }

        if (msg.type === 'members.list') {
          const { conversationId } = msg;
          if (!conversationId || !userInConversation(conversationId, userId)) return;
          sendToUser(userId, {
            type: 'members',
            conversationId,
            members: listMembers(conversationId),
          });
        }
      } catch (err) {
        socket.send(
          JSON.stringify({ type: 'error', error: err.message || 'ws error' }),
        );
      }
    });

    socket.on('close', () => {
      if (!userId) return;
      if (!isOnline(userId)) {
        touchLastSeen(userId);
        const at = new Date().toISOString().replace('T', ' ').slice(0, 19);
        noteLastSeen(userId, at);
      }
      broadcastPresence();
    });
  });
}

function broadcastPresence() {
  // Debounce fan-out: multi-tab connect/disconnect otherwise storms every client.
  if (presenceTimer) return;
  presenceTimer = setTimeout(() => {
    presenceTimer = null;
    broadcastPresenceNow();
  }, 250);
}

function broadcastPresenceNow() {
  const online = onlineUserIds();
  const allIds = db.prepare('SELECT id, last_seen_at FROM users').all();
  for (const row of allIds) {
    if (row.last_seen_at) noteLastSeen(row.id, row.last_seen_at);
  }
  const lastSeen = lastSeenMap(allIds.map((r) => r.id));
  for (const id of online) {
    sendToUser(id, { type: 'presence', online, lastSeen });
  }
}
