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

const STATE_ID = 'default';
const MAX_CIPHERTEXT = 5_000_000;

export async function registerHabitationStateRoutes(app) {
  app.get('/api/habitation/state', async (request, reply) => {
    if (!requireActivityToken(request, reply)) return;

    const row = db
      .prepare(
        `
        SELECT id, ciphertext, updated_at, device_id, rev
        FROM habitation_state
        WHERE id = ?
      `,
      )
      .get(STATE_ID);

    if (!row) {
      return reply.code(404).send({ error: 'not_found' });
    }

    return {
      id: row.id,
      ciphertext: row.ciphertext,
      updated_at: Number(row.updated_at) || 0,
      device_id: row.device_id || '',
      rev: Number(row.rev) || 0,
    };
  });

  app.put('/api/habitation/state', async (request, reply) => {
    if (!requireActivityToken(request, reply)) return;

    const body = request.body || {};
    const ciphertext = String(body.ciphertext || '');
    const deviceId = String(body.device_id || '').trim().slice(0, 80);
    const updatedAt = Number(body.updated_at);
    const rev = Number(body.rev);

    if (!deviceId || !Number.isFinite(updatedAt) || updatedAt < 1) {
      return reply.code(400).send({ error: 'invalid_fields' });
    }
    if (!Number.isFinite(rev) || rev < 1) {
      return reply.code(400).send({ error: 'invalid_rev' });
    }
    if (!ciphertext || ciphertext.length > MAX_CIPHERTEXT) {
      return reply.code(400).send({ error: 'invalid_ciphertext' });
    }

    const current = db
      .prepare(
        `
        SELECT ciphertext, updated_at, device_id, rev
        FROM habitation_state
        WHERE id = ?
      `,
      )
      .get(STATE_ID);

    if (current) {
      const curRev = Number(current.rev) || 0;
      const curUpdated = Number(current.updated_at) || 0;
      // Reject stale writes: remote must not go backwards.
      if (rev < curRev || (rev === curRev && updatedAt < curUpdated)) {
        return reply.code(409).send({
          error: 'conflict',
          ciphertext: current.ciphertext,
          updated_at: curUpdated,
          device_id: current.device_id || '',
          rev: curRev,
        });
      }
    }

    try {
      db.prepare(
        `
        INSERT INTO habitation_state (id, ciphertext, updated_at, device_id, rev)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          ciphertext = excluded.ciphertext,
          updated_at = excluded.updated_at,
          device_id = excluded.device_id,
          rev = excluded.rev
      `,
      ).run(STATE_ID, ciphertext, Math.floor(updatedAt), deviceId, Math.floor(rev));
    } catch (err) {
      request.log.error({ err }, 'habitation state upsert failed');
      return reply.code(500).send({ error: 'store_failed' });
    }

    return {
      ok: true,
      updated_at: Math.floor(updatedAt),
      device_id: deviceId,
      rev: Math.floor(rev),
    };
  });
}
