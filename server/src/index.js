import Fastify from 'fastify';
import cors from '@fastify/cors';
import jwt from '@fastify/jwt';
import websocket from '@fastify/websocket';
import fastifyStatic from '@fastify/static';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadEnvFile } from './env.js';
import { migrate, uploadsDir } from './db.js';
import { getDueReminders, updateReminder } from './db/reminders.js';
import { memberIds } from './db/chat.js';
import { broadcastToUsers } from './ws/hub.js';

loadEnvFile();
import { registerRoutes } from './routes/api.js';
import { registerWebsocket } from './ws/handlers.js';
import './seed.js';

migrate();

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const serverRoot = path.join(__dirname, '..');
const publicDir = path.join(serverRoot, 'public');

const app = Fastify({
  logger: true,
  bodyLimit: 1048576,
});
const port = Number(process.env.PORT || 7777);
const host = process.env.HOST || '0.0.0.0';

await app.register(cors, { origin: true });
await app.register(jwt, {
  secret: process.env.JWT_SECRET || 'privet-dev-secret-change-me',
});
await app.register(websocket);

app.removeContentTypeParser('application/json');
app.addContentTypeParser(
  'application/json',
  { parseAs: 'string' },
  (req, body, done) => {
    if (!body || body.length === 0) {
      done(null, {});
      return;
    }
    try {
      done(null, JSON.parse(body));
    } catch (err) {
      err.statusCode = 400;
      done(err, undefined);
    }
  },
);

await registerRoutes(app);
registerWebsocket(app);

// Old invite links were /?invite=handle; chat moved to /app/ after landing split.
app.addHook('onRequest', async (request, reply) => {
  if (request.method !== 'GET' && request.method !== 'HEAD') return;
  const qIndex = request.url.indexOf('?');
  const pathOnly = qIndex === -1 ? request.url : request.url.slice(0, qIndex);
  if (pathOnly !== '/') return;
  const search = qIndex === -1 ? '' : request.url.slice(qIndex);
  const invite = new URLSearchParams(search.startsWith('?') ? search.slice(1) : search)
    .get('invite')
    ?.trim();
  if (!invite) return;
  return reply.redirect(`/app/${search || `?invite=${encodeURIComponent(invite)}`}`);
});

fs.mkdirSync(uploadsDir, { recursive: true });
await app.register(fastifyStatic, {
  root: uploadsDir,
  prefix: '/media/',
  decorateReply: false,
});

if (fs.existsSync(publicDir)) {
  await app.register(fastifyStatic, {
    root: publicDir,
    prefix: '/',
    decorateReply: true,
    // Must stay true so newly deployed files (stamped main.*.js, sounds, …)
    // are served without restarting Node.
    wildcard: true,
    setHeaders: (res, pathName) => {
      // Always revalidate the Flutter shell + bundle during local iteration.
      if (
        pathName.endsWith('index.html') ||
        pathName.endsWith('flutter_bootstrap.js') ||
        pathName.endsWith('flutter.js') ||
        pathName.endsWith('main.dart.js') ||
        pathName.endsWith('manifest.json') ||
        pathName.endsWith('sw.js')
      ) {
        // @fastify/static may pass a Fastify reply or a Node response.
        if (typeof res.setHeader === 'function') {
          res.setHeader('Cache-Control', 'no-store, no-cache, must-revalidate');
          res.setHeader('Pragma', 'no-cache');
        } else if (typeof res.header === 'function') {
          res.header('Cache-Control', 'no-store, no-cache, must-revalidate');
          res.header('Pragma', 'no-cache');
        }
      }
    },
  });

  app.setNotFoundHandler((request, reply) => {
    if (request.method === 'GET') {
      const url = request.url.split('?')[0];
      // Native chat client (hash-routed Flutter shell) lives under /app/.
      if (
        (url === '/app' || url.startsWith('/app/')) &&
        fs.existsSync(path.join(publicDir, 'app', 'index.html'))
      ) {
        return reply.sendFile('app/index.html');
      }
      const apiLike =
        url.startsWith('/auth') ||
        url.startsWith('/me') ||
        url.startsWith('/users') ||
        url.startsWith('/conversations') ||
        url.startsWith('/uploads') ||
        url.startsWith('/media') ||
        url.startsWith('/ice') ||
        url.startsWith('/health') ||
        url.startsWith('/ws') ||
        url.startsWith('/downloads') ||
        url.startsWith('/install');
      if (!apiLike && fs.existsSync(path.join(publicDir, 'index.html'))) {
        return reply.sendFile('index.html');
      }
    }
    return reply.code(404).send({ error: 'not found' });
  });
}

// Fire payment reminder notifications once per minute.
function tickReminders() {
  try {
    const due = getDueReminders();
    for (const r of due) {
      const amount = (r.amountCents / 100).toFixed(2);
      const symbol = r.currency === 'USD' ? '$' : r.currency;
      const label = r.direction === 'owe'
        ? `You owe ${symbol}${amount}`
        : `${symbol}${amount} owed to you`;
      broadcastToUsers([r.createdBy?.id].filter(Boolean), {
        type: 'notify',
        conversationId: r.conversationId,
        title: '💸 Payment reminder',
        body: `${label} — due ${r.dueDate}${r.note ? ': ' + r.note : ''}`,
        tag: `reminder-${r.id}`,
      });
      // Snooze for 24 h so we don't spam on every tick.
      const snoozeUntil = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();
      try {
        updateReminder(r.id, r.createdBy?.id, { snoozedUntil: snoozeUntil });
      } catch (_) { /* ignore */ }
    }
  } catch (err) {
    console.error('[reminders] tick error', err);
  }
}
setInterval(tickReminders, 60_000);

try {
  await app.listen({ port, host });
  console.log(`[privet] http://${host}:${port}`);
  console.log(`[privet] ws   ws://${host}:${port}/ws`);
  console.log('[privet] demo logins: alex / privet, mira / privet, jon / privet');
} catch (err) {
  app.log.error(err);
  process.exit(1);
}
