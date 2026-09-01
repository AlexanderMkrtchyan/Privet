import { v4 as uuid } from 'uuid';
import { db, publicUser } from '../db.js';
import { getUserById } from '../auth/users.js';
import { userInConversation } from './chat.js';

const MAX_TASK_ATTACHMENTS = 10;

export const TASK_STATUSES = ['todo', 'in_progress', 'review', 'done'];
export const TASK_PRIORITIES = ['lowest', 'low', 'medium', 'high', 'highest'];

export const PRIORITY_WEIGHT = {
  lowest: 0,
  low: 1,
  medium: 2,
  high: 3,
  highest: 4,
};

const VALID_STATUS = new Set(TASK_STATUSES);
const VALID_PRIORITY = new Set(TASK_PRIORITIES);

function normalizeStatus(value) {
  const s = String(value || 'todo').toLowerCase().replace(/_/g, '_');
  return VALID_STATUS.has(s) ? s : 'todo';
}

function normalizePriority(value) {
  const p = String(value || 'medium').toLowerCase();
  return VALID_PRIORITY.has(p) ? p : 'medium';
}

function logActivity({
  taskId,
  conversationId,
  userId,
  action,
  fromValue = null,
  toValue = null,
}) {
  db.prepare(
    `INSERT INTO task_activity (id, task_id, conversation_id, user_id, action, from_value, to_value)
     VALUES (?, ?, ?, ?, ?, ?, ?)`,
  ).run(uuid(), taskId, conversationId, userId || null, action, fromValue, toValue);
}

function kindFromMime(mimeType, fileName) {
  const mime = String(mimeType || '').toLowerCase();
  if (mime.startsWith('image/')) return 'image';
  if (mime.startsWith('video/')) return 'video';
  if (mime.startsWith('audio/')) return 'audio';
  const name = String(fileName || '').toLowerCase();
  if (/\.(png|jpe?g|gif|webp|bmp|heic)$/.test(name)) return 'image';
  if (/\.(mp4|webm|mov|mkv)$/.test(name)) return 'video';
  if (/\.(mp3|wav|ogg|m4a|aac)$/.test(name)) return 'audio';
  return 'file';
}

function normalizeAttachments(raw, { mediaUrl, mimeType, fileName } = {}) {
  let list = [];
  if (Array.isArray(raw)) {
    list = raw;
  } else if (typeof raw === 'string' && raw.trim()) {
    try {
      const parsed = JSON.parse(raw);
      if (Array.isArray(parsed)) list = parsed;
    } catch {
      list = [];
    }
  }

  const out = [];
  for (const item of list) {
    if (!item || typeof item !== 'object') continue;
    const url = item.mediaUrl ? String(item.mediaUrl) : '';
    if (!url) continue;
    const mime = item.mimeType ? String(item.mimeType) : null;
    const name = item.fileName ? String(item.fileName) : null;
    out.push({
      mediaUrl: url,
      mimeType: mime,
      fileName: name,
      kind: item.kind ? String(item.kind) : kindFromMime(mime, name),
      ...(item.fileSize != null ? { fileSize: Number(item.fileSize) || 0 } : {}),
    });
    if (out.length >= MAX_TASK_ATTACHMENTS) break;
  }

  // Legacy single-file columns → attach list for older clients / rows.
  if (out.length === 0 && mediaUrl) {
    out.push({
      mediaUrl: String(mediaUrl),
      mimeType: mimeType ? String(mimeType) : null,
      fileName: fileName ? String(fileName) : null,
      kind: kindFromMime(mimeType, fileName),
    });
  }
  return out;
}

function serializeAttachments(list) {
  if (!list || list.length === 0) return null;
  return JSON.stringify(list.slice(0, MAX_TASK_ATTACHMENTS));
}

