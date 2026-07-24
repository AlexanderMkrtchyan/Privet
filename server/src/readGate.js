/** conversationId -> epoch ms of last message create/broadcast */
const recentMessageAt = new Map();

export function noteConversationMessage(conversationId) {
  if (!conversationId) return;
  recentMessageAt.set(conversationId, Date.now());
}

/**
 * Idle windows used to mark-read the instant a message arrived.
 * Reject those auto-acks unless the client asserts it is focused,
 * or enough time has passed that it is likely a deliberate open.
 */
export function shouldAcceptMarkRead(conversationId, { focused } = {}) {
  if (focused === true) return true;
  const recent = recentMessageAt.get(conversationId) || 0;
  return Date.now() - recent >= 800;
}
