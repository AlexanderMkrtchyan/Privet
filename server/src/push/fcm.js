import { listDeviceTokensForUser, removeDeviceToken } from '../db/devices.js';

/**
 * Send FCM data+notification when PRIVET_FCM_SERVER_KEY is set.
 * Uses the legacy HTTP API (still works with server keys from Firebase console).
 */
export async function pushToUser(
  userId,
  { title, body, data = {}, isCall = false } = {},
) {
  const key = process.env.PRIVET_FCM_SERVER_KEY || '';
  if (!key) return { sent: 0, skipped: 'no_fcm_key' };

  const tokens = listDeviceTokensForUser(userId);
  if (tokens.length === 0) return { sent: 0, skipped: 'no_tokens' };

  let sent = 0;
  for (const row of tokens) {
    try {
      const channelId = isCall ? 'privet_calls' : 'privet_messages';
      const res = await fetch('https://fcm.googleapis.com/fcm/send', {
        method: 'POST',
        headers: {
          Authorization: `key=${key}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          to: row.token,
          priority: 'high',
          content_available: true,
          notification: {
            title: String(title || 'Privet').slice(0, 100),
            body: String(body || '').slice(0, 200),
            sound: 'default',
            android_channel_id: channelId,
            click_action: 'FLUTTER_NOTIFICATION_CLICK',
          },
          data: Object.fromEntries(
            Object.entries({
              ...data,
              title: String(title || 'Privet'),
              body: String(body || ''),
            }).map(([k, v]) => [k, String(v ?? '')]),
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
    data: { ...data, type: data.type || 'message' },
    isCall: false,
  });
}
