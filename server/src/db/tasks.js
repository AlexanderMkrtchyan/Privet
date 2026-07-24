import { v4 as uuid } from 'uuid';
import { db, publicUser } from '../db.js';
import { getUserById } from '../auth/users.js';
import { userInConversation } from './chat.js';

function mapItem(row) {
  if (!row) return null;
  const creator = row.created_by ? getUserById(row.created_by) : null;
  return {
    id: row.id,
    conversationId: row.conversation_id,
    body: row.body || '',
    done: !!row.done,
    sortOrder: row.sort_order,
    messageId: row.message_id || null,
    mediaUrl: row.media_url || null,
    mimeType: row.mime_type || null,
    fileName: row.file_name || null,
    createdBy: creator ? publicUser(creator) : null,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

export function listTaskItems(conversationId) {
  const rows = db
    .prepare(
      `
      SELECT * FROM task_items
      WHERE conversation_id = ?
      ORDER BY sort_order ASC, created_at ASC
    `,
    )
    .all(conversationId);
  return rows.map(mapItem);
}

export function getTaskItem(id) {
  const row = db.prepare('SELECT * FROM task_items WHERE id = ?').get(id);
  return mapItem(row);
}

export function createTaskItem({
  conversationId,
  createdBy,
  body,
  messageId = null,
  mediaUrl = null,
  mimeType = null,
  fileName = null,
}) {
  const text = String(body || '').trim();
  if (!text && !mediaUrl) {
    throw new Error('empty task');
  }
  if (!userInConversation(conversationId, createdBy)) {
    throw new Error('forbidden');
  }

  const maxOrder = db
    .prepare(
      'SELECT COALESCE(MAX(sort_order), 0) AS m FROM task_items WHERE conversation_id = ?',
    )
    .get(conversationId).m;

  const id = uuid();
  const now = new Date().toISOString();
  db.prepare(
    `
    INSERT INTO task_items (
      id, conversation_id, body, done, sort_order, message_id,
      media_url, mime_type, file_name, created_by, created_at, updated_at
    ) VALUES (?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?)
  `,
  ).run(
    id,
    conversationId,
    text || (fileName ? String(fileName) : 'Attachment'),
    maxOrder + 1,
    messageId || null,
    mediaUrl || null,
    mimeType || null,
    fileName || null,
    createdBy,
    now,
    now,
  );

  return getTaskItem(id);
}

export function updateTaskItem(id, userId, patch) {
  const existing = db.prepare('SELECT * FROM task_items WHERE id = ?').get(id);
  if (!existing) throw new Error('not found');
  if (!userInConversation(existing.conversation_id, userId)) {
    throw new Error('forbidden');
  }

  let body = existing.body;
  let done = existing.done;
  let mediaUrl = existing.media_url;
  let mimeType = existing.mime_type;
  let fileName = existing.file_name;

  if (patch.body !== undefined) {
    body = String(patch.body || '').trim();
    if (!body && !mediaUrl && !patch.mediaUrl) {
      throw new Error('empty task');
    }
  }
  if (patch.done !== undefined) {
    done = patch.done ? 1 : 0;
  }
  if (patch.mediaUrl !== undefined) {
    mediaUrl = patch.mediaUrl ? String(patch.mediaUrl) : null;
    mimeType = patch.mimeType ? String(patch.mimeType) : null;
    fileName = patch.fileName ? String(patch.fileName) : null;
  }
  if (patch.clearMedia === true) {
    mediaUrl = null;
    mimeType = null;
    fileName = null;
  }

  const now = new Date().toISOString();
  db.prepare(
    `
    UPDATE task_items
    SET body = ?, done = ?, media_url = ?, mime_type = ?, file_name = ?, updated_at = ?
    WHERE id = ?
  `,
  ).run(body, done, mediaUrl, mimeType, fileName, now, id);

  return getTaskItem(id);
}

export function deleteTaskItem(id, userId) {
  const existing = db.prepare('SELECT * FROM task_items WHERE id = ?').get(id);
  if (!existing) throw new Error('not found');
  if (!userInConversation(existing.conversation_id, userId)) {
    throw new Error('forbidden');
  }
  db.prepare('DELETE FROM task_items WHERE id = ?').run(id);
  return {
    conversationId: existing.conversation_id,
    deletedId: id,
  };
}

export function clearDoneTaskItems(conversationId, userId) {
  if (!userInConversation(conversationId, userId)) {
    throw new Error('forbidden');
  }
  db.prepare(
    'DELETE FROM task_items WHERE conversation_id = ? AND done = 1',
  ).run(conversationId);
  return listTaskItems(conversationId);
}
