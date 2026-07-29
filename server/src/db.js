import Database from 'better-sqlite3';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const serverRoot = path.join(__dirname, '..');

// NEW messenger DB only. Never the dating-site MySQL under /home/alex/Working.
// Default file: /home/alex/Privet/server/data/privet.sqlite
const dbPath = path.resolve(
  serverRoot,
  process.env.PRIVET_DB_PATH || path.join('data', 'privet.sqlite'),
);

if (!dbPath.startsWith(serverRoot + path.sep)) {
  throw new Error(
    `Privet DB must stay inside ${serverRoot} (got ${dbPath}). Dating-site DB is off-limits.`,
  );
}

fs.mkdirSync(path.dirname(dbPath), { recursive: true });
fs.mkdirSync(path.join(serverRoot, 'data', 'uploads'), { recursive: true });

console.log(`[privet-db] using ${dbPath}`);
export const db = new Database(dbPath);
db.pragma('journal_mode = WAL');
db.pragma('foreign_keys = ON');

function ensureColumn(table, column, ddl) {
  const cols = db.prepare(`PRAGMA table_info(${table})`).all();
  if (!cols.some((c) => c.name === column)) {
    db.exec(`ALTER TABLE ${table} ADD COLUMN ${ddl}`);
  }
}

export function migrate() {
  db.exec(`
    CREATE TABLE IF NOT EXISTS users (
      id TEXT PRIMARY KEY,
      handle TEXT NOT NULL UNIQUE COLLATE NOCASE,
      display_name TEXT NOT NULL,
      password_hash TEXT NOT NULL,
      avatar_hue INTEGER NOT NULL DEFAULT 160,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS conversations (
      id TEXT PRIMARY KEY,
      is_group INTEGER NOT NULL DEFAULT 0,
      title TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS conversation_members (
      conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      joined_at TEXT NOT NULL DEFAULT (datetime('now')),
      PRIMARY KEY (conversation_id, user_id)
    );

    CREATE TABLE IF NOT EXISTS messages (
      id TEXT PRIMARY KEY,
      conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
      sender_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      body TEXT NOT NULL,
      kind TEXT NOT NULL DEFAULT 'text',
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );

    CREATE INDEX IF NOT EXISTS idx_messages_conversation_created
      ON messages(conversation_id, created_at);
  `);

  ensureColumn('messages', 'media_url', 'media_url TEXT');
  ensureColumn('messages', 'mime_type', 'mime_type TEXT');
  ensureColumn('messages', 'file_name', 'file_name TEXT');
  ensureColumn('messages', 'file_size', 'file_size INTEGER');
  ensureColumn('messages', 'reply_to_id', 'reply_to_id TEXT');
  ensureColumn('messages', 'reply_quote', 'reply_quote TEXT');
  ensureColumn('messages', 'attachments', 'attachments TEXT');
  ensureColumn('messages', 'link_preview', 'link_preview TEXT');
  ensureColumn('messages', 'edited_at', 'edited_at TEXT');
  ensureColumn('messages', 'deleted_at', 'deleted_at TEXT');
  ensureColumn('conversations', 'owner_id', 'owner_id TEXT');
  ensureColumn('conversation_members', 'hidden', 'hidden INTEGER NOT NULL DEFAULT 0');
  ensureColumn('conversation_members', 'muted', 'muted INTEGER NOT NULL DEFAULT 0');
  ensureColumn(
    'conversation_members',
    'last_read_message_id',
    'last_read_message_id TEXT',
  );
  ensureColumn('conversation_members', 'last_read_at', 'last_read_at TEXT');
  ensureColumn('conversation_members', 'pinned', 'pinned INTEGER NOT NULL DEFAULT 0');
  ensureColumn('conversation_members', 'pinned_at', 'pinned_at TEXT');
  ensureColumn('users', 'avatar_url', 'avatar_url TEXT');
  ensureColumn('users', 'last_seen_at', 'last_seen_at TEXT');
  ensureColumn('messages', 'forwarded_from_id', 'forwarded_from_id TEXT');
  ensureColumn('messages', 'forwarded_from_name', 'forwarded_from_name TEXT');
  ensureColumn('messages', 'forwarded_from_handle', 'forwarded_from_handle TEXT');

  // Existing groups had no owner — assign the earliest member.
  db.prepare(
    `
    UPDATE conversations
    SET owner_id = (
      SELECT cm.user_id FROM conversation_members cm
      WHERE cm.conversation_id = conversations.id
      ORDER BY cm.joined_at ASC
      LIMIT 1
    )
    WHERE is_group = 1 AND (owner_id IS NULL OR owner_id = '')
  `,
  ).run();

  db.exec(`
    CREATE TABLE IF NOT EXISTS message_reactions (
      message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      emoji TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      PRIMARY KEY (message_id, user_id, emoji)
    );
    CREATE INDEX IF NOT EXISTS idx_reactions_message
      ON message_reactions(message_id);

    -- Outbound forward notes on the *source* message ("Forwarded to Jon").
    CREATE TABLE IF NOT EXISTS message_forwards (
      forwarded_message_id TEXT PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
      source_message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
      to_conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
      by_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      target_title TEXT NOT NULL,
      target_is_group INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE INDEX IF NOT EXISTS idx_forwards_source
      ON message_forwards(source_message_id);

    CREATE TABLE IF NOT EXISTS task_items (
      id TEXT PRIMARY KEY,
      conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
      body TEXT NOT NULL DEFAULT '',
      done INTEGER NOT NULL DEFAULT 0,
      sort_order INTEGER NOT NULL DEFAULT 0,
      message_id TEXT,
      media_url TEXT,
      mime_type TEXT,
      file_name TEXT,
      created_by TEXT REFERENCES users(id) ON DELETE SET NULL,
      assigned_to TEXT REFERENCES users(id) ON DELETE SET NULL,
      done_confirmed INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE INDEX IF NOT EXISTS idx_task_items_conversation
      ON task_items(conversation_id, sort_order);

    CREATE TABLE IF NOT EXISTS payment_reminders (
      id TEXT PRIMARY KEY,
      conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
      created_by TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      kind TEXT NOT NULL DEFAULT 'payment',
      amount_cents INTEGER,
      currency TEXT NOT NULL DEFAULT 'USD',
      direction TEXT NOT NULL DEFAULT 'owe',
      note TEXT NOT NULL DEFAULT '',
      due_date TEXT NOT NULL,
      paid INTEGER NOT NULL DEFAULT 0,
      paid_at TEXT,
      paid_by TEXT REFERENCES users(id) ON DELETE SET NULL,
      snoozed_until TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE INDEX IF NOT EXISTS idx_payment_reminders_conversation
      ON payment_reminders(conversation_id);
    CREATE INDEX IF NOT EXISTS idx_payment_reminders_due
      ON payment_reminders(due_date, paid);

    CREATE TABLE IF NOT EXISTS payment_expenses (
      id TEXT PRIMARY KEY,
      payment_id TEXT NOT NULL REFERENCES payment_reminders(id) ON DELETE CASCADE,
      label TEXT NOT NULL DEFAULT '',
      amount_cents INTEGER NOT NULL,
      created_by TEXT REFERENCES users(id) ON DELETE SET NULL,
      sort_order INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE INDEX IF NOT EXISTS idx_payment_expenses_payment
      ON payment_expenses(payment_id);

    CREATE TABLE IF NOT EXISTS user_blocks (
      blocker_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      blocked_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      PRIMARY KEY (blocker_id, blocked_id)
    );
    CREATE INDEX IF NOT EXISTS idx_user_blocks_blocked
      ON user_blocks(blocked_id);

    CREATE TABLE IF NOT EXISTS device_tokens (
      token TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      platform TEXT NOT NULL DEFAULT 'android',
      updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE INDEX IF NOT EXISTS idx_device_tokens_user
      ON device_tokens(user_id);
  `);

  // Add columns introduced after initial schema (safe to run repeatedly).
  const addColIfMissing = (table, col, def) => {
    const cols = db.prepare(`PRAGMA table_info(${table})`).all().map(r => r.name);
    if (!cols.includes(col)) {
      db.prepare(`ALTER TABLE ${table} ADD COLUMN ${col} ${def}`).run();
    }
  };
  addColIfMissing('task_items', 'assigned_to', 'TEXT REFERENCES users(id) ON DELETE SET NULL');
  addColIfMissing('task_items', 'done_confirmed', 'INTEGER NOT NULL DEFAULT 0');
  addColIfMissing('payment_reminders', 'kind', "TEXT NOT NULL DEFAULT 'payment'");
  addColIfMissing('payment_reminders', 'paid_by', 'TEXT REFERENCES users(id) ON DELETE SET NULL');
  addColIfMissing('payment_reminders', 'amount_cents', 'INTEGER');
  addColIfMissing('task_items', 'pinned', 'INTEGER NOT NULL DEFAULT 0');
  addColIfMissing('task_items', 'parent_id', 'TEXT REFERENCES task_items(id) ON DELETE CASCADE');
  addColIfMissing('task_items', 'attachments', 'TEXT');
  addColIfMissing('payment_reminders', 'pinned', 'INTEGER NOT NULL DEFAULT 0');
  db.exec(`
    CREATE INDEX IF NOT EXISTS idx_task_items_parent
      ON task_items(conversation_id, parent_id, sort_order);
  `);

  // Older DBs created amount_cents as NOT NULL — recreate table so reminders can omit amount.
  const amountCol = db.prepare('PRAGMA table_info(payment_reminders)').all()
    .find((c) => c.name === 'amount_cents');
  if (amountCol && amountCol.notnull === 1) {
    db.exec(`
      PRAGMA foreign_keys = OFF;
      BEGIN;
      CREATE TABLE payment_reminders_v2 (
        id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
        created_by TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        kind TEXT NOT NULL DEFAULT 'payment',
        amount_cents INTEGER,
        currency TEXT NOT NULL DEFAULT 'USD',
        direction TEXT NOT NULL DEFAULT 'owe',
        note TEXT NOT NULL DEFAULT '',
        due_date TEXT NOT NULL,
        paid INTEGER NOT NULL DEFAULT 0,
        paid_at TEXT,
        paid_by TEXT REFERENCES users(id) ON DELETE SET NULL,
        snoozed_until TEXT,
        pinned INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        updated_at TEXT NOT NULL DEFAULT (datetime('now'))
      );
      INSERT INTO payment_reminders_v2 (
        id, conversation_id, created_by, kind, amount_cents, currency, direction,
        note, due_date, paid, paid_at, paid_by, snoozed_until, pinned, created_at, updated_at
      )
      SELECT
        id, conversation_id, created_by,
        COALESCE(kind, 'payment'),
        amount_cents, currency, direction, note, due_date, paid, paid_at, paid_by,
        snoozed_until, COALESCE(pinned, 0), created_at, updated_at
      FROM payment_reminders;
      DROP TABLE payment_reminders;
      ALTER TABLE payment_reminders_v2 RENAME TO payment_reminders;
      CREATE INDEX IF NOT EXISTS idx_payment_reminders_conversation
        ON payment_reminders(conversation_id);
      CREATE INDEX IF NOT EXISTS idx_payment_reminders_due
        ON payment_reminders(due_date, paid);
      COMMIT;
      PRAGMA foreign_keys = ON;
    `);
    console.log('[privet-db] migrated payment_reminders.amount_cents → nullable');
  }

  // Backfill outbound notes from existing inbound forward copies.
  db.prepare(
    `
    INSERT OR IGNORE INTO message_forwards (
      forwarded_message_id, source_message_id, to_conversation_id,
      by_user_id, target_title, target_is_group, created_at
    )
    SELECT
      m.id,
      m.forwarded_from_id,
      m.conversation_id,
      m.sender_id,
      COALESCE(
        NULLIF(TRIM(c.title), ''),
        (
          SELECT u.display_name
          FROM conversation_members cm
          JOIN users u ON u.id = cm.user_id
          WHERE cm.conversation_id = m.conversation_id
            AND cm.user_id != m.sender_id
          ORDER BY cm.joined_at ASC
          LIMIT 1
        ),
        'Chat'
      ),
      c.is_group,
      m.created_at
    FROM messages m
    JOIN conversations c ON c.id = m.conversation_id
    WHERE m.forwarded_from_id IS NOT NULL
      AND m.forwarded_from_id != ''
  `,
  ).run();
}

export function publicUser(row) {
  if (!row) return null;
  return {
    id: row.id,
    handle: row.handle,
    displayName: row.display_name,
    avatarHue: row.avatar_hue,
    avatarUrl: row.avatar_url || null,
    lastSeenAt: row.last_seen_at || null,
  };
}

export const uploadsDir = path.join(serverRoot, 'data', 'uploads');