function mapItem(row) {
  if (!row) return null;
  const creator = row.created_by ? getUserById(row.created_by) : null;
  const assignee = row.assigned_to ? getUserById(row.assigned_to) : null;
  const attachments = normalizeAttachments(row.attachments, {
    mediaUrl: row.media_url,
    mimeType: row.mime_type,
    fileName: row.file_name,
  });
  const primary = attachments[0] || null;
  // Prefer the explicit status column; fall back to legacy booleans for rows
  // written before the migration ran.
  const status =
    row.status && row.status !== 'todo'
      ? row.status
      : row.done_confirmed
        ? 'done'
        : row.done
          ? 'review'
          : 'todo';
  return {
    id: row.id,
    conversationId: row.conversation_id,
    parentId: row.parent_id || null,
    body: row.body || '',
    status,
    priority: normalizePriority(row.priority),
    done: status === 'done',
    sortOrder: row.sort_order,
    messageId: row.message_id || null,
    mediaUrl: primary?.mediaUrl || row.media_url || null,
    mimeType: primary?.mimeType || row.mime_type || null,
    fileName: primary?.fileName || row.file_name || null,
    attachments,
    createdBy: creator ? publicUser(creator) : null,
    assignedTo: assignee ? publicUser(assignee) : null,
    pinned: !!row.pinned,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function nextSortOrder(conversationId, parentId = null) {
  if (parentId) {
    return db
      .prepare(
        `SELECT COALESCE(MAX(sort_order), 0) AS m FROM task_items
         WHERE conversation_id = ? AND parent_id = ?`,
      )
      .get(conversationId, parentId).m + 1;
  }
  return db
    .prepare(
      `SELECT COALESCE(MAX(sort_order), 0) AS m FROM task_items
       WHERE conversation_id = ? AND parent_id IS NULL`,
    )
    .get(conversationId).m + 1;
}

// Active tasks: everything not yet done (status workflow, Jira-style). Done
// tasks move to history; nothing blocks completion — any member can close.
export function listTaskItems(conversationId) {
  const roots = db
    .prepare(
      `SELECT * FROM task_items t
       WHERE t.conversation_id = ?
         AND t.parent_id IS NULL
         AND t.status != 'done'
       ORDER BY t.pinned DESC,
         CASE t.priority
           WHEN 'highest' THEN 4 WHEN 'high' THEN 3
           WHEN 'medium' THEN 2 WHEN 'low' THEN 1 ELSE 0
         END DESC,
         t.sort_order ASC, t.created_at ASC`,
    )
    .all(conversationId);

  const rootIds = roots.map((r) => r.id);
  let subtasks = [];
  if (rootIds.length > 0) {
    const placeholders = rootIds.map(() => '?').join(',');
    subtasks = db
      .prepare(
        `SELECT * FROM task_items
         WHERE parent_id IN (${placeholders})
         ORDER BY sort_order ASC, created_at ASC`,
      )
      .all(...rootIds);
  }

  const rows = [...roots, ...subtasks];

  const countRows = db
    .prepare(
      `SELECT parent_id, COUNT(*) AS total, SUM(done) AS done
       FROM task_items
       WHERE conversation_id = ? AND parent_id IS NOT NULL
       GROUP BY parent_id`,
    )
    .all(conversationId);
  const countsByParent = new Map(
    countRows.map((r) => [r.parent_id, { total: r.total, done: r.done || 0 }]),
  );

  return rows.map((row) => {
    const item = mapItem(row);
    if (!row.parent_id) {
      const c = countsByParent.get(row.id);
      if (c && c.total > 0) {
        item.subtaskDone = c.done;
        item.subtaskTotal = c.total;
      }
    }
    return item;
  });
}

// History: done tasks only.
export function listDoneTaskItems(conversationId, { limit = 20, before = null } = {}) {
  const lim = Math.min(Math.max(Number(limit) || 20, 1), 50);
  let sql = `
    SELECT * FROM task_items t
    WHERE t.conversation_id = ?
      AND t.parent_id IS NULL
      AND t.status = 'done'
  `;
  const params = [conversationId];
  if (before) {
    sql += ' AND updated_at < ?';
    params.push(String(before));
  }
  sql += ' ORDER BY updated_at DESC LIMIT ?';
  params.push(lim);

  const roots = db.prepare(sql).all(...params);
  if (roots.length === 0) {
    return { items: [], hasMore: false };
  }

  const ids = roots.map((r) => r.id);
  const placeholders = ids.map(() => '?').join(',');
  const subtasks = db
    .prepare(
      `SELECT * FROM task_items
       WHERE parent_id IN (${placeholders})
       ORDER BY sort_order ASC, created_at ASC`,
    )
    .all(...ids);

  const items = [...roots.map(mapItem), ...subtasks.map(mapItem)];
  return { items, hasMore: roots.length >= lim };
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
  attachments = null,
  assignedTo = null,
  parentId = null,
  status = 'todo',
  priority = 'medium',
}) {
  const text = String(body || '').trim();
  let attachList = normalizeAttachments(attachments, { mediaUrl, mimeType, fileName });
  if (attachList.length === 0 && mediaUrl) {
    attachList = normalizeAttachments(null, { mediaUrl, mimeType, fileName });
  }
  if (!text && attachList.length === 0) throw new Error('empty task');
  if (!userInConversation(conversationId, createdBy)) throw new Error('forbidden');

  let resolvedParentId = null;
  if (parentId) {
    const parent = db.prepare('SELECT * FROM task_items WHERE id = ?').get(parentId);
    if (!parent) throw new Error('parent not found');
    if (parent.conversation_id !== conversationId) throw new Error('forbidden');
    if (parent.parent_id) throw new Error('subtasks cannot nest');
    if (parent.status === 'done') throw new Error('parent archived');
    resolvedParentId = parent.id;
  }

  const sortOrder = nextSortOrder(conversationId, resolvedParentId);
  const id = uuid();
  const now = new Date().toISOString();
  const primary = attachList[0] || null;
  const fallbackName = primary?.fileName || (attachList.length > 1 ? `${attachList.length} files` : null);

  const taskStatus = normalizeStatus(status);
  const taskPriority = normalizePriority(priority);

  db.prepare(
    `INSERT INTO task_items (
       id, conversation_id, parent_id, body, done, done_confirmed, sort_order, message_id,
       media_url, mime_type, file_name, attachments, created_by, assigned_to, status, priority,
       created_at, updated_at
     ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).run(
    id,
    conversationId,
    resolvedParentId,
    text || fallbackName || 'Attachment',
    taskStatus === 'done' ? 1 : 0,
    taskStatus === 'done' ? 1 : 0,
    sortOrder,
    messageId || null,
    primary?.mediaUrl || null,
    primary?.mimeType || null,
    primary?.fileName || null,
    serializeAttachments(attachList),
    createdBy,
    assignedTo || null,
    taskStatus,
    taskPriority,
    now,
    now,
  );

  logActivity({
    taskId: id,
    conversationId,
    userId: createdBy,
    action: 'created',
    toValue: text || fallbackName || 'Attachment',
  });
  if (assignedTo) {
    logActivity({
      taskId: id,
      conversationId,
      userId: createdBy,
      action: 'assigned',
      toValue: assignedTo,
    });
  }

  return getTaskItem(id);
}

export function updateTaskItem(id, userId, patch) {
  const existing = db.prepare('SELECT * FROM task_items WHERE id = ?').get(id);
  if (!existing) throw new Error('not found');
  if (!userInConversation(existing.conversation_id, userId)) throw new Error('forbidden');

  let body = existing.body;
  let mediaUrl = existing.media_url;
  let mimeType = existing.mime_type;
  let fileName = existing.file_name;
  let attachmentsJson = existing.attachments;
  let assignedTo = existing.assigned_to;
  let pinned = existing.pinned;

  let status =
    existing.status && existing.status !== 'todo'
      ? existing.status
      : existing.done_confirmed
        ? 'done'
        : existing.done
          ? 'review'
          : 'todo';
  let priority = normalizePriority(existing.priority);

  let attachList = normalizeAttachments(attachmentsJson, { mediaUrl, mimeType, fileName });

  const activity = [];

  if (patch.body !== undefined) {
    body = String(patch.body || '').trim();
    if (!body && attachList.length === 0 && !patch.mediaUrl && !patch.attachments) {
      throw new Error('empty task');
    }
    if (body !== existing.body) {
      activity.push({ action: 'body', fromValue: existing.body || null, toValue: body });
    }
  }

  // New status workflow. Legacy patches (done / doneConfirmed) map onto it so
  // older clients keep working during rollout.
  let nextStatus = status;
  if (patch.status !== undefined) {
    nextStatus = normalizeStatus(patch.status);
  } else if (patch.doneConfirmed !== undefined) {
    nextStatus = patch.doneConfirmed ? 'done' : 'todo';
  } else if (patch.done !== undefined) {
    nextStatus = patch.done ? 'review' : 'todo';
  }
  if (nextStatus !== status) {
    activity.push({ action: 'status', fromValue: status, toValue: nextStatus });
    status = nextStatus;
  }

  let nextPriority = priority;
  if (patch.priority !== undefined) {
    nextPriority = normalizePriority(patch.priority);
    if (nextPriority !== priority) {
      activity.push({ action: 'priority', fromValue: priority, toValue: nextPriority });
      priority = nextPriority;
    }
  }

  // Marking a parent done cascades to its subtasks (matches the old
  // group-archive behavior: the whole board group closes together). The
  // cascade also logs each child's status change so the parent's activity feed
  // (which now surfaces subtask activity) tells the full story.
  if (status === 'done' && !existing.parent_id) {
    const children = db
      .prepare('SELECT * FROM task_items WHERE parent_id = ? AND status != ?')
      .all(id, 'done');
    if (children.length > 0) {
      db.prepare(
        `UPDATE task_items
         SET done = 1, done_confirmed = 1, status = 'done', pinned = 0, updated_at = ?
         WHERE parent_id = ? AND status != 'done'`,
      ).run(new Date().toISOString(), id);
      for (const child of children) {
        const childStatus =
          child.status && child.status !== 'todo'
            ? child.status
            : child.done_confirmed
              ? 'done'
              : child.done
                ? 'review'
                : 'todo';
        logActivity({
          taskId: child.id,
          conversationId: existing.conversation_id,
          userId,
          action: 'status',
          fromValue: childStatus,
          toValue: 'done',
        });
      }
    }
  }

  if (patch.attachments !== undefined) {
    attachList = normalizeAttachments(patch.attachments);
    const primary = attachList[0] || null;
    mediaUrl = primary?.mediaUrl || null;
    mimeType = primary?.mimeType || null;
    fileName = primary?.fileName || null;
    attachmentsJson = serializeAttachments(attachList);
  } else if (patch.mediaUrl !== undefined) {
    // Legacy single-file replace: keep remaining attachments if any, else set one.
    const next = {
      mediaUrl: patch.mediaUrl ? String(patch.mediaUrl) : null,
      mimeType: patch.mimeType ? String(patch.mimeType) : null,
      fileName: patch.fileName ? String(patch.fileName) : null,
      kind: kindFromMime(patch.mimeType, patch.fileName),
    };
    if (next.mediaUrl) {
      if (attachList.length === 0) {
        attachList = [next];
      } else {
        attachList = [next, ...attachList.slice(1)].slice(0, MAX_TASK_ATTACHMENTS);
      }
    }
    const primary = attachList[0] || null;
    mediaUrl = primary?.mediaUrl || null;
    mimeType = primary?.mimeType || null;
    fileName = primary?.fileName || null;
    attachmentsJson = serializeAttachments(attachList);
  }

  if (patch.clearMedia === true) {
    mediaUrl = null;
    mimeType = null;
    fileName = null;
    attachmentsJson = null;
    attachList = [];
  }

  if (patch.assignedTo !== undefined) {
    const nextAssignee = patch.assignedTo || null;
    if (nextAssignee !== assignedTo) {
      activity.push({ action: 'assigned', fromValue: assignedTo || null, toValue: nextAssignee });
      assignedTo = nextAssignee;
    }
  }
  if (patch.pinned !== undefined) {
    if (existing.parent_id) throw new Error('cannot pin subtask');
    pinned = patch.pinned ? 1 : 0;
    // Pinning a task puts the Tasks chip in the header — only one board pin needed.
    if (pinned) {
      db.prepare(
        `UPDATE task_items SET pinned = 0
         WHERE conversation_id = ? AND id != ? AND status != 'done'`,
      ).run(existing.conversation_id, id);
    }
  }

  if (patch.body !== undefined && !body && attachList.length === 0) {
    throw new Error('empty task');
  }

  // A task marked done can no longer be pinned.
  if (status === 'done') pinned = 0;

  const now = new Date().toISOString();
  db.prepare(
    `UPDATE task_items
     SET body=?, done=?, done_confirmed=?, media_url=?, mime_type=?, file_name=?,
         attachments=?, assigned_to=?, pinned=?, status=?, priority=?, updated_at=?
     WHERE id=?`,
  ).run(
    body,
    status === 'review' || status === 'done' ? 1 : 0,
    status === 'done' ? 1 : 0,
    mediaUrl,
    mimeType,
    fileName,
    attachmentsJson,
    assignedTo,
    pinned,
    status,
    priority,
    now,
    id,
  );

  for (const entry of activity) {
    logActivity({
      taskId: id,
      conversationId: existing.conversation_id,
      userId,
      action: entry.action,
      fromValue: entry.fromValue,
      toValue: entry.toValue,
    });
  }

  return getTaskItem(id);
}

/** Unpin every task in a conversation (removes Tasks chip from header). */
export function unpinAllTasks(conversationId, userId) {
  if (!userInConversation(conversationId, userId)) throw new Error('forbidden');
  db.prepare(
    'UPDATE task_items SET pinned = 0 WHERE conversation_id = ? AND pinned = 1',
  ).run(conversationId);
  return listTaskItems(conversationId);
}

export function deleteTaskItem(id, userId) {
  const existing = db.prepare('SELECT * FROM task_items WHERE id = ?').get(id);
  if (!existing) throw new Error('not found');
  if (!userInConversation(existing.conversation_id, userId)) throw new Error('forbidden');
  // Children cascade via FK when parent_id is set; explicit delete keeps older DBs safe.
  db.prepare('DELETE FROM task_items WHERE parent_id = ?').run(id);
  db.prepare('DELETE FROM task_items WHERE id = ?').run(id);
  return { conversationId: existing.conversation_id, deletedId: id };
}

export function clearDoneTaskItems(conversationId, userId) {
  if (!userInConversation(conversationId, userId)) throw new Error('forbidden');
  // Only clear tasks that are fully done (and their subtasks).
  db.prepare(
    `DELETE FROM task_items
     WHERE conversation_id = ?
       AND (
         status = 'done'
         OR parent_id IN (
           SELECT id FROM task_items
           WHERE conversation_id = ? AND status = 'done'
         )
       )`,
  ).run(conversationId, conversationId);
  return listTaskItems(conversationId);
}

/** Change log for one task (newest first). For a parent task the feed also
 * includes its subtasks' activity (children can't nest, so one level is
 * enough): opening a board group's log shows every check/uncheck and edit made
 * under it. Entries carry the owning task's body so the client can label rows
 * that belong to a subtask rather than the task being viewed. */
export function listTaskActivity(taskId, { limit = 50 } = {}) {
  const lim = Math.min(Math.max(Number(limit) || 50, 1), 200);
  const childIds = db
    .prepare('SELECT id FROM task_items WHERE parent_id = ?')
    .all(taskId)
    .map((r) => r.id);
  const taskIds = [taskId, ...childIds];
  const placeholders = taskIds.map(() => '?').join(',');
  const rows = db
    .prepare(
      `SELECT a.*, t.body AS task_body
       FROM task_activity a
       JOIN task_items t ON t.id = a.task_id
       WHERE a.task_id IN (${placeholders})
       ORDER BY a.created_at DESC
       LIMIT ?`,
    )
    .all(...taskIds, lim);
  return rows.map((row) => ({
    id: row.id,
    taskId: row.task_id,
    taskBody: row.task_body || null,
    userId: row.user_id || null,
    user: row.user_id ? publicUser(getUserById(row.user_id)) : null,
    action: row.action,
    fromValue: row.from_value,
    toValue: row.to_value,
    createdAt: row.created_at,
  }));
}
