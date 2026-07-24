import { listDeviceTokensForUser, removeDeviceToken } from '../db/devices.js';

/**
 * Send FCM data+notification when PRIVET_FCM_SERVER_KEY is set.
 * Uses the legacy HTTP API (still works with server keys from Firebase console).
 */
export async function pushToUser(userId, { title, body, data = {} } = {}) {
  const key = process.env.PRIVET_FCM_SERVER_KEY || '';
  if (!key) return { sent: 0, skipped: 'no_fcm_key' };

  const tokens = listDeviceTokensForUser(userId);
  if (tokens.length === 0) return { sent: 0, skipped: 'no_tokens' };

  let sent = 0;
  for (const row of tokens) {
    try {
      const res = await fetch('https://fcm.googleapis.com/fcm/send', {
        method: 'POST',
        headers: {
          Authorization: `key=${key}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          to: row.token,
          priority: 'high',
          notification: {
            title: String(title || 'Privet').slice(0, 100),
            body: String(body || '').slice(0, 200),
            sound: 'default',
          },
          data: Object.fromEntries(
            Object.entries(data).map(([k, v]) => [k, String(v ?? '')]),
          ),
        }),
      });
      const json = await res.json().catch(() => ({}));
      if (json.failure === 1 || json.error) {
        const err = json.results?.[0]?.error || json.error;
        if (
          err === 'NotRegistered' ||
          err === 'InvalidRegistration' ||
          err === 'MismatchSenderId'
        ) {
          removeDeviceToken(row.token);
        }
        continue;
      }
      sent += 1;
    } catch {
      // ignore network failures per-token
    }
  }
  return { sent };
}
