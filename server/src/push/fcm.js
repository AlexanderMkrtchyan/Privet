import crypto from 'node:crypto';
import { listDeviceTokensForUser, removeDeviceToken } from '../db/devices.js';

const FCM_SEND_LEGACY = 'https://fcm.googleapis.com/fcm/send';
const FCM_V1_ENDPOINT = 'https://fcm.googleapis.com/v1/projects';

// ---------------------------------------------------------------------------
// OAuth2 (FCM HTTP v1) — service account JWT minting, no external dependency.
// ---------------------------------------------------------------------------

let _saAccount = null;
let _accessToken = null;
let _accessTokenExpiry = 0;

function loadServiceAccount() {
  if (_saAccount) return _saAccount;
  const raw = process.env.PRIVET_FCM_SERVICE_ACCOUNT || '';
  if (!raw) return null;
  try {
    const json = Buffer.from(raw, 'base64').toString('utf8');
    const sa = JSON.parse(json);
    if (!sa.client_email || !sa.private_key || !sa.project_id) return null;
    _saAccount = sa;
    return _saAccount;
  } catch {
    return null;
  }
}

function base64Url(input) {
  return Buffer.from(input)
    .toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/g, '');
}

function signJwt(payload) {
  const sa = loadServiceAccount();
  const header = { alg: 'RS256', typ: 'JWT' };
  const signingInput = `${base64Url(JSON.stringify(header))}.${base64Url(
    JSON.stringify(payload),
  )}`;
  const sig = crypto
    .createSign('RSA-SHA256')
    .update(signingInput)
    .sign(sa.private_key);
  return `${signingInput}.${base64Url(sig)}`;
}

async function mintAccessToken() {
  const now = Math.floor(Date.now() / 1000);
  if (_accessToken && now < _accessTokenExpiry - 60) return _accessToken;
  const sa = loadServiceAccount();
  const assertion = signJwt({
    iss: sa.client_email,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  });
  const body = new URLSearchParams({
    grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
    assertion,
  }).toString();
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body,
  });
  if (!res.ok) {
    const text = await res.text().catch(() => '');
    throw new Error(`oauth token failed ${res.status}: ${text.slice(0, 200)}`);
  }
  const json = await res.json();
  _accessToken = json.access_token;
  _accessTokenExpiry = now + Number(json.expires_in || 3600);
  return _accessToken;
}

// ---------------------------------------------------------------------------
// Sending
// ---------------------------------------------------------------------------

/**
 * Call messages are sent as DATA-ONLY (no `notification` block) so
 * FirebaseMessagingService.onMessageReceived() fires in EVERY app state:
 * foreground, background, and killed.  The native PrivetFCMService posts
 * the Teams-style full-screen ring (IncomingCallActivity) with ringtone +
 * vibration as soon as the data arrives.
 *
 * `direct_boot_ok: true` allows delivery before the user unlocks after
 * reboot.  `ttl: 60s` matches the server-side ring timeout.
 *
 * Chat (non-call) messages use the standard `notification` path — the OS
 * handles display in background/killed.
 */

async function sendV1(sa, token, { title, body, data = {}, isCall }) {
  const projectId = sa.project_id;
  const channelId = isCall ? 'privet_calls' : 'privet_messages';
  const tag = data.tag || (isCall ? `call:${data.callId}` : data.conversationId);

  const message = {
    token,
    android: {
      priority: 'HIGH',
      // Data-only for calls: no `notification` block anywhere so
      // onMessageReceived() fires in all states.
      ...(isCall
        ? { direct_boot_ok: true }
        : {
            notification: {
              channel_id: channelId,
              icon: 'ic_stat_privet',
              sound: 'default',
              click_action: 'FLUTTER_NOTIFICATION_CLICK',
              visibility: 'PUBLIC',
              notification_priority: 'PRIORITY_HIGH',
              ...(tag ? { tag } : {}),
            },
          }),
    },
    // Calls: data-only — the native service builds the notification.
    // Chat: notification block for OS auto-display.
    ...(isCall
      ? {}
      : {
          notification: {
            title: String(title || 'Privet').slice(0, 100),
            body: String(body || '').slice(0, 200),
          },
        }),
    data: Object.fromEntries(
      Object.entries({
        ...data,
        title: String(title || 'Privet'),
        body: String(body || ''),
      }).map(([k, v]) => [k, String(v ?? '')]),
    ),
  };

  // Calls: add a 60s TTL matching the ring timeout so stale messages
  // don't wake the device long after the caller hung up.
  if (isCall) {
    message.android.ttl = '60s';
  }

  const accessToken = await mintAccessToken();
  const res = await fetch(
    `${FCM_V1_ENDPOINT}/${projectId}/messages:send`,
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${accessToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ message }),
    },
  );
  return { res, json: await res.json().catch(() => ({})) };
}

