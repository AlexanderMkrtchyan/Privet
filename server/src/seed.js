import bcrypt from 'bcryptjs';
import { v4 as uuid } from 'uuid';
import { db, migrate, publicUser } from './db.js';

migrate();

const DEMO = [
  { handle: 'alex', displayName: 'Alex', password: 'privet', hue: 168 },
  { handle: 'mira', displayName: 'Mira', password: 'privet', hue: 28 },
  { handle: 'jon', displayName: 'Jon', password: 'privet', hue: 210 },
];

const insertUser = db.prepare(`
  INSERT OR IGNORE INTO users (id, handle, display_name, password_hash, avatar_hue)
  VALUES (@id, @handle, @display_name, @password_hash, @avatar_hue)
`);

const findByHandle = db.prepare('SELECT * FROM users WHERE handle = ? COLLATE NOCASE');

for (const u of DEMO) {
  insertUser.run({
    id: uuid(),
    handle: u.handle,
    display_name: u.displayName,
    password_hash: bcrypt.hashSync(u.password, 10),
    avatar_hue: u.hue,
  });
}

const alex = findByHandle.get('alex');
const mira = findByHandle.get('mira');
const jon = findByHandle.get('jon');

function ensureDm(a, b) {
  const existing = db
    .prepare(
      `
      SELECT c.id FROM conversations c
      JOIN conversation_members m1 ON m1.conversation_id = c.id AND m1.user_id = ?
      JOIN conversation_members m2 ON m2.conversation_id = c.id AND m2.user_id = ?
      WHERE c.is_group = 0
      LIMIT 1
    `,
    )
    .get(a.id, b.id);

  if (existing) return existing.id;

  const id = uuid();
  db.prepare('INSERT INTO conversations (id, is_group) VALUES (?, 0)').run(id);
  const add = db.prepare(
    'INSERT INTO conversation_members (conversation_id, user_id) VALUES (?, ?)',
  );
  add.run(id, a.id);
  add.run(id, b.id);
  return id;
}

const dmAlexMira = ensureDm(alex, mira);
const dmAlexJon = ensureDm(alex, jon);

const msgCount = db
  .prepare('SELECT COUNT(*) AS n FROM messages WHERE conversation_id = ?')
  .get(dmAlexMira).n;

if (msgCount === 0) {
  const insertMsg = db.prepare(`
    INSERT INTO messages (id, conversation_id, sender_id, body, kind, created_at)
    VALUES (@id, @conversation_id, @sender_id, @body, 'text', @created_at)
  `);

  const seed = [
    [dmAlexMira, mira.id, 'Ship the thing people actually open every day.', '2026-07-22 18:01:00'],
    [dmAlexMira, alex.id, 'Messenger first. Dating later. No WordPress.', '2026-07-22 18:01:40'],
    [dmAlexMira, mira.id, 'Windows, Linux, web, Android. One client.', '2026-07-22 18:02:10'],
    [dmAlexMira, alex.id, 'Privet.', '2026-07-22 18:02:25'],
    [dmAlexJon, jon.id, 'When calls land, we do TURN properly.', '2026-07-22 19:10:00'],
    [dmAlexJon, alex.id, 'Phase 2. First we make chat feel inevitable.', '2026-07-22 19:10:30'],
  ];

  for (const [conversation_id, sender_id, body, created_at] of seed) {
    insertMsg.run({
      id: uuid(),
      conversation_id,
      sender_id,
      body,
      created_at,
    });
  }
}

console.log('Seeded demo users:');
for (const u of [alex, mira, jon]) {
  console.log(`  ${publicUser(u).handle} / privet`);
}
