import 'dart:convert';

/// Packed body for chat `kind: task_event` rows.
///
/// These are system rows the server inserts into the chat whenever a *big*
/// task change happens (task/subtask added, status / priority / assignee
/// changed, task deleted). The body carries structured fields plus a plain
/// [summary]; the client renders the summary as a clickable pill and, when the
/// user taps it, opens the Tasks pane and reveals the affected task.
class TaskEventPayload {
  const TaskEventPayload({
    required this.action,
    this.taskId,
    this.parentId,
    this.task,
    this.parent,
    this.from,
    this.to,
    required this.summary,
  });

  /// created | subtask | status | priority | assigned | deleted
  final String action;
  final String? taskId;
  final String? parentId;

  /// Short plain label of the affected task ("Chapter 1").
  final String? task;

  /// Short plain label of the containing parent task, when the event is about
  /// a subtask ("Book").
  final String? parent;

  /// Human-readable old value (status/priority label or display name).
  final String? from;

  /// Human-readable new value.
  final String? to;

  /// Full one-line sentence, e.g. "Alex changed status of “Book” from Review
  /// to Done". Server-authored so every client renders the same wording.
  final String summary;

  static TaskEventPayload? tryParse(String body) {
    final raw = body.trim();
    if (raw.isEmpty || raw[0] != '{') return null;
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return null;
      final action = (map['action'] as String?)?.trim() ?? '';
      if (action.isEmpty) return null;
      return TaskEventPayload(
        action: action,
        taskId: map['taskId'] as String?,
        parentId: map['parentId'] as String?,
        task: map['task'] as String?,
        parent: map['parent'] as String?,
        from: map['from'] as String?,
        to: map['to'] as String?,
        summary: (map['summary'] as String?)?.trim() ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  /// Fallback wording for bodies written before summaries existed.
  String get label {
    if (summary.isNotEmpty) return summary;
    final q = (String? s) => s == null || s.isEmpty ? '' : '“$s”';
    switch (action) {
      case 'created':
        return 'added task ${q(task)}';
      case 'subtask':
        return parent == null || parent!.isEmpty
            ? 'added subtask ${q(task)}'
            : 'added subtask ${q(task)} to ${q(parent)}';
      case 'status':
        return from == null
            ? 'set status of ${q(task)} to $to'
            : 'changed status of ${q(task)} from $from to $to';
      case 'priority':
        return from == null
            ? 'set priority of ${q(task)} to $to'
            : 'changed priority of ${q(task)} from $from to $to';
      case 'assigned':
        return to == null
            ? 'cleared the assignee of ${q(task)}'
            : 'assigned ${q(task)} to $to';
      case 'deleted':
        return 'deleted task ${q(task)}';
      default:
        return 'updated ${q(task)}';
    }
  }

  /// Conversation-list preview helper (same role as CallHistoryPayload.preview).
  static String preview(String body) {
    final parsed = tryParse(body);
    if (parsed != null) return '📋 ${parsed.label}';
    final trimmed = body.trim();
    return trimmed.isEmpty ? '📋 Task update' : '📋 $trimmed';
  }
}