async function sendLegacy(token, { title, body, data = {}, isCall }) {
  const key = process.env.PRIVET_FCM_SERVER_KEY || '';
  if (!key) return { skipped: 'no_fcm_key' };
  const channelId = isCall ? 'privet_calls' : 'privet_messages';
  const tag = data.tag || (isCall ? `call:${data.callId}` : data.conversationId);
  const res = await fetch(FCM_SEND_LEGACY, {
    method: 'POST',
    headers: {
      Authorization: `key=${key}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      to: token,
      priority: 'high',
      content_available: true,
      // Calls: data-only — the native service posts the full-screen ring.
      // Chat: notification block for OS auto-display.
      ...(isCall
        ? { time_to_live: 60 }
        : {
            notification: {
              title: String(title || 'Privet').slice(0, 100),
              body: String(body || '').slice(0, 200),
              sound: 'default',
              icon: 'ic_stat_privet',
              android_channel_id: channelId,
              click_action: 'FLUTTER_NOTIFICATION_CLICK',
              ...(tag ? { tag } : {}),
            },
          }),
      data: Object.fromEntries(
        Object.entries({
          ...data,
          title: String(title || 'Privet'),
          body: String(body || ''),
        }).map(([k, v]) => [k, String(v ?? '')]),
      ),
    }),
  });
  return { res, json: await res.json().catch(() => ({})) };
}

export async function pushToUser(
  userId,
  { title, body, data = {}, isCall = false } = {},
) {
  const tokens = listDeviceTokensForUser(userId);
  if (tokens.length === 0) return { sent: 0, skipped: 'no_tokens' };

  const sa = loadServiceAccount();
  const legacyKey = process.env.PRIVET_FCM_SERVER_KEY || '';
  if (!sa && !legacyKey) return { sent: 0, skipped: 'no_fcm_key' };

  let sent = 0;
  for (const row of tokens) {
    try {
      const { res, json } = sa
        ? await sendV1(sa, row.token, { title, body, data, isCall })
        : await sendLegacy(row.token, { title, body, data, isCall });
      if (json.skipped) continue;
      const err =
        json.error?.details?.[0]?.errorCode ||
        json.results?.[0]?.error ||
        json.error?.message ||
        '';
      if (
        res.status === 404 ||
        /UNREGISTERED|NOT_FOUND|InvalidRegistration|NotRegistered|MismatchSenderId/i.test(
          String(err),
        )
      ) {
        removeDeviceToken(row.token);
        continue;
      }
      if (!res.ok) {
        console.error(
          `[fcm] send failed ${res.status} ${String(err).slice(0, 200)}`,
        );
        continue;
      }
      sent += 1;
    } catch {
      // ignore network failures per-token
    }
  }
  return { sent };
}

/** Ring mobile devices even when a desktop socket is still "online". */
export async function pushCallToUser(userId, { title, body, data = {} } = {}) {
  return pushToUser(userId, {
    title,
    body,
    data: { ...data, type: data.type || 'call.incoming' },
    isCall: true,
  });
}

/** Chat toast for killed/background mobile clients. */
export async function pushMessageToUser(userId, { title, body, data = {} } = {}) {
  return pushToUser(userId, {
    title,
    body,
    data: {
      ...data,
      tag: data.conversationId || '',
      type: data.type || 'message',
    },
    isCall: false,
  });
}
