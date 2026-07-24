import dns from 'node:dns/promises';
import net from 'node:net';
import { URL } from 'node:url';

const URL_RE = /https?:\/\/[^\s<>"')\]]+/gi;
const FETCH_TIMEOUT_MS = 3500;
const MAX_HTML_BYTES = 512_000;

function stripTrailingPunct(url) {
  return url.replace(/[.,;:!?)\]>'"]+$/g, '');
}

export function extractFirstUrl(text) {
  if (!text) return null;
  const match = String(text).match(URL_RE);
  if (!match) return null;
  try {
    const raw = stripTrailingPunct(match[0]);
    const u = new URL(raw);
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
    return u.toString();
  } catch {
    return null;
  }
}

function isPrivateIp(ip) {
  if (!ip) return true;
  if (ip === '::1' || ip === '0.0.0.0') return true;
  if (ip.startsWith('fe80:') || ip.startsWith('fc') || ip.startsWith('fd')) {
    return true;
  }
  const parts = ip.split('.').map(Number);
  if (parts.length !== 4 || parts.some((n) => Number.isNaN(n))) return false;
  const [a, b] = parts;
  if (a === 10 || a === 127 || a === 0) return true;
  if (a === 169 && b === 254) return true;
  if (a === 172 && b >= 16 && b <= 31) return true;
  if (a === 192 && b === 168) return true;
  if (a === 100 && b >= 64 && b <= 127) return true;
  return false;
}

async function assertPublicUrl(urlString) {
  const u = new URL(urlString);
  if (u.protocol !== 'http:' && u.protocol !== 'https:') {
    throw new Error('unsupported protocol');
  }
  if (u.username || u.password) throw new Error('credentials not allowed');
  const host = u.hostname;
  if (
    host === 'localhost' ||
    host.endsWith('.localhost') ||
    host.endsWith('.local')
  ) {
    throw new Error('local host blocked');
  }
  if (net.isIP(host)) {
    if (isPrivateIp(host)) throw new Error('private IP blocked');
    return;
  }
  const records = await dns.lookup(host, { all: true, verbatim: true });
  if (!records.length) throw new Error('DNS failed');
  for (const r of records) {
    if (isPrivateIp(r.address)) throw new Error('private IP blocked');
  }
}

function decodeEntities(s) {
  return String(s || '')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&#x([0-9a-f]+);/gi, (_, h) =>
      String.fromCodePoint(parseInt(h, 16)),
    )
    .replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(Number(d)));
}

function metaContent(html, ...keys) {
  for (const key of keys) {
    const reProp = new RegExp(
      `<meta[^>]+(?:property|name)=["']${key}["'][^>]+content=["']([^"']+)["'][^>]*>`,
      'i',
    );
    const reContentFirst = new RegExp(
      `<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name)=["']${key}["'][^>]*>`,
      'i',
    );
    const m = html.match(reProp) || html.match(reContentFirst);
    if (m?.[1]) return decodeEntities(m[1].trim());
  }
  return null;
}

function pageTitle(html) {
  const m = html.match(/<title[^>]*>([^<]*)<\/title>/i);
  return m?.[1] ? decodeEntities(m[1].trim()) : null;
}

function absoluteUrl(base, maybeRelative) {
  if (!maybeRelative) return null;
  try {
    return new URL(maybeRelative, base).toString();
  } catch {
    return null;
  }
}

function hostnameOf(url) {
  try {
    return new URL(url).hostname.replace(/^www\./, '');
  } catch {
    return null;
  }
}

/**
 * Fetch Open Graph / Twitter card style metadata for a URL.
 * @returns {Promise<{ url: string, title: string|null, description: string|null, image: string|null, siteName: string|null }|null>}
 */
export async function fetchLinkPreview(urlString) {
  try {
    await assertPublicUrl(urlString);
  } catch {
    return null;
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
  try {
    const res = await fetch(urlString, {
      method: 'GET',
      redirect: 'follow',
      signal: controller.signal,
      headers: {
        Accept: 'text/html,application/xhtml+xml;q=0.9,*/*;q=0.8',
        'User-Agent':
          'PrivetBot/1.0 (+https://privet.local; link-preview)',
        'Accept-Language': 'en-US,en;q=0.8',
      },
    });
    if (!res.ok) return null;
    const ctype = (res.headers.get('content-type') || '').toLowerCase();
    if (
      ctype &&
      !ctype.includes('text/html') &&
      !ctype.includes('application/xhtml')
    ) {
      // Non-HTML: still show a minimal card with the host.
      return {
        url: res.url || urlString,
        title: hostnameOf(res.url || urlString),
        description: null,
        image: null,
        siteName: hostnameOf(res.url || urlString),
      };
    }

    const reader = res.body?.getReader?.();
    let html = '';
    if (reader) {
      const decoder = new TextDecoder('utf-8');
      let size = 0;
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.byteLength;
        html += decoder.decode(value, { stream: true });
        if (size >= MAX_HTML_BYTES) {
          try {
            await reader.cancel();
          } catch {
            // ignore
          }
          break;
        }
      }
      html += decoder.decode();
    } else {
      html = await res.text();
      if (html.length > MAX_HTML_BYTES) html = html.slice(0, MAX_HTML_BYTES);
    }

    const finalUrl = res.url || urlString;
    const title =
      metaContent(html, 'og:title', 'twitter:title') || pageTitle(html);
    const description = metaContent(
      html,
      'og:description',
      'twitter:description',
      'description',
    );
    const image = absoluteUrl(
      finalUrl,
      metaContent(html, 'og:image', 'twitter:image', 'twitter:image:src'),
    );
    const siteName =
      metaContent(html, 'og:site_name') || hostnameOf(finalUrl);

    if (!title && !description && !image) {
      return {
        url: finalUrl,
        title: hostnameOf(finalUrl),
        description: null,
        image: null,
        siteName: hostnameOf(finalUrl),
      };
    }

    return {
      url: finalUrl,
      title: title ? title.slice(0, 200) : null,
      description: description ? description.slice(0, 320) : null,
      image,
      siteName: siteName ? String(siteName).slice(0, 120) : null,
    };
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}
