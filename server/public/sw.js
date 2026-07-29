/* Privet PWA service worker — local web.
 * Build stamp is injected by deploy-web.sh (20260729-123747).
 * Network-first for app shell/JS so local deploys stay fresh; cache-first for
 * static icons/assets. API, media, and WebSocket traffic are never cached.
 */
'use strict';

const BUILD = '20260729-123747';
const CACHE = `privet-static-${BUILD}`;

const PRECACHE = [
  '/app/',
  '/app/index.html',
  '/manifest.json',
  '/pwa-install.js',
  '/favicon.png',
  '/icons/Icon-192.png',
  '/icons/Icon-512.png',
  '/icons/Icon-maskable-192.png',
  '/icons/Icon-maskable-512.png',
];

const API_PREFIXES = [
  '/auth',
  '/me',
  '/users',
  '/conversations',
  '/uploads',
  '/media/',
  '/ice',
  '/health',
  '/ws',
  '/downloads/',
  '/install/',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    (async () => {
      const cache = await caches.open(CACHE);
      await Promise.all(
        PRECACHE.map(async (url) => {
          try {
            await cache.add(url);
          } catch (_) {
            // Optional during first boot if a path is missing.
          }
        }),
      );
      await self.skipWaiting();
    })(),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      const keys = await caches.keys();
      await Promise.all(
        keys
          .filter((k) => k.startsWith('privet-static-') && k !== CACHE)
          .map((k) => caches.delete(k)),
      );
      // Drop legacy Flutter SW caches if any remain.
      await Promise.all(
        keys
          .filter((k) => !k.startsWith('privet-static-'))
          .map((k) => caches.delete(k)),
      );
      await self.clients.claim();
    })(),
  );
});

function isApiLike(pathname) {
  return API_PREFIXES.some((p) => {
    if (p.endsWith('/')) return pathname.startsWith(p);
    return pathname === p || pathname.startsWith(`${p}/`);
  });
}

function isStaticAsset(pathname) {
  if (
    pathname.startsWith('/icons/') ||
    pathname.startsWith('/assets/') ||
    pathname.startsWith('/canvaskit/') ||
    pathname === '/favicon.png' ||
    pathname === '/manifest.json'
  ) {
    return true;
  }
  return /\.(png|jpg|jpeg|gif|webp|svg|ico|woff2?|ttf|otf|wasm)$/i.test(pathname);
}

function isAppShell(pathname) {
  return (
    pathname === '/app' ||
    pathname === '/app/' ||
    pathname === '/app/index.html' ||
    pathname.endsWith('.js') ||
    pathname.endsWith('.json')
  );
}

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;

  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  if (isApiLike(url.pathname)) return;

  if (isStaticAsset(url.pathname)) {
    event.respondWith(cacheFirst(req));
    return;
  }

  if (isAppShell(url.pathname)) {
    event.respondWith(networkFirst(req));
  }
});

async function cacheFirst(req) {
  const cached = await caches.match(req);
  if (cached) return cached;
  const res = await fetch(req);
  if (res.ok) {
    const cache = await caches.open(CACHE);
    cache.put(req, res.clone());
  }
  return res;
}

async function networkFirst(req) {
  try {
    const res = await fetch(req);
    if (res.ok) {
      const cache = await caches.open(CACHE);
      cache.put(req, res.clone());
    }
    return res;
  } catch (_) {
    const cached = await caches.match(req);
    if (cached) return cached;
    if (req.mode === 'navigate') {
      const shell = await caches.match('/app/index.html');
      if (shell) return shell;
    }
    throw _;
  }
}
