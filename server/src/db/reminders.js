import { v4 as uuid } from 'uuid';
import { db, publicUser } from '../db.js';
import { getUserById } from '../auth/users.js';
import { userInConversation } from './chat.js';

function mapExpense(row) {
  if (!row) return null;
  return {
    id: row.id,
    paymentId: row.payment_id,
    label: row.label || '',
    amountCents: row.amount_cents ?? 0,
    createdBy: row.created_by || null,
    sortOrder: row.sort_order ?? 0,
    createdAt: row.created_at,
  };
}

function listExpensesForPayment(paymentId) {
  const rows = db
    .prepare(
      `SELECT * FROM payment_expenses
       WHERE payment_id = ?
       ORDER BY sort_order ASC, created_at ASC`,
    )
    .all(paymentId);
  return rows.map(mapExpense);
}

function mapReminder(row) {
  if (!row) return null;
  const creator = row.created_by ? getUserById(row.created_by) : null;
  const paidByUser = row.paid_by ? getUserById(row.paid_by) : null;
  const expenses = row.kind === 'payment' ? listExpensesForPayment(row.id) : [];
  return {
    id: row.id,
    conversationId: row.conversation_id,
    createdBy: creator ? publicUser(creator) : null,
    kind: row.kind || 'payment',
    amountCents: row.kind === 'reminder' ? null : (row.amount_cents ?? null),
    currency: row.currency,
    direction: row.direction,
    note: row.note || '',
    dueDate: row.due_date,
    paid: !!row.paid,
    paidAt: row.paid_at || null,
    paidBy: paidByUser ? publicUser(paidByUser) : null,
    snoozedUntil: row.snoozed_until || null,
    pinned: !!row.pinned,
    expenses,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

/** Active reminders: all unpaid, pinned first then by due date. */
export function listReminders(conversationId) {
  const rows = db
    .prepare(
      `SELECT * FROM payment_reminders
       WHERE conversation_id = ?
         AND paid = 0
       ORDER BY pinned DESC, due_date ASC, created_at ASC`,
    )
    .all(conversationId);
  return rows.map(mapReminder);
}

/** Paid/past reminders for history view. */
export function listReminderHistory(conversationId) {
  const rows = db
    .prepare(
      `SELECT * FROM payment_reminders
       WHERE conversation_id = ? AND paid = 1
       ORDER BY paid_at DESC, due_date DESC`,
    )
    .all(conversationId);
  return rows.map(mapReminder);
}

export function getReminder(id) {
  const row = db.prepare('SELECT * FROM payment_reminders WHERE id = ?').get(id);
  return mapReminder(row);
}

export function createReminder({ conversationId, createdBy, kind, amountCents, currency, direction, note, dueDate }) {
  if (!userInConversation(conversationId, createdBy)) throw new Error('forbidden');
  if (!dueDate) throw new Error('due date required');
  const k = kind === 'reminder' ? 'reminder' : 'payment';
  if (k === 'payment' && (!amountCents || amountCents <= 0)) throw new Error('invalid amount');

  const id = uuid();
  const now = new Date().toISOString();
  // Reminders without amount: store NULL (or 0 on legacy NOT NULL schemas).
  const cents = k === 'reminder' ? null : amountCents;
  db.prepare(
    `INSERT INTO payment_reminders
       (id, conversation_id, created_by, kind, amount_cents, currency, direction, note, due_date, paid, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)`,
  ).run(id, conversationId, createdBy, k, cents, currency || 'USD', direction || 'owe', note || '', dueDate, now, now);

  return getReminder(id);
}

export function updateReminder(id, userId, patch) {
  const existing = db.prepare('SELECT * FROM payment_reminders WHERE id = ?').get(id);
  if (!existing) throw new Error('not found');
  if (!userInConversation(existing.conversation_id, userId)) throw new Error('forbidden');

  const now = new Date().toISOString();
  const amountCents = patch.amountCents !== undefined ? patch.amountCents : existing.amount_cents;
  const currency = patch.currency !== undefined ? patch.currency : existing.currency;
  const direction = patch.direction !== undefined ? patch.direction : existing.direction;
  const note = patch.note !== undefined ? patch.note : existing.note;
  const dueDate = patch.dueDate !== undefined ? patch.dueDate : existing.due_date;
  const snoozedUntil = patch.snoozedUntil !== undefined ? patch.snoozedUntil : existing.snoozed_until;
  let pinned = existing.pinned;
  if (patch.pinned !== undefined) {
    pinned = patch.pinned ? 1 : 0;
    // Only one of each kind can be pinned to the chat header.
    if (pinned) {
      db.prepare(
        `UPDATE payment_reminders SET pinned = 0
         WHERE conversation_id = ? AND kind = ? AND id != ? AND paid = 0`,
      ).run(existing.conversation_id, existing.kind, id);
    }
  }

  let paid = existing.paid;
  let paidAt = existing.paid_at;
  let paidBy = existing.paid_by;
  if (patch.paid !== undefined) {
    paid = patch.paid ? 1 : 0;
    paidAt = patch.paid ? (existing.paid_at || now) : null;
    paidBy = patch.paid ? (patch.paidBy || userId) : null;
  }

  const cents = existing.kind === 'reminder' && amountCents == null ? null : amountCents;

  db.prepare(
    `UPDATE payment_reminders
     SET amount_cents=?, currency=?, direction=?, note=?, due_date=?, paid=?, paid_at=?, paid_by=?, snoozed_until=?, pinned=?, updated_at=?
     WHERE id=?`,
  ).run(cents, currency, direction, note, dueDate, paid, paidAt, paidBy, snoozedUntil, pinned, now, id);

  return getReminder(id);
}

export function deleteReminder(id, userId) {
  const existing = db.prepare('SELECT * FROM payment_reminders WHERE id = ?').get(id);
  if (!existing) throw new Error('not found');
  if (!userInConversation(existing.conversation_id, userId)) throw new Error('forbidden');
  db.prepare('DELETE FROM payment_expenses WHERE payment_id = ?').run(id);
  db.prepare('DELETE FROM payment_reminders WHERE id = ?').run(id);
  return { conversationId: existing.conversation_id, deletedId: id };
}

/** Returns reminders whose due_date is today and not yet paid and not snoozed. */
export function getDueReminders() {
  const today = new Date().toISOString().slice(0, 10);
  const nowIso = new Date().toISOString();
  const rows = db
    .prepare(
      `SELECT * FROM payment_reminders
       WHERE due_date <= ?
         AND paid = 0
         AND (snoozed_until IS NULL OR snoozed_until < ?)`,
    )
    .all(today, nowIso);
  return rows.map(mapReminder);
}

function sumExpenseCents(paymentId, excludeId = null) {
  const rows = db
    .prepare('SELECT id, amount_cents FROM payment_expenses WHERE payment_id = ?')
    .all(paymentId);
  return rows
    .filter((r) => r.id !== excludeId)
    .reduce((sum, r) => sum + (r.amount_cents ?? 0), 0);
}

function assertExpenseBudget(payment, amountCents, excludeExpenseId = null) {
  if (!payment.paid) throw new Error('expenses only on paid payments');
  const budget = payment.amount_cents;
  if (budget == null || budget <= 0) throw new Error('invalid payment amount');
  const spent = sumExpenseCents(payment.id, excludeExpenseId);
  if (spent + amountCents > budget) throw new Error('exceeds payment amount');
}

export function createExpense({ paymentId, userId, label, amountCents }) {
  const payment = db.prepare('SELECT * FROM payment_reminders WHERE id = ?').get(paymentId);
  if (!payment) throw new Error('not found');
  if (!userInConversation(payment.conversation_id, userId)) throw new Error('forbidden');
  if (payment.kind !== 'payment') throw new Error('expenses only on payments');
  if (!label || !String(label).trim()) throw new Error('label required');
  const cents = Number(amountCents);
  if (!Number.isFinite(cents) || cents <= 0) throw new Error('invalid amount');
  assertExpenseBudget(payment, Math.round(cents));

  const maxOrder = db
    .prepare('SELECT COALESCE(MAX(sort_order), 0) AS m FROM payment_expenses WHERE payment_id = ?')
    .get(paymentId).m;

  const id = uuid();
  const now = new Date().toISOString();
  db.prepare(
    `INSERT INTO payment_expenses
       (id, payment_id, label, amount_cents, created_by, sort_order, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?)`,
  ).run(id, paymentId, String(label).trim().slice(0, 120), Math.round(cents), userId, maxOrder + 1, now);

  return {
    expense: mapExpense(db.prepare('SELECT * FROM payment_expenses WHERE id = ?').get(id)),
    conversationId: payment.conversation_id,
    paymentId,
  };
}

export function updateExpense(id, userId, patch) {
  const existing = db.prepare('SELECT * FROM payment_expenses WHERE id = ?').get(id);
  if (!existing) throw new Error('not found');
  const payment = db.prepare('SELECT * FROM payment_reminders WHERE id = ?').get(existing.payment_id);
  if (!payment) throw new Error('not found');
  if (!userInConversation(payment.conversation_id, userId)) throw new Error('forbidden');

  const label = patch.label !== undefined ? String(patch.label).trim().slice(0, 120) : existing.label;
  let amountCents = existing.amount_cents;
  if (patch.amountCents !== undefined) {
    const cents = Number(patch.amountCents);
    if (!Number.isFinite(cents) || cents <= 0) throw new Error('invalid amount');
    amountCents = Math.round(cents);
  }
  if (!label) throw new Error('label required');
  assertExpenseBudget(payment, amountCents, id);

  db.prepare(
    `UPDATE payment_expenses SET label = ?, amount_cents = ? WHERE id = ?`,
  ).run(label, amountCents, id);

  return {
    expense: mapExpense(db.prepare('SELECT * FROM payment_expenses WHERE id = ?').get(id)),
    conversationId: payment.conversation_id,
    paymentId: payment.id,
  };
}

export function deleteExpense(id, userId) {
  const existing = db.prepare('SELECT * FROM payment_expenses WHERE id = ?').get(id);
  if (!existing) throw new Error('not found');
  const payment = db.prepare('SELECT * FROM payment_reminders WHERE id = ?').get(existing.payment_id);
  if (!payment) throw new Error('not found');
  if (!userInConversation(payment.conversation_id, userId)) throw new Error('forbidden');
  db.prepare('DELETE FROM payment_expenses WHERE id = ?').run(id);
  return { conversationId: payment.conversation_id, paymentId: payment.id, deletedId: id };
}
