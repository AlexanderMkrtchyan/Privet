/**
 * Pure helpers for 1:1 call / remote-control authorization.
 * Kept free of Fastify/DB imports so unit tests can import them safely.
 */

export function isCallParticipant(call, userId) {
  return !!(call && (userId === call.fromUserId || userId === call.toUserId));
}

export function peerUserId(call, userId) {
  if (!call) return null;
  if (userId === call.fromUserId) return call.toUserId;
  if (userId === call.toUserId) return call.fromUserId;
  return null;
}

/**
 * Media/control signaling may only be relayed by an active call participant
 * to the other participant.
 */
export function canRelayCallSignal(call, fromUserId, toUserId) {
  if (!call || call.status !== 'active') return false;
  if (!isCallParticipant(call, fromUserId)) return false;
  return peerUserId(call, fromUserId) === toUserId;
}

export function canGrantControl(call, fromUserId, toUserId) {
  return canRelayCallSignal(call, fromUserId, toUserId);
}

export function canRequestControl(call, fromUserId, toUserId) {
  return canRelayCallSignal(call, fromUserId, toUserId);
}

/**
 * Build the outbound payload for control_* signaling.
 * Preserves a trimmed deny reason (capped) so controllers see the real cause.
 */
export function buildControlSignalOutbound(msg, { callId, fromUserId, toUserId }) {
  const outbound = {
    type: msg.type,
    callId,
    fromUserId,
    toUserId,
  };
  if (
    msg.type === 'call.control_deny' &&
    typeof msg.reason === 'string' &&
    msg.reason.trim()
  ) {
    outbound.reason = msg.reason.trim().slice(0, 500);
  }
  return outbound;
}
