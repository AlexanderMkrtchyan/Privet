import { randomUUID } from 'node:crypto';
import { db } from '../db.js';

function requireActivityToken(request, reply) {
  const expected = String(process.env.HABITATION_ACTIVITY_TOKEN || '').trim();
  if (!expected) {
    reply.code(503).send({ error: 'habitation_activity_disabled' });
    return false;
  }
  const header = String(request.headers.authorization || '');
  const token = header.toLowerCase().startsWith('bearer ')
    ? header.slice(7).trim()
    : String(request.headers['x-habitation-token'] || '').trim();
  if (!token || token !== expected) {
    reply.code(401).send({ error: 'unauthorized' });
    return false;
  }
  return true;
}

export async function registerHabitationActivityRoutes(app) {
  app.get('/api/habitation/activity/health', async () => ({
    ok: true,
    enabled: Boolean(String(process.env.HABITATION_ACTIVITY_TOKEN || '').trim()),
  }));

  app.post('/api/habitation/activity/chunks', async (request, reply) => {
    if (!requireActivityToken(request, reply)) return;

    const body = request.body || {};
    const deviceId = String(body.device_id || '').trim().slice(0, 80);
    const os = String(body.os || '').trim().slice(0, 32);
    const day = String(body.day || '').trim().slice(0, 10);
    const seq = Number(body.seq);
    const ciphertext = String(body.ciphertext || '');

    if (!deviceId || !os || !/^\d{4}-\d{2}-\d{2}$/.test(day) || !Number.isFinite(seq) || seq < 1) {
      return reply.code(400).send({ error: 'invalid_fields' });
    }
    if (!ciphertext || ciphertext.length > 2_000_000) {
      return reply.code(400).send({ error: 'invalid_ciphertext' });
    }

    const id = randomUUID();
    try {
      db.prepare(
        `
        INSERT INTO habitation_activity_chunks (id, device_id, os, day, seq, ciphertext)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(device_id, day, seq) DO UPDATE SET
          ciphertext = excluded.ciphertext,
          os = excluded.os,
          created_at = datetime('now')
      `,
      ).run(id, deviceId, os, day, Math.floor(seq), ciphertext);
    } catch (err) {
      request.log.error({ err }, 'habitation activity insert failed');
      return reply.code(500).send({ error: 'store_failed' });
    }

    return { ok: true, day, seq: Math.floor(seq) };
  });

  app.get('/api/habitation/activity/chunks', async (request, reply) => {
    if (!requireActivityToken(request, reply)) return;

    const day = String(request.query?.day || '').trim();
    const since = String(request.query?.since || '').trim();
    let rows;
    if (/^\d{4}-\d{2}-\d{2}$/.test(day)) {
      rows = db
        .prepare(
          `
          SELECT id, device_id, os, day, seq, ciphertext, created_at
          FROM habitation_activity_chunks
          WHERE day = ?
          ORDER BY day ASC, device_id ASC, seq ASC
        `,
        )
        .all(day);
    } else if (/^\d{4}-\d{2}-\d{2}$/.test(since)) {
      rows = db
        .prepare(
          `
          SELECT id, device_id, os, day, seq, ciphertext, created_at
          FROM habitation_activity_chunks
          WHERE day >= ?
          ORDER BY day ASC, device_id ASC, seq ASC
        `,
        )
        .all(since);
    } else {
      rows = db
        .prepare(
          `
          SELECT id, device_id, os, day, seq, ciphertext, created_at
          FROM habitation_activity_chunks
          WHERE day >= date('now', '-30 day')
          ORDER BY day ASC, device_id ASC, seq ASC
        `,
        )
        .all();
    }

    return {
      chunks: rows.map((r) => ({
        id: r.id,
        device_id: r.device_id,
        os: r.os,
        day: r.day,
        seq: r.seq,
        ciphertext: r.ciphertext,
        created_at: r.created_at,
      })),
    };
  });
}
