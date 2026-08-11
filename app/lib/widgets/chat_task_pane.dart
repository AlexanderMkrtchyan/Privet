import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models.dart';
import '../state.dart';
import '../theme.dart';
import '../util/clipboard_files.dart';
import '../util/perf.dart';
import 'payment_spending_insights.dart';
import 'privet_date_picker.dart';
import 'web_attach_button.dart';

/// Shared outer height for chat header chips (tasks, reminders, media, calls).
const double kChatHeaderChipHeight = 43;

/// Compact creation-date label for a task row, e.g. "Aug 5, 2026".
String _fmtTaskDate(DateTime dt) {
  const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  final local = dt.toLocal();
  return '${months[local.month - 1]} ${local.day}, ${local.year}';
}

/// Wraps a pinned header chip and reveals a close (unpin) button at its top
/// right corner while hovered.
class _HeaderChipHoverClose extends StatefulWidget {
  const _HeaderChipHoverClose({required this.onClose, required this.child});

  final VoidCallback? onClose;
  final Widget child;

  @override
  State<_HeaderChipHoverClose> createState() => _HeaderChipHoverCloseState();
}

class _HeaderChipHoverCloseState extends State<_HeaderChipHoverClose> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final onClose = widget.onClose;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          widget.child,
          if (_hovering && onClose != null)
            Positioned(
              top: -6,
              right: -6,
              child: Semantics(
                button: true,
                label: 'Unpin',
                child: Tooltip(
                  message: 'Unpin',
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onClose,
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: PrivetTheme.ink,
                        shape: BoxShape.circle,
                        border: Border.all(color: PrivetTheme.line),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.35),
                            blurRadius: 4,
                            offset: const Offset(0, 1),
                          ),
                        ],
                      ),
                      child: Icon(
                        Icons.close_rounded,
                        size: 13,
                        color: PrivetTheme.paper,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Compact header control: pinned task name + 3/10 progress (or "Task done").
class TaskHeaderChip extends StatelessWidget {
  const TaskHeaderChip({
    super.key,
    required this.board,
    required this.active,
    required this.onTap,
    this.onUnpin,
    this.pinnedTask,
  });

  final ConversationTasks board;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback? onUnpin;
  final TaskItem? pinnedTask;

  @override
  Widget build(BuildContext context) {
    final pinned = pinnedTask ?? board.pinnedTask;
    final prog = pinned != null
        ? board.progressFor(pinned)
        : (done: board.doneCount, total: board.total);
    final done = prog.total == 0 || prog.done >= prog.total;
    final fill = done ? PrivetTheme.signal : PrivetTheme.signalDim;
    final track = done
        ? PrivetTheme.signal.withValues(alpha: 0.22)
        : PrivetTheme.signalDim.withValues(alpha: 0.18);
    final name = (pinned?.body.trim().isNotEmpty == true)
        ? pinned!.body.trim()
        : 'Task';
    final progressLabel = done ? 'done' : '${prog.done}/${prog.total}';
    final label = '$name · $progressLabel';
    final progressValue =
        prog.total == 0 ? 1.0 : (prog.done / prog.total).clamp(0.0, 1.0);

    return Semantics(
      button: true,
      label: done
          ? 'Task "$name" done. Open task board'
          : 'Task "$name": ${prog.done} of ${prog.total} done. Open task board',
                      child: Tooltip(
                        message: done
                            ? 'Open tasks — $name complete'
                            : 'Open tasks — $name · ${prog.done} of ${prog.total} done',
                        child: _HeaderChipHoverClose(
                          onClose: onUnpin,
                          child: Material(
                            color: Colors.transparent,
                            child: Ink(
                              decoration: BoxDecoration(
                                color: active
                                    ? PrivetTheme.panelElevated
                                    : PrivetTheme.ink.withValues(alpha: 0.35),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: active
                                      ? fill.withValues(alpha: 0.7)
                                      : done
                                          ? PrivetTheme.signal.withValues(
                                              alpha: 0.45,
                                            )
                                          : PrivetTheme.line,
                                ),
                              ),
                              child: InkWell(
                                onTap: onTap,
                                mouseCursor: SystemMouseCursors.click,
                                borderRadius: BorderRadius.circular(12),
                                hoverColor: PrivetTheme.paper.withValues(
                                  alpha: 0.06,
                                ),
                                splashColor: PrivetTheme.paper.withValues(
                                  alpha: 0.08,
                                ),
                                child: Container(
                                  height: kChatHeaderChipHeight,
                                  constraints: const BoxConstraints(
                                    minWidth: 72,
                                    maxWidth: 170,
                                  ),
                                  padding: const EdgeInsets.fromLTRB(10, 3, 6, 3),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            done
                                                ? Icons.check_circle_rounded
                                                : Icons.checklist_rtl_rounded,
                                            size: 12,
                                            color: fill,
                                          ),
                                          const SizedBox(width: 4),
                                          Flexible(
                                            child: Text(
                                              label,
                                              overflow: TextOverflow.ellipsis,
                                              style: GoogleFonts.syne(
                                                fontWeight: FontWeight.w700,
                                                fontSize: 11,
                                                color: done
                                                    ? PrivetTheme.signal
                                                    : PrivetTheme.paper,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                      IgnorePointer(
                                        child: ExcludeSemantics(
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              99,
                                            ),
                                            child: TweenAnimationBuilder<double>(
                                              tween: Tween(
                                                begin: 0,
                                                end: progressValue,
                                              ),
                                              duration: const Duration(
                                                milliseconds: 280,
                                              ),
                                              curve: Curves.easeOutCubic,
                                              builder: (context, value, _) {
                                                return LinearProgressIndicator(
                                                  value: value.clamp(0.0, 1.0),
                                                  minHeight: 3,
                                                  backgroundColor: track,
                                                  color: fill,
                                                );
                                              },
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
    );
  }
}

/// Tabbed side panel: Tasks | Reminders, each with active + history sections.
class ChatTaskPane extends StatefulWidget {
  const ChatTaskPane({
    super.key,
    required this.state,
    required this.conversationId,
    required this.mediaBase,
    required this.onClose,
    this.initialTab = 0,
  });

  final PrivetState state;
  final String conversationId;
  final String mediaBase;
  final VoidCallback onClose;
  final int initialTab;

  @override
  State<ChatTaskPane> createState() => _ChatTaskPaneState();
}

class _ChatTaskPaneState extends State<ChatTaskPane> with SingleTickerProviderStateMixin {
  late final TabController _tab;
  final _taskScrollCtrl = ScrollController();
  final _addCtrl = TextEditingController();
  final _addFocus = FocusNode();
  final List<PickedBytes> _draftAttach = [];
  final List<TextEditingController> _draftSubtasks = [];
  bool _saving = false;
  bool _loadingTaskHistory = false;
  static const _maxFiles = 10;

  @override
  void initState() {
    super.initState();
    _tab = TabController(
      length: 3,
      vsync: this,
      initialIndex: widget.initialTab.clamp(0, 2),
    );
    _taskScrollCtrl.addListener(_onTaskScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.state.refreshReminderHistory(widget.conversationId);
      widget.state.refreshTaskHistory(widget.conversationId);
    });
  }

  void _onTaskScroll() {
    if (!_taskScrollCtrl.hasClients || _loadingTaskHistory) return;
    final pos = _taskScrollCtrl.position;
    if (pos.pixels >= pos.maxScrollExtent - 160) {
      _loadMoreTaskHistory();
    }
  }

  /// Ctrl+scroll over the task pane zooms task text (independent of the chat
  /// font size). Registers with the pointer-signal resolver before the pane's
  /// Scrollables so a Ctrl+wheel zooms instead of scrolling the list.
  void _onPointerSignal(PointerSignalEvent e) {
    if (!HardwareKeyboard.instance.isControlPressed) return;
    final double dy;
    if (e is PointerScrollEvent) {
      dy = e.scrollDelta.dy;
    } else if (e is PointerScaleEvent) {
      // Web: scale = exp(-deltaY / 200) → undo that map so both platforms
      // share the same step logic as the chat zoom.
      dy = -200 * math.log(e.scale);
    } else {
      return;
    }
    if (dy == 0) return;
    final step = dy < 0 ? 0.5 : -0.5;
    GestureBinding.instance.pointerSignalResolver.register(
      e,
      (_) => unawaited(
        widget.state.setTaskFontSize(widget.state.taskFontSize + step),
      ),
    );
  }

  /// Only the task creator can approve a done task (server enforces it too).
  bool _canApprove(TaskItem item) {
    final uid = widget.state.user?.id;
    return uid != null &&
        item.createdBy?.id == uid &&
        item.done &&
        !item.doneConfirmed;
  }

  Future<void> _loadMoreTaskHistory() async {
    if (_loadingTaskHistory) return;
    if (!widget.state.taskHistoryHasMore(widget.conversationId)) return;
    setState(() => _loadingTaskHistory = true);
    try {
      await widget.state.loadOlderTaskHistory(widget.conversationId);
    } finally {
      if (mounted) setState(() => _loadingTaskHistory = false);
    }
  }

  @override
  void dispose() {
    _tab.dispose();
    _taskScrollCtrl.removeListener(_onTaskScroll);
    _taskScrollCtrl.dispose();
    _addCtrl.dispose();
    _addFocus.dispose();
    for (final c in _draftSubtasks) {
      c.dispose();
    }
    super.dispose();
  }

  void _addDraftSubtask() {
    setState(() => _draftSubtasks.add(TextEditingController()));
  }

  void _removeDraftSubtask(int index) {
    setState(() {
      _draftSubtasks.removeAt(index).dispose();
    });
  }

  void _addDraftFiles(Iterable<PickedBytes> files) {
    setState(() {
      for (final f in files) {
        if (_draftAttach.length >= _maxFiles) break;
        _draftAttach.add(f);
      }
    });
  }

  Future<void> _pickDraftFiles() async {
    try {
      final remaining = _maxFiles - _draftAttach.length;
      if (remaining <= 0) {
        widget.state.setError('Max $_maxFiles files per task');
        return;
      }
      final picked = kIsWeb
          ? await pickMultipleFilesNative(maxFiles: remaining)
          : await _pickFilesViaFilePicker(remaining);
      if (picked.isEmpty) return;
      _addDraftFiles(picked);
    } catch (e) {
      widget.state.setError('Attach failed: $e');
    }
  }

  Future<List<PickedBytes>> _pickFilesViaFilePicker(int maxFiles) async {
    final result = await FilePicker.platform.pickFiles(
      withData: true,
      type: FileType.any,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return const [];
    final picked = <PickedBytes>[];
    for (final file in result.files) {
      if (picked.length >= maxFiles) break;
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) continue;
      picked.add(PickedBytes(
        bytes: bytes,
        filename: file.name,
        mimeType: _mimeFor(file.name),
      ));
    }
    return picked;
  }

  Future<List<MediaAttachment>> _uploadDrafts(List<PickedBytes> drafts) async {
    final out = <MediaAttachment>[];
    for (final draft in drafts.take(_maxFiles)) {
      final up = await widget.state.api.uploadBytes(
        bytes: draft.bytes,
        filename: draft.filename,
        mimeType: draft.mimeType,
      );
      out.add(MediaAttachment(
        mediaUrl: up.mediaUrl,
        kind: draft.mimeType.startsWith('image/') ? 'image' : 'file',
        mimeType: up.mimeType,
        fileName: up.fileName,
      ));
    }
    return out;
  }

  Future<void> _submitNew() async {
    final text = _addCtrl.text.trim();
    final subtaskBodies = _draftSubtasks
        .map((c) => c.text.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    if (text.isEmpty && _draftAttach.isEmpty) return;
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final uploaded = await _uploadDrafts(List.of(_draftAttach));
      final body = text.isEmpty
          ? (uploaded.length == 1
              ? (uploaded.first.fileName ?? 'Attachment')
              : uploaded.isNotEmpty
                  ? '${uploaded.length} files'
                  : 'Task')
          : text;
      final parent = await widget.state.addTask(
        conversationId: widget.conversationId,
        body: body,
        mediaUrl: uploaded.isNotEmpty ? uploaded.first.mediaUrl : null,
        mimeType: uploaded.isNotEmpty ? uploaded.first.mimeType : null,
        fileName: uploaded.isNotEmpty ? uploaded.first.fileName : null,
        attachments: uploaded.isNotEmpty ? uploaded : null,
      );
      for (final sub in subtaskBodies) {
        await widget.state.addTask(
          conversationId: widget.conversationId,
          body: sub,
          parentId: parent.id,
        );
      }
      _addCtrl.clear();
      for (final c in _draftSubtasks) {
        c.dispose();
      }
      setState(() {
        _draftAttach.clear();
        _draftSubtasks.clear();
      });
      _addFocus.requestFocus();
    } catch (e) {
      widget.state.setError('Could not add task: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _attachToItem(TaskItem item) async {
    try {
      final remaining = _maxFiles - item.mediaItems.length;
      if (remaining <= 0) {
        widget.state.setError('Max $_maxFiles files per task');
        return;
      }
      final picked = kIsWeb
          ? await pickMultipleFilesNative(maxFiles: remaining)
          : await _pickFilesViaFilePicker(remaining);
      if (picked.isEmpty) return;
      final next = List<MediaAttachment>.from(item.mediaItems);
      for (final draft in picked) {
        if (next.length >= _maxFiles) break;
        final up = await widget.state.api.uploadBytes(
          bytes: draft.bytes,
          filename: draft.filename,
          mimeType: draft.mimeType,
        );
        next.add(MediaAttachment(
          mediaUrl: up.mediaUrl,
          kind: draft.mimeType.startsWith('image/') ? 'image' : 'file',
          mimeType: up.mimeType,
          fileName: up.fileName,
        ));
      }
      await widget.state.setTaskAttachments(item: item, attachments: next);
    } catch (e) {
      widget.state.setError('Could not attach: $e');
    }
  }

  String _mimeFor(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    return 'application/octet-stream';
  }

  @override
  Widget build(BuildContext context) {
    final board = widget.state.taskBoardFor(widget.conversationId);
    final activeItems = board.activeItems;
    final historyBoard = widget.state.taskHistoryBoardFor(widget.conversationId);
    final historyRoots = historyBoard.rootItems;
    final historyLoading =
        widget.state.taskHistoryLoadingOlder.contains(widget.conversationId);
    final historyHasMore = widget.state.taskHistoryHasMore(widget.conversationId);
    final reminders = widget.state.remindersFor(widget.conversationId);
    final activePayments = reminders.where((r) => !r.paid && r.isPayment).toList();
    final activePlainReminders = reminders.where((r) => !r.paid && !r.isPayment).toList();
    final historyAll = widget.state.reminderHistoryFor(widget.conversationId);
    final paymentHistory = historyAll.where((r) => r.isPayment).toList();
    final reminderHistory = historyAll.where((r) => !r.isPayment).toList();

    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
        // ── Header ──────────────────────────────────────────────────────────
        Container(
          decoration: BoxDecoration(
            color: PrivetTheme.panelElevated,
            border: Border(bottom: BorderSide(color: PrivetTheme.line)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 8, 0),
                child: Row(
                  children: [
                    Text(
                      'Tasks · Payments · Reminders',
                      style: GoogleFonts.syne(fontWeight: FontWeight.w700, fontSize: 16),
                    ),
                    const Spacer(),
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: IconButton(
                        tooltip: 'Close',
                        onPressed: widget.onClose,
                        icon: const Icon(Icons.close_rounded),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ],
                ),
              ),
              TabBar(
                controller: _tab,
                indicatorColor: PrivetTheme.signal,
                labelColor: PrivetTheme.signal,
                unselectedLabelColor: PrivetTheme.mist,
                labelStyle: GoogleFonts.syne(fontWeight: FontWeight.w700, fontSize: 13),
                unselectedLabelStyle: GoogleFonts.syne(fontSize: 13),
                tabs: [
                  Tab(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Tasks'),
                        if (activeItems.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          _CountBadge(activeItems.length, color: PrivetTheme.signal),
                        ],
                      ],
                    ),
                  ),
                  Tab(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Payments'),
                        if (activePayments.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          _CountBadge(
                            activePayments.length,
                            color: activePayments.any((r) => r.isOverdue)
                                ? PrivetTheme.danger
                                : PrivetTheme.signal,
                          ),
                        ],
                      ],
                    ),
                  ),
                  Tab(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Reminders'),
                        if (activePlainReminders.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          _CountBadge(
                            activePlainReminders.length,
                            color: activePlainReminders.any((r) => r.isOverdue)
                                ? PrivetTheme.danger
                                : PrivetTheme.signal,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        // ── Body ─────────────────────────────────────────────────────────────
        Expanded(
          child: TabBarView(
            controller: _tab,
            children: [
              // ── TASKS TAB ──────────────────────────────────────────────────
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (activeItems.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: _TaskProgressBar(board: board),
                    ),
                  Expanded(
                    child: ListView(
                      controller: _taskScrollCtrl,
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                      children: [
                        if (activeItems.isEmpty && historyRoots.isEmpty)
                          _EmptyState(
                            icon: Icons.task_alt_rounded,
                            color: PrivetTheme.signal,
                            title: 'No open tasks',
                            subtitle: 'Add a task with subtasks below, or right-click any message → Add to task',
                          )
                        else ...[
                          if (activeItems.isNotEmpty) ...[
                            _SectionLabel('To do — ${activeItems.length}'),
                            const SizedBox(height: 6),
                            ...activeItems.asMap().entries.map((e) {
                              final subtasks = board.subtasksOf(e.value.id);
                              final prog = board.progressFor(e.value);
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: _TaskRow(
                                  number: e.key + 1,
                                  item: e.value,
                                  taskFontSize: widget.state.taskFontSize,
                                  mediaBase: widget.mediaBase,
                                  myUserId: widget.state.user?.id,
                                  subtasks: subtasks,
                                  progressLabel: (e.value.subtaskTotal ?? 0) > 0
                                      ? '${prog.done}/${prog.total}'
                                      : null,
                                  onToggle: () => widget.state.toggleTaskDone(e.value),
                                  onConfirmDone: _canApprove(e.value)
                                      ? () => widget.state.confirmTaskDone(e.value)
                                      : null,
                                  onSaveBody: (body) => widget.state.updateTaskBody(e.value, body),
                                  onDelete: () => widget.state.deleteTask(e.value),
                                  onRemoveAttachment: (url) =>
                                      widget.state.removeTaskAttachment(e.value, url),
                                  onAttach: () => _attachToItem(e.value),
                                  onPin: () => widget.state.toggleTaskPin(e.value),
                                  onAddSubtask: (body) => widget.state.addTask(
                                    conversationId: widget.conversationId,
                                    body: body,
                                    parentId: e.value.id,
                                  ),
                                  onToggleSubtask: (sub) => widget.state.toggleTaskDone(sub),
                                  onConfirmSubtask: (sub) => _canApprove(sub)
                                      ? () => widget.state.confirmTaskDone(sub)
                                      : null,
                                  onSaveSubtaskBody: (sub, body) =>
                                      widget.state.updateTaskBody(sub, body),
                                  onDeleteSubtask: (sub) => widget.state.deleteTask(sub),
                                  onAttachSubtask: (sub) => _attachToItem(sub),
                                  onRemoveSubtaskAttachment: (sub, url) =>
                                      widget.state.removeTaskAttachment(sub, url),
                                ),
                              );
                            }),
                          ],
                          if (historyRoots.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            _SectionLabel(
                              historyHasMore
                                  ? 'History — ${historyRoots.length}+'
                                  : 'History — ${historyRoots.length}',
                            ),
                            const SizedBox(height: 6),
                            ...historyRoots.asMap().entries.map((e) => Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: _TaskRow(
                                number: e.key + 1,
                                item: e.value,
                                taskFontSize: widget.state.taskFontSize,
                                mediaBase: widget.mediaBase,
                                myUserId: widget.state.user?.id,
                                subtasks: historyBoard.subtasksOf(e.value.id),
                                progressLabel: null,
                                onToggle: null,
                                onConfirmDone: null,
                                onSaveBody: null,
                                onDelete: null,
                                onRemoveAttachment: null,
                                onAttach: null,
                                onPin: null,
                                onAddSubtask: null,
                                onToggleSubtask: null,
                                onConfirmSubtask: null,
                                onSaveSubtaskBody: null,
                                onDeleteSubtask: null,
                                onAttachSubtask: null,
                                onRemoveSubtaskAttachment: null,
                              ),
                            )),
                            if (historyLoading || _loadingTaskHistory)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 12),
                                child: Center(
                                  child: SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  ),
                                ),
                              )
                            else if (historyHasMore)
                              Padding(
                                padding: const EdgeInsets.only(top: 4, bottom: 8),
                                child: Center(
                                  child: Text(
                                    'Scroll for more…',
                                    style: GoogleFonts.ibmPlexSans(
                                      fontSize: 11,
                                      color: PrivetTheme.mist.withValues(alpha: 0.55),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ],
                      ],
                    ),
                  ),
                  // Add-task bar
                  Container(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                    decoration: BoxDecoration(
                      border: Border(top: BorderSide(color: PrivetTheme.line)),
                      color: PrivetTheme.panelElevated,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_draftAttach.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: SizedBox(
                              height: 72,
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                itemCount: _draftAttach.length,
                                separatorBuilder: (_, __) => const SizedBox(width: 8),
                                itemBuilder: (context, i) {
                                  final draft = _draftAttach[i];
                                  return Stack(
                                    clipBehavior: Clip.none,
                                    children: [
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(10),
                                        child: draft.mimeType.startsWith('image/')
                                            ? Image.memory(draft.bytes, width: 72, height: 72, fit: BoxFit.cover)
                                            : Container(
                                                width: 72,
                                                height: 72,
                                                color: PrivetTheme.ink,
                                                alignment: Alignment.center,
                                                child: const Icon(Icons.insert_drive_file),
                                              ),
                                      ),
                                      Positioned(
                                        top: -6,
                                        right: -6,
                                        child: MouseRegion(
                                          cursor: SystemMouseCursors.click,
                                          child: Material(
                                            color: PrivetTheme.panelElevated,
                                            shape: const CircleBorder(),
                                            child: InkWell(
                                              customBorder: const CircleBorder(),
                                              onTap: () => setState(() => _draftAttach.removeAt(i)),
                                              child: const Padding(
                                                padding: EdgeInsets.all(2),
                                                child: Icon(Icons.close_rounded, size: 16),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                            ),
                          ),
                        if (_draftSubtasks.isNotEmpty) ...[
                          for (var i = 0; i < _draftSubtasks.length; i++)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Row(
                                children: [
                                  const SizedBox(width: 8),
                                  Icon(Icons.subdirectory_arrow_right_rounded,
                                      size: 16, color: PrivetTheme.mist.withValues(alpha: 0.7)),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: TextField(
                                      controller: _draftSubtasks[i],
                                      style: GoogleFonts.ibmPlexSans(fontSize: 13),
                                      decoration: const InputDecoration(
                                        hintText: 'Subtask…',
                                        isDense: true,
                                        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Remove subtask',
                                    onPressed: () => _removeDraftSubtask(i),
                                    icon: const Icon(Icons.close_rounded, size: 16),
                                    color: PrivetTheme.mist,
                                    visualDensity: VisualDensity.compact,
                                  ),
                                ],
                              ),
                            ),
                        ],
                        Row(
                          children: [
                            WebAttachButton(
                              tooltip: 'Attach files (up to 10)',
                              onPicked: (file) => _addDraftFiles([file]),
                              onPressedFallback: _pickDraftFiles,
                              onError: (e) => widget.state.setError('Attach failed: $e'),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: TextField(
                                controller: _addCtrl,
                                focusNode: _addFocus,
                                textInputAction: TextInputAction.done,
                                onSubmitted: (_) => _submitNew(),
                                decoration: const InputDecoration(
                                  hintText: 'Add a task…',
                                  isDense: true,
                                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: IconButton(
                                tooltip: 'Add subtask',
                                onPressed: _addDraftSubtask,
                                icon: const Icon(Icons.playlist_add_rounded, size: 20),
                                color: PrivetTheme.mist,
                                visualDensity: VisualDensity.compact,
                              ),
                            ),
                            const SizedBox(width: 4),
                            MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: ElevatedButton(
                                onPressed: _saving ? null : _submitNew,
                                child: _saving
                                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                    : const Text('Add'),
                              ),
                            ),
                          ],
                        ),
                        if (_draftAttach.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4, left: 4),
                            child: Text(
                              '${_draftAttach.length}/$_maxFiles files',
                              style: GoogleFonts.ibmPlexSans(
                                fontSize: 11,
                                color: PrivetTheme.mist.withValues(alpha: 0.65),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),

              // ── PAYMENTS TAB ───────────────────────────────────────────────
              _PaymentWalletTab(
                state: widget.state,
                conversationId: widget.conversationId,
                active: activePayments,
                history: paymentHistory,
              ),

              // ── REMINDERS TAB ──────────────────────────────────────────────
              _ReminderKindTab(
                emptyIcon: Icons.notifications_active_outlined,
                emptyColor: PrivetTheme.signal,
                emptyTitle: 'No reminders yet',
                emptySubtitle: 'Set a date reminder for this chat.\nPin one to show it in the chat header.',
                active: activePlainReminders,
                history: reminderHistory,
                addLabel: 'Add reminder',
                onAdd: () => showReminderDialog(
                  context,
                  state: widget.state,
                  conversationId: widget.conversationId,
                  initialKind: 'reminder',
                ),
                onOpen: (r) => showReminderDialog(
                  context,
                  state: widget.state,
                  conversationId: widget.conversationId,
                  existing: r,
                ),
                onMarkDone: (r) => widget.state.markReminderPaid(r),
                onPin: (r) => widget.state.toggleReminderPin(r),
                onDelete: (r) => _confirmDeleteReminder(
                  context,
                  state: widget.state,
                  reminder: r,
                ),
              ),
            ],
          ),
        ),
      ],
      ),
      Positioned.fill(
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerSignal: _onPointerSignal,
        ),
      ),
      ],
    );
  }
}

// ─── Supporting widgets ───────────────────────────────────────────────────────

class _PaymentWalletTab extends StatelessWidget {
  const _PaymentWalletTab({
    required this.state,
    required this.conversationId,
    required this.active,
    required this.history,
  });

  final PrivetState state;
  final String conversationId;
  final List<PaymentReminder> active;
  final List<PaymentReminder> history;

  @override
  Widget build(BuildContext context) {
    final allPayments = [...active, ...history];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: Align(
            alignment: Alignment.centerRight,
            child: PaymentSpendingInsightsButton(payments: allPayments),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
            children: [
              if (active.isEmpty && history.isEmpty)
                _EmptyState(
                  icon: Icons.account_balance_wallet_outlined,
                  color: PrivetTheme.signal,
                  title: 'No payments yet',
                  subtitle: 'Add a payment, mark it paid, then log\nwhat you spent — beer, taxi, bills…',
                )
              else ...[
                if (active.isNotEmpty) ...[
                  _SectionLabel('Active — ${active.length}'),
                  const SizedBox(height: 6),
                  ...active.map((r) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _PaymentWalletCard(
                      payment: r,
                      state: state,
                      onEdit: () => showReminderDialog(
                        context,
                        state: state,
                        conversationId: conversationId,
                        existing: r,
                      ),
                      onMarkDone: () => state.markReminderPaid(r),
                      onPin: () => state.toggleReminderPin(r),
                    ),
                  )),
                ],
                if (history.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _SectionLabel('History — ${history.length}'),
                  const SizedBox(height: 6),
                  ...history.map((r) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _PaymentWalletCard(
                      payment: r,
                      state: state,
                    ),
                  )),
                ],
              ],
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: PrivetTheme.line)),
            color: PrivetTheme.panelElevated,
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: _AddReminderBtn(
                label: 'Add payment',
                icon: Icons.account_balance_wallet_rounded,
                onTap: () => showReminderDialog(
                  context,
                  state: state,
                  conversationId: conversationId,
                  initialKind: 'payment',
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PaymentWalletCard extends StatefulWidget {
  const _PaymentWalletCard({
    required this.payment,
    required this.state,
    this.onEdit,
    this.onMarkDone,
    this.onPin,
  });

  final PaymentReminder payment;
  final PrivetState state;
  final VoidCallback? onEdit;
  final VoidCallback? onMarkDone;
  final VoidCallback? onPin;

  @override
  State<_PaymentWalletCard> createState() => _PaymentWalletCardState();
}

class _PaymentWalletCardState extends State<_PaymentWalletCard> {
  late bool _expanded;
  final _labelCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  bool _adding = false;
  bool _saving = false;

  bool get _canEditWallet => widget.payment.paid;

  @override
  void initState() {
    super.initState();
    _expanded = _canEditWallet && widget.payment.expenses.isNotEmpty;
  }

  @override
  void didUpdateWidget(covariant _PaymentWalletCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.payment.id != widget.payment.id ||
        oldWidget.payment.paid != widget.payment.paid) {
      if (!oldWidget.payment.paid && widget.payment.paid) {
        _expanded = true;
      } else {
        _expanded = _canEditWallet && widget.payment.expenses.isNotEmpty;
      }
      _adding = false;
      _labelCtrl.clear();
      _amountCtrl.clear();
    }
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _amountCtrl.dispose();
    super.dispose();
  }

  Future<void> _submitExpense() async {
    final label = _labelCtrl.text.trim();
    final amountText = _amountCtrl.text.trim().replaceAll(',', '.');
    final amount = double.tryParse(amountText);
    if (label.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('What did you buy?')),
      );
      return;
    }
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid amount')),
      );
      return;
    }
    final newCents = (amount * 100).round();
    final remaining = widget.payment.remainingCents;
    if (remaining != null && newCents > remaining) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Cannot exceed ${widget.payment.formattedAmount} — only ${widget.payment.formatMoney(remaining)} left',
          ),
        ),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.state.addPaymentExpense(
        payment: widget.payment,
        label: label,
        amountCents: newCents,
      );
      if (!mounted) return;
      _labelCtrl.clear();
      _amountCtrl.clear();
      setState(() {
        _adding = false;
        _expanded = true;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deleteExpense(PaymentExpense expense) async {
    try {
      await widget.state.deletePaymentExpense(
        conversationId: widget.payment.conversationId,
        expenseId: expense.id,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _deletePayment() async {
    await _confirmDeleteReminder(context, state: widget.state, reminder: widget.payment);
  }

  @override
  Widget build(BuildContext context) {
    final payment = widget.payment;
    final overdue = payment.isOverdue;
    final paid = payment.paid;
    final accent = paid
        ? PrivetTheme.signal
        : overdue
            ? PrivetTheme.danger
            : PrivetTheme.signal;
    final remaining = payment.remainingCents;
    final spent = payment.spentCents;

    return Container(
      decoration: BoxDecoration(
        color: PrivetTheme.panelElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: paid ? PrivetTheme.line : accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    paid ? Icons.check_rounded : Icons.account_balance_wallet_rounded,
                    size: 20,
                    color: accent,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: MouseRegion(
                    cursor: widget.onEdit != null ? SystemMouseCursors.click : MouseCursor.defer,
                    child: GestureDetector(
                      onTap: widget.onEdit,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            payment.formattedAmount,
                            style: GoogleFonts.syne(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                              color: paid ? PrivetTheme.mist : PrivetTheme.paper,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            paid
                                ? 'Completed${payment.paidAt != null ? ' · ${payment.paidAt!.year}-${payment.paidAt!.month.toString().padLeft(2, '0')}-${payment.paidAt!.day.toString().padLeft(2, '0')}' : ''}'
                                : overdue
                                    ? 'Overdue — was due ${payment.dueDate}'
                                    : 'Due ${payment.dueDate}',
                            style: GoogleFonts.ibmPlexSans(fontSize: 12, color: accent),
                          ),
                          if (payment.note.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                payment.note,
                                style: GoogleFonts.ibmPlexSans(
                                  fontSize: 12,
                                  color: PrivetTheme.mist.withValues(alpha: 0.65),
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          if (paid && (spent > 0 || remaining != null))
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                spent > 0 && remaining != null && remaining >= 0
                                    ? 'Spent ${payment.formatMoney(spent)} · left ${payment.formatMoney(remaining)}'
                                    : spent > 0
                                        ? 'Spent ${payment.formatMoney(spent)}'
                                        : 'Nothing spent yet',
                                style: GoogleFonts.ibmPlexSans(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: PrivetTheme.mist.withValues(alpha: 0.75),
                                ),
                              ),
                            ),
                          if (!paid)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                'Mark paid to log spending',
                                style: GoogleFonts.ibmPlexSans(
                                  fontSize: 11,
                                  color: PrivetTheme.mist.withValues(alpha: 0.55),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (_canEditWallet)
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Tooltip(
                      message: _expanded ? 'Hide wallet' : 'Show wallet',
                      child: GestureDetector(
                        onTap: () => setState(() => _expanded = !_expanded),
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Icon(
                            _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                            size: 20,
                            color: PrivetTheme.mist,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (widget.onPin != null)
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Tooltip(
                      message: payment.pinned ? 'Unpin from header' : 'Pin to header',
                      child: GestureDetector(
                        onTap: widget.onPin,
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Icon(
                            payment.pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                            size: 16,
                            color: payment.pinned ? PrivetTheme.signal : PrivetTheme.mist,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (widget.onMarkDone != null) ...[
                  const SizedBox(width: 4),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: widget.onMarkDone,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: PrivetTheme.signal.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: PrivetTheme.signal.withValues(alpha: 0.4)),
                        ),
                        child: Text(
                          'Paid',
                          style: GoogleFonts.syne(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: PrivetTheme.signal,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 2),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Tooltip(
                    message: 'Delete payment',
                    child: GestureDetector(
                      onTap: _deletePayment,
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Icon(
                          Icons.delete_outline_rounded,
                          size: 17,
                          color: PrivetTheme.danger.withValues(alpha: 0.75),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 2),
              ],
            ),
          ),
          if (_canEditWallet && _expanded) ...[
            Divider(height: 1, color: PrivetTheme.line.withValues(alpha: 0.8)),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(Icons.receipt_long_rounded, size: 14, color: accent.withValues(alpha: 0.9)),
                      const SizedBox(width: 6),
                      Text(
                        'Wallet',
                        style: GoogleFonts.syne(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: PrivetTheme.mist,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (payment.expenses.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        'Log what this money went to — beer, chicken, bills, taxi…',
                        style: GoogleFonts.ibmPlexSans(
                          fontSize: 12,
                          color: PrivetTheme.mist.withValues(alpha: 0.55),
                        ),
                      ),
                    )
                  else
                    ...payment.expenses.map((e) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              e.label,
                              style: GoogleFonts.ibmPlexSans(
                                fontSize: 13,
                                color: PrivetTheme.paper,
                              ),
                            ),
                          ),
                          Text(
                            payment.formatMoney(e.amountCents),
                            style: GoogleFonts.syne(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: accent,
                            ),
                          ),
                          if (_canEditWallet) ...[
                            const SizedBox(width: 4),
                            MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: GestureDetector(
                                onTap: () => _deleteExpense(e),
                                child: Padding(
                                  padding: const EdgeInsets.all(4),
                                  child: Icon(
                                    Icons.close_rounded,
                                    size: 14,
                                    color: PrivetTheme.mist.withValues(alpha: 0.55),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    )),
                  if (_canEditWallet && (remaining == null || remaining > 0 || _adding)) ...[
                    if (_adding) ...[
                      const SizedBox(height: 4),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 3,
                            child: TextField(
                              controller: _labelCtrl,
                              style: GoogleFonts.ibmPlexSans(color: PrivetTheme.paper, fontSize: 13),
                              cursorColor: PrivetTheme.signal,
                              decoration: InputDecoration(
                                hintText: 'Beer, taxi, bread…',
                                hintStyle: GoogleFonts.ibmPlexSans(
                                  color: PrivetTheme.mist.withValues(alpha: 0.4),
                                  fontSize: 13,
                                ),
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                                filled: true,
                                fillColor: PrivetTheme.ink.withValues(alpha: 0.35),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  borderSide: BorderSide(color: PrivetTheme.line),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  borderSide: BorderSide(color: PrivetTheme.line),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  borderSide: BorderSide(color: accent.withValues(alpha: 0.7)),
                                ),
                              ),
                              onSubmitted: (_) => _submitExpense(),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 2,
                            child: TextField(
                              controller: _amountCtrl,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.,]'))],
                              style: GoogleFonts.syne(color: PrivetTheme.paper, fontSize: 13),
                              cursorColor: PrivetTheme.signal,
                              decoration: InputDecoration(
                                hintText: payment.currencySymbol,
                                hintStyle: GoogleFonts.syne(
                                  color: PrivetTheme.mist.withValues(alpha: 0.4),
                                  fontSize: 13,
                                ),
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                                filled: true,
                                fillColor: PrivetTheme.ink.withValues(alpha: 0.35),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  borderSide: BorderSide(color: PrivetTheme.line),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  borderSide: BorderSide(color: PrivetTheme.line),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  borderSide: BorderSide(color: accent.withValues(alpha: 0.7)),
                                ),
                              ),
                              onSubmitted: (_) => _submitExpense(),
                            ),
                          ),
                          const SizedBox(width: 6),
                          MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: IconButton(
                              onPressed: _saving ? null : _submitExpense,
                              icon: _saving
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  : Icon(Icons.check_rounded, color: accent, size: 20),
                              tooltip: 'Add',
                            ),
                          ),
                          MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: IconButton(
                              onPressed: _saving
                                  ? null
                                  : () => setState(() {
                                        _adding = false;
                                        _labelCtrl.clear();
                                        _amountCtrl.clear();
                                      }),
                              icon: Icon(
                                Icons.close_rounded,
                                color: PrivetTheme.mist.withValues(alpha: 0.6),
                                size: 18,
                              ),
                              tooltip: 'Cancel',
                            ),
                          ),
                        ],
                      ),
                    ] else if (remaining != null && remaining <= 0)
                      Text(
                        'Fully spent — no budget left',
                        style: GoogleFonts.ibmPlexSans(
                          fontSize: 12,
                          color: PrivetTheme.mist.withValues(alpha: 0.55),
                        ),
                      )
                    else
                      Align(
                        alignment: Alignment.centerLeft,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: TextButton.icon(
                            onPressed: () => setState(() => _adding = true),
                            icon: Icon(Icons.add_rounded, size: 16, color: accent),
                            label: Text(
                              'Add purchase',
                              style: GoogleFonts.syne(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: accent,
                              ),
                            ),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ReminderKindTab extends StatelessWidget {
  const _ReminderKindTab({
    required this.emptyIcon,
    required this.emptyColor,
    required this.emptyTitle,
    required this.emptySubtitle,
    required this.active,
    required this.history,
    required this.addLabel,
    required this.onAdd,
    required this.onOpen,
    required this.onMarkDone,
    required this.onPin,
    required this.onDelete,
  });

  final IconData emptyIcon;
  final Color emptyColor;
  final String emptyTitle;
  final String emptySubtitle;
  final List<PaymentReminder> active;
  final List<PaymentReminder> history;
  final String addLabel;
  final VoidCallback onAdd;
  final void Function(PaymentReminder) onOpen;
  final void Function(PaymentReminder) onMarkDone;
  final void Function(PaymentReminder) onPin;
  final void Function(PaymentReminder) onDelete;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
            children: [
              if (active.isEmpty && history.isEmpty)
                _EmptyState(
                  icon: emptyIcon,
                  color: emptyColor,
                  title: emptyTitle,
                  subtitle: emptySubtitle,
                )
              else ...[
                if (active.isNotEmpty) ...[
                  _SectionLabel('Active — ${active.length}'),
                  const SizedBox(height: 6),
                  ...active.map((r) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _ReminderRow(
                      reminder: r,
                      onTap: () => onOpen(r),
                      onMarkDone: () => onMarkDone(r),
                      onPin: () => onPin(r),
                      onDelete: () => onDelete(r),
                    ),
                  )),
                ],
                if (history.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _SectionLabel('History — ${history.length}'),
                  const SizedBox(height: 6),
                  ...history.map((r) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _ReminderRow(
                      reminder: r,
                      onTap: null,
                      onMarkDone: null,
                      onPin: null,
                      onDelete: () => onDelete(r),
                    ),
                  )),
                ],
              ],
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: PrivetTheme.line)),
            color: PrivetTheme.panelElevated,
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: _AddReminderBtn(
                label: addLabel,
                icon: Icons.notifications_active_outlined,
                onTap: onAdd,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge(this.count, {required this.color});
  final int count;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(color: color.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(99), border: Border.all(color: color.withValues(alpha: 0.4))),
    child: Text('$count', style: GoogleFonts.syne(fontSize: 10, fontWeight: FontWeight.w700, color: color)),
  );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 2, bottom: 2),
    child: Text(text, style: GoogleFonts.ibmPlexSans(fontSize: 11, fontWeight: FontWeight.w600, color: PrivetTheme.mist.withValues(alpha: 0.6), letterSpacing: 0.4)),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.color, required this.title, required this.subtitle});
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 52, color: color.withValues(alpha: 0.8)),
      const SizedBox(height: 14),
      Text(title, style: GoogleFonts.syne(fontWeight: FontWeight.w700, fontSize: 20, color: color)),
      const SizedBox(height: 8),
      Text(subtitle, textAlign: TextAlign.center, style: GoogleFonts.ibmPlexSans(fontSize: 13, color: PrivetTheme.mist)),
    ]),
  );
}

class _TaskProgressBar extends StatelessWidget {
  const _TaskProgressBar({required this.board});
  final ConversationTasks board;
  @override
  Widget build(BuildContext context) {
    final done = board.isComplete;
    final fill = done ? PrivetTheme.signal : PrivetTheme.signalDim;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Text(done ? 'Complete' : 'Progress', style: GoogleFonts.ibmPlexSans(fontSize: 12, fontWeight: FontWeight.w600, color: PrivetTheme.mist)),
        const Spacer(),
        Text('${board.doneCount} / ${board.total}', style: GoogleFonts.syne(fontSize: 13, fontWeight: FontWeight.w700, color: done ? PrivetTheme.signal : PrivetTheme.paper)),
      ]),
      const SizedBox(height: 6),
      ClipRRect(
        borderRadius: BorderRadius.circular(99),
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: board.progress),
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          builder: (_, v, __) => LinearProgressIndicator(value: v.clamp(0.0, 1.0), minHeight: 8, backgroundColor: fill.withValues(alpha: 0.16), color: fill),
        ),
      ),
    ]);
  }
}

/// Explicit edit dialog for a task's text (Save on the button or Enter).
Future<void> _promptEditTaskText(
  BuildContext context, {
  required String title,
  required String initial,
  required ValueChanged<String> onSave,
}) async {
  final ctrl = TextEditingController(text: initial);
  final saved = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: PrivetTheme.panelElevated,
      title: Text(
        title,
        style: GoogleFonts.syne(
          color: PrivetTheme.mist,
          fontWeight: FontWeight.w700,
        ),
      ),
      content: SizedBox(
        width: 340,
        child: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 3,
          style: GoogleFonts.ibmPlexSans(
            color: PrivetTheme.paper,
            fontSize: 14,
          ),
          cursorColor: PrivetTheme.signal,
          decoration: const InputDecoration(
            hintText: 'Task text',
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
          onSubmitted: (_) => Navigator.of(ctx).pop(true),
        ),
      ),
      actions: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'Cancel',
              style: TextStyle(color: PrivetTheme.mist),
            ),
          ),
        ),
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: FilledButton(
            style: FilledButton.styleFrom(backgroundColor: PrivetTheme.signal),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              'Save',
              style: TextStyle(color: PrivetTheme.onAccent),
            ),
          ),
        ),
      ],
    ),
  );
  final value = ctrl.text.trim();
  ctrl.dispose();
  if (saved == true && value.isNotEmpty) onSave(value);
}

class _TaskRow extends StatefulWidget {
  const _TaskRow({
    required this.number,
    required this.item,
    required this.taskFontSize,
    required this.mediaBase,
    required this.myUserId,
    required this.subtasks,
    required this.progressLabel,
    required this.onToggle,
    required this.onConfirmDone,
    required this.onSaveBody,
    required this.onDelete,
    required this.onRemoveAttachment,
    required this.onAttach,
    required this.onPin,
    required this.onAddSubtask,
    required this.onToggleSubtask,
    required this.onConfirmSubtask,
    required this.onSaveSubtaskBody,
    required this.onDeleteSubtask,
    required this.onAttachSubtask,
    required this.onRemoveSubtaskAttachment,
  });

  final int number;
  final TaskItem item;

  /// Task text size (logical px), from [PrivetState.taskFontSize]. Independent
  /// of the chat font size so task text can be zoomed on its own.
  final double taskFontSize;
  final String mediaBase;
  final String? myUserId;
  final List<TaskItem> subtasks;
  final String? progressLabel;
  final VoidCallback? onToggle;
  final VoidCallback? onConfirmDone;
  final ValueChanged<String>? onSaveBody;
  final VoidCallback? onDelete;
  final ValueChanged<String>? onRemoveAttachment;
  final VoidCallback? onAttach;
  final VoidCallback? onPin;
  final Future<void> Function(String body)? onAddSubtask;
  final ValueChanged<TaskItem>? onToggleSubtask;
  /// Returns the confirm handler for a subtask, or null when it can't be approved.
  final VoidCallback? Function(TaskItem item)? onConfirmSubtask;
  final void Function(TaskItem item, String body)? onSaveSubtaskBody;
  final ValueChanged<TaskItem>? onDeleteSubtask;
  final ValueChanged<TaskItem>? onAttachSubtask;
  final void Function(TaskItem item, String url)? onRemoveSubtaskAttachment;

  @override
  State<_TaskRow> createState() => _TaskRowState();
}

class _TaskRowState extends State<_TaskRow> {
  late final TextEditingController _ctrl;
  late final FocusNode _focus;
  final _subCtrl = TextEditingController();
  final _subFocus = FocusNode();
  bool _addingSub = false;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.item.body);
    _focus = FocusNode();
    _focus.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(covariant _TaskRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.body != widget.item.body && !_focus.hasFocus) {
      _ctrl.text = widget.item.body;
    }
  }

  void _onFocus() {
    if (!_focus.hasFocus && widget.onSaveBody != null) {
      final next = _ctrl.text.trim();
      if (next.isNotEmpty && next != widget.item.body) {
        widget.onSaveBody!(next);
      } else if (next.isEmpty) {
        _ctrl.text = widget.item.body;
      }
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _ctrl.dispose();
    _focus.dispose();
    _subCtrl.dispose();
    _subFocus.dispose();
    super.dispose();
  }

  String _abs(String? path) {
    if (path == null || path.isEmpty) return '';
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    return '${widget.mediaBase}$path';
  }

  bool _isImageAtt(MediaAttachment a) {
    if (a.mimeType != null && a.mimeType!.startsWith('image/')) return true;
    final name = (a.fileName ?? a.mediaUrl).toLowerCase();
    return name.endsWith('.png') ||
        name.endsWith('.jpg') ||
        name.endsWith('.jpeg') ||
        name.endsWith('.gif') ||
        name.endsWith('.webp');
  }

  void _openPreview(MediaAttachment att) {
    final url = _abs(att.mediaUrl);
    if (url.isEmpty || !_isImageAtt(att)) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: PrivetTheme.ink,
        insetPadding: const EdgeInsets.all(24),
        child: Stack(children: [
          InteractiveViewer(child: Image.network(url, fit: BoxFit.contain)),
          Positioned(
            top: 8,
            right: 8,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: IconButton(
                onPressed: () => Navigator.pop(ctx),
                icon: const Icon(Icons.close_rounded),
              ),
            ),
          ),
          Positioned(top: 12, left: 12, child: _NumberBadge(number: widget.number, large: true)),
        ]),
      ),
    );
  }

  Future<void> _submitSubtask() async {
    final text = _subCtrl.text.trim();
    if (text.isEmpty || widget.onAddSubtask == null) return;
    await widget.onAddSubtask!(text);
    if (!mounted) return;
    _subCtrl.clear();
    setState(() => _addingSub = false);
  }

  void _openEditDialog() {
    _promptEditTaskText(
      context,
      title: 'Edit task',
      initial: _ctrl.text,
      onSave: (next) {
        widget.onSaveBody?.call(next);
        _ctrl.text = next;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final isHistory = widget.onToggle == null;
    final awaitingApproval = item.done && !item.doneConfirmed;
    final media = item.mediaItems;

    return AnimatedOpacity(
      opacity: isHistory ? 0.65 : 1.0,
      duration: const Duration(milliseconds: 200),
      child: Material(
        color: awaitingApproval
            ? const Color(0xFFF0A83D).withValues(alpha: 0.09)
            : isHistory
                ? PrivetTheme.panelElevated.withValues(alpha: 0.6)
                : PrivetTheme.panelElevated,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 6, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _NumberBadge(number: widget.number),
                  const SizedBox(width: 8),
                  if (widget.onToggle != null)
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: Tooltip(
                        message: item.doneConfirmed
                            ? 'Done'
                            : (item.done
                                ? 'Done — awaiting approval · tap to reopen'
                                : 'Mark done'),
                        child: GestureDetector(
                          onTap: widget.onToggle,
                          child: Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Icon(
                              item.done
                                  ? Icons.check_box_rounded
                                  : Icons.check_box_outline_blank_rounded,
                              color: item.doneConfirmed
                                  ? PrivetTheme.signal
                                  : (item.done
                                      ? const Color(0xFFF0A83D)
                                      : PrivetTheme.mist),
                              size: 22,
                            ),
                          ),
                        ),
                      ),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(
                        Icons.check_box_rounded,
                        color: PrivetTheme.signal.withValues(alpha: 0.5),
                        size: 22,
                      ),
                    ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: widget.onSaveBody != null
                                  ? TextField(
                                      controller: _ctrl,
                                      focusNode: _focus,
                                      maxLines: null,
                                      style: GoogleFonts.ibmPlexSans(
                                        fontSize: widget.taskFontSize,
                                        color: PrivetTheme.paper,
                                      ),
                                      decoration: const InputDecoration(
                                        isDense: true,
                                        border: InputBorder.none,
                                        enabledBorder: InputBorder.none,
                                        focusedBorder: InputBorder.none,
                                        filled: false,
                                        contentPadding:
                                            EdgeInsets.symmetric(vertical: 4),
                                      ),
                                    )
                                  : Text(
                                      item.body,
                                      style: GoogleFonts.ibmPlexSans(
                                        fontSize: widget.taskFontSize,
                                        color: PrivetTheme.paper,
                                      ),
                                    ),
                            ),
                            if (widget.progressLabel != null)
                              Padding(
                                padding: const EdgeInsets.only(left: 6),
                                child: Text(
                                  widget.progressLabel!,
                                  style: GoogleFonts.syne(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: PrivetTheme.signal,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(text: 'Created ${_fmtTaskDate(item.createdAt)}'),
                                if (item.createdBy != null) ...[
                                  const TextSpan(text: ' · '),
                                  TextSpan(
                                    text: 'by ${item.createdBy!.displayName}',
                                  ),
                                ],
                                if (item.assignedTo != null) ...[
                                  const TextSpan(text: ' → '),
                                  TextSpan(
                                    text: item.assignedTo!.displayName,
                                  ),
                                ],
                                if (item.done && !item.doneConfirmed)
                                  TextSpan(
                                    text: ' · awaiting approval',
                                    style: GoogleFonts.ibmPlexSans(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: const Color(0xFFF0A83D),
                                    ),
                                  ),
                                if (item.doneConfirmed)
                                  TextSpan(
                                    text: ' · Done',
                                    style: GoogleFonts.ibmPlexSans(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: PrivetTheme.signal,
                                    ),
                                  ),
                              ],
                            ),
                            style: GoogleFonts.ibmPlexSans(
                              fontSize: 11,
                              color: PrivetTheme.mist.withValues(alpha: 0.55),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  _TaskRowActions(
                    onAttach: !isHistory ? widget.onAttach : null,
                    attachDisabled: media.length >= 10,
                    pinned: item.pinned,
                    onPin: widget.onPin,
                    onEdit: widget.onSaveBody != null ? _openEditDialog : null,
                    onDelete: widget.onDelete,
                    onConfirmDone: widget.onConfirmDone,
                    history: isHistory,
                  ),
                ],
              ),
              if (media.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 38, top: 8),
                  child: SizedBox(
                    height: 52,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: media.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 6),
                      itemBuilder: (context, i) {
                        final att = media[i];
                        final url = _abs(att.mediaUrl);
                        return Stack(
                          clipBehavior: Clip.none,
                          children: [
                            MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: GestureDetector(
                                onTap: () => _openPreview(att),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: _isImageAtt(att)
                                      ? Image.network(
                                          url,
                                          width: 52,
                                          height: 52,
                                          fit: BoxFit.cover,
                                          cacheWidth: ImageDecodeCaps.cacheWidth(
                                            52,
                                            dpr: MediaQuery.devicePixelRatioOf(
                                                context),
                                          ),
                                          cacheHeight:
                                              ImageDecodeCaps.cacheHeight(
                                            52,
                                            dpr: MediaQuery.devicePixelRatioOf(
                                                context),
                                          ),
                                          errorBuilder: (_, __, ___) =>
                                              _fileThumb(att.fileName),
                                        )
                                      : _fileThumb(att.fileName),
                                ),
                              ),
                            ),
                            if (!isHistory &&
                                widget.onRemoveAttachment != null)
                              Positioned(
                                top: -6,
                                right: -6,
                                child: MouseRegion(
                                  cursor: SystemMouseCursors.click,
                                  child: Material(
                                    color: PrivetTheme.panel,
                                    shape: const CircleBorder(),
                                    child: InkWell(
                                      customBorder: const CircleBorder(),
                                      onTap: () => widget
                                          .onRemoveAttachment!(att.mediaUrl),
                                      child: const Padding(
                                        padding: EdgeInsets.all(2),
                                        child:
                                            Icon(Icons.close_rounded, size: 14),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              // Subtasks
              if (widget.subtasks.isNotEmpty ||
                  (!isHistory && widget.onAddSubtask != null))
                Padding(
                  padding: const EdgeInsets.only(left: 30, top: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final sub in widget.subtasks)
                        _SubtaskRow(
                          item: sub,
                          taskFontSize: widget.taskFontSize,
                          mediaBase: widget.mediaBase,
                          editable: !isHistory,
                          onPreview: _openPreview,
                          onToggle: widget.onToggleSubtask == null
                              ? null
                              : () => widget.onToggleSubtask!(sub),
                          onConfirm: widget.onConfirmSubtask == null
                              ? null
                              : widget.onConfirmSubtask!(sub),
                          onSaveBody: widget.onSaveSubtaskBody == null
                              ? null
                              : (body) =>
                                  widget.onSaveSubtaskBody!(sub, body),
                          onDelete: widget.onDeleteSubtask == null
                              ? null
                              : () => widget.onDeleteSubtask!(sub),
                          onAttach: widget.onAttachSubtask == null
                              ? null
                              : () => widget.onAttachSubtask!(sub),
                          onRemoveAttachment: widget.onRemoveSubtaskAttachment == null
                              ? null
                              : (url) =>
                                  widget.onRemoveSubtaskAttachment!(sub, url),
                        ),
                      if (!isHistory && widget.onAddSubtask != null)
                        _addingSub
                            ? Row(
                                children: [
                                  Icon(
                                    Icons.subdirectory_arrow_right_rounded,
                                    size: 16,
                                    color: PrivetTheme.mist
                                        .withValues(alpha: 0.7),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: TextField(
                                      controller: _subCtrl,
                                      focusNode: _subFocus,
                                      autofocus: true,
                                      textInputAction: TextInputAction.done,
                                      onSubmitted: (_) => _submitSubtask(),
                                      style: GoogleFonts.ibmPlexSans(
                                          fontSize: 13),
                                      decoration: const InputDecoration(
                                        hintText: 'Add subtask…',
                                        isDense: true,
                                        contentPadding: EdgeInsets.symmetric(
                                            horizontal: 10, vertical: 8),
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    onPressed: _submitSubtask,
                                    icon: const Icon(Icons.check_rounded,
                                        size: 18),
                                    color: PrivetTheme.signal,
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  IconButton(
                                    onPressed: () => setState(() {
                                      _addingSub = false;
                                      _subCtrl.clear();
                                    }),
                                    icon: const Icon(Icons.close_rounded,
                                        size: 18),
                                    color: PrivetTheme.mist,
                                    visualDensity: VisualDensity.compact,
                                  ),
                                ],
                              )
                            : Align(
                                alignment: Alignment.centerLeft,
                                child: MouseRegion(
                                  cursor: SystemMouseCursors.click,
                                  child: TextButton.icon(
                                    onPressed: () {
                                      setState(() => _addingSub = true);
                                      WidgetsBinding.instance
                                          .addPostFrameCallback((_) {
                                        _subFocus.requestFocus();
                                      });
                                    },
                                    icon: const Icon(Icons.add_rounded,
                                        size: 16),
                                    label: Text(
                                      'Add subtask',
                                      style: GoogleFonts.syne(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    style: TextButton.styleFrom(
                                      foregroundColor: PrivetTheme.mist,
                                      visualDensity: VisualDensity.compact,
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8),
                                    ),
                                  ),
                                ),
                              ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fileThumb(String? name) => Container(
        width: 52,
        height: 52,
        color: PrivetTheme.ink,
        alignment: Alignment.center,
        child: Text(
          (name != null && name.isNotEmpty) ? name[0].toUpperCase() : 'F',
          style: GoogleFonts.syne(fontWeight: FontWeight.w700),
        ),
      );
}

/// Trailing actions for a task row. Desktop shows them inline; mobile
/// (compact) collapses them behind one overflow menu so long task text keeps
/// the full row width instead of wrapping at a few px per line.
class _TaskRowActions extends StatelessWidget {
  const _TaskRowActions({
    required this.onAttach,
    required this.attachDisabled,
    required this.pinned,
    required this.onPin,
    required this.onEdit,
    required this.onDelete,
    required this.onConfirmDone,
    required this.history,
  });

  final VoidCallback? onAttach;
  final bool attachDisabled;
  final bool pinned;
  final VoidCallback? onPin;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onConfirmDone;
  final bool history;

  @override
  Widget build(BuildContext context) {
    if (PrivetTheme.isCompact(context)) {
      if (onAttach == null &&
          onPin == null &&
          onEdit == null &&
          onDelete == null &&
          onConfirmDone == null) {
        return const SizedBox.shrink();
      }
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        child: IconButton(
          tooltip: 'More',
          onPressed: () => _showMenu(context),
          icon: const Icon(Icons.more_horiz_rounded, size: 20),
          color: PrivetTheme.mist,
          visualDensity: VisualDensity.compact,
        ),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (onAttach != null)
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: IconButton(
              tooltip:
                  attachDisabled ? 'Max 10 files' : 'Attach files (up to 10)',
              onPressed: attachDisabled ? null : onAttach,
              icon: const Icon(Icons.attach_file_rounded, size: 20),
              color: PrivetTheme.mist,
              visualDensity: VisualDensity.compact,
            ),
          ),
        if (onPin != null)
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: IconButton(
              tooltip: pinned ? 'Unpin from header' : 'Pin to header',
              onPressed: onPin,
              icon: Icon(
                pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                size: 18,
                color: pinned ? PrivetTheme.signal : PrivetTheme.mist,
              ),
              visualDensity: VisualDensity.compact,
            ),
          ),
        if (onEdit != null)
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: IconButton(
              tooltip: 'Edit text',
              onPressed: onEdit,
              icon: const Icon(Icons.edit_outlined, size: 18),
              color: PrivetTheme.mist,
              visualDensity: VisualDensity.compact,
            ),
          ),
        if (onDelete != null)
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: IconButton(
              tooltip: history ? 'Remove from history' : 'Remove',
              onPressed: onDelete,
              icon: const Icon(Icons.close_rounded, size: 18),
              color: PrivetTheme.mist,
              visualDensity: VisualDensity.compact,
            ),
          ),
        if (onConfirmDone != null)
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Tooltip(
              message: 'Approve — mark done and move to history',
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: onConfirmDone,
                mouseCursor: SystemMouseCursors.click,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: PrivetTheme.signal.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: PrivetTheme.signal.withValues(alpha: 0.5),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.done_all_rounded,
                          size: 14,
                          color: PrivetTheme.signal,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Approve',
                          style: GoogleFonts.syne(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: PrivetTheme.signal,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _showMenu(BuildContext context) {
    final tiles = <Widget>[];
    void addTile({
      required IconData icon,
      required String label,
      VoidCallback? onTap,
      bool disabled = false,
      Color? color,
      bool prominent = false,
    }) {
      tiles.add(
        ListTile(
          enabled: !disabled && onTap != null,
          leading: Icon(
            icon,
            color: color ?? (prominent ? PrivetTheme.signal : null),
          ),
          title: Text(
            label,
            style: prominent
                ? GoogleFonts.syne(
                    fontWeight: FontWeight.w700,
                    color: PrivetTheme.signal,
                  )
                : null,
          ),
          onTap: (disabled || onTap == null)
              ? null
              : () {
                  Navigator.pop(context);
                  onTap!();
                },
        ),
      );
    }

    if (onAttach != null) {
      addTile(
        icon: Icons.attach_file_rounded,
        label: attachDisabled ? 'Max 10 files' : 'Attach files',
        onTap: onAttach,
        disabled: attachDisabled,
      );
    }
    if (onPin != null) {
      addTile(
        icon: pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
        label: pinned ? 'Unpin from header' : 'Pin to header',
        onTap: onPin,
      );
    }
    if (onEdit != null) {
      addTile(icon: Icons.edit_outlined, label: 'Edit text', onTap: onEdit);
    }
    if (onConfirmDone != null) {
      addTile(
        icon: Icons.done_all_rounded,
        label: 'Approve — move to history',
        onTap: onConfirmDone,
        prominent: true,
      );
    }
    if (onDelete != null) {
      addTile(
        icon: Icons.close_rounded,
        label: history ? 'Remove from history' : 'Remove',
        onTap: onDelete,
        color: PrivetTheme.danger,
      );
    }
    if (tiles.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: PrivetTheme.panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: tiles),
      ),
    );
  }
}

class _SubtaskRow extends StatefulWidget {
  const _SubtaskRow({
    required this.item,
    required this.taskFontSize,
    required this.mediaBase,
    required this.editable,
    required this.onToggle,
    required this.onConfirm,
    required this.onSaveBody,
    required this.onDelete,
    required this.onAttach,
    required this.onRemoveAttachment,
    this.onPreview,
  });

  final TaskItem item;
  final double taskFontSize;
  final String mediaBase;
  final bool editable;
  final VoidCallback? onToggle;
  final VoidCallback? onConfirm;
  final ValueChanged<String>? onSaveBody;
  final VoidCallback? onDelete;
  final VoidCallback? onAttach;
  final ValueChanged<String>? onRemoveAttachment;
  final void Function(MediaAttachment att)? onPreview;

  @override
  State<_SubtaskRow> createState() => _SubtaskRowState();
}

class _SubtaskRowState extends State<_SubtaskRow> {
  late final TextEditingController _ctrl;
  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.item.body);
    _focus = FocusNode()..addListener(_onFocus);
  }

  @override
  void didUpdateWidget(covariant _SubtaskRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.body != widget.item.body && !_focus.hasFocus) {
      _ctrl.text = widget.item.body;
    }
  }

  void _onFocus() {
    if (!_focus.hasFocus && widget.onSaveBody != null) {
      final next = _ctrl.text.trim();
      if (next.isNotEmpty && next != widget.item.body) {
        widget.onSaveBody!(next);
      } else if (next.isEmpty) {
        _ctrl.text = widget.item.body;
      }
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  String _abs(String? path) {
    if (path == null || path.isEmpty) return '';
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    return '${widget.mediaBase}$path';
  }

  bool _isImageAtt(MediaAttachment a) {
    if (a.mimeType != null && a.mimeType!.startsWith('image/')) return true;
    final name = (a.fileName ?? a.mediaUrl).toLowerCase();
    return name.endsWith('.png') ||
        name.endsWith('.jpg') ||
        name.endsWith('.jpeg') ||
        name.endsWith('.gif') ||
        name.endsWith('.webp');
  }

  void _openEditDialog() {
    _promptEditTaskText(
      context,
      title: 'Edit subtask',
      initial: _ctrl.text,
      onSave: (next) {
        widget.onSaveBody?.call(next);
        _ctrl.text = next;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final media = item.mediaItems;
    // Subtasks stay one step smaller than the parent task but zoom together.
    final double subFontSize = math.max(11.0, widget.taskFontSize - 1.0);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.subdirectory_arrow_right_rounded,
                size: 16,
                color: PrivetTheme.mist.withValues(alpha: 0.55),
              ),
              const SizedBox(width: 4),
              if (widget.onToggle != null)
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: widget.onToggle,
                    child: Icon(
                      item.done
                          ? Icons.check_box_rounded
                          : Icons.check_box_outline_blank_rounded,
                      size: 18,
                      color: item.doneConfirmed
                          ? PrivetTheme.signal
                          : (item.done
                              ? const Color(0xFFF0A83D)
                              : PrivetTheme.mist),
                    ),
                  ),
                )
              else
                Icon(
                  Icons.check_box_rounded,
                  size: 18,
                  color: PrivetTheme.signal.withValues(alpha: 0.45),
                ),
              const SizedBox(width: 6),
              Expanded(
                child: widget.editable && widget.onSaveBody != null
                    ? TextField(
                        controller: _ctrl,
                        focusNode: _focus,
                        maxLines: null,
                        style: GoogleFonts.ibmPlexSans(
                          fontSize: subFontSize,
                          color: PrivetTheme.paper,
                        ),
                        decoration: const InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: false,
                          contentPadding: EdgeInsets.symmetric(vertical: 2),
                        ),
                      )
                    : Text(
                        item.body,
                        style: GoogleFonts.ibmPlexSans(
                          fontSize: subFontSize,
                          color: PrivetTheme.paper,
                        ),
                      ),
              ),
              _SubtaskActions(
                editable: widget.editable,
                onAttach: widget.onAttach,
                attachDisabled: media.length >= 10,
                onEdit:
                    widget.editable && widget.onSaveBody != null
                        ? _openEditDialog
                        : null,
                onDelete: widget.onDelete,
                onConfirm: widget.editable ? widget.onConfirm : null,
              ),
            ],
          ),
          if (media.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 28, top: 4),
              child: SizedBox(
                height: 44,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: media.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 6),
                  itemBuilder: (context, i) {
                    final att = media[i];
                    final url = _abs(att.mediaUrl);
                    final clickable = _isImageAtt(att) && widget.onPreview != null;
                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        MouseRegion(
                          cursor: clickable
                              ? SystemMouseCursors.click
                              : MouseCursor.defer,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: clickable
                                ? () => widget.onPreview!(att)
                                : null,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: _isImageAtt(att)
                                  ? Image.network(
                                      url,
                                      width: 44,
                                      height: 44,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => _fileThumb(att.fileName),
                                    )
                                  : _fileThumb(att.fileName),
                            ),
                          ),
                        ),
                        if (widget.editable && widget.onRemoveAttachment != null)
                          Positioned(
                            top: -5,
                            right: -5,
                            child: MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: Material(
                                color: PrivetTheme.panel,
                                shape: const CircleBorder(),
                                child: InkWell(
                                  customBorder: const CircleBorder(),
                                  onTap: () =>
                                      widget.onRemoveAttachment!(att.mediaUrl),
                                  child: const Padding(
                                    padding: EdgeInsets.all(2),
                                    child: Icon(Icons.close_rounded, size: 12),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _fileThumb(String? name) => Container(
        width: 44,
        height: 44,
        color: PrivetTheme.ink,
        alignment: Alignment.center,
        child: Text(
          (name != null && name.isNotEmpty) ? name[0].toUpperCase() : 'F',
          style: GoogleFonts.syne(fontWeight: FontWeight.w700, fontSize: 12),
        ),
      );
}

/// Trailing actions for a subtask row. Desktop shows them inline; mobile
/// (compact) collapses them behind one overflow menu so the subtask text keeps
/// the full row width.
class _SubtaskActions extends StatelessWidget {
  const _SubtaskActions({
    required this.editable,
    required this.onAttach,
    required this.attachDisabled,
    required this.onEdit,
    required this.onDelete,
    required this.onConfirm,
  });

  final bool editable;
  final VoidCallback? onAttach;
  final bool attachDisabled;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onConfirm;

  bool get _hasAny =>
      (editable &&
          (onAttach != null || onEdit != null || onConfirm != null)) ||
      onDelete != null;

  @override
  Widget build(BuildContext context) {
    if (!_hasAny) return const SizedBox.shrink();
    if (PrivetTheme.isCompact(context)) {
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        child: IconButton(
          tooltip: 'More',
          onPressed: () => _showMenu(context),
          icon: const Icon(Icons.more_horiz_rounded, size: 18),
          color: PrivetTheme.mist,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          padding: EdgeInsets.zero,
        ),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (editable && onAttach != null)
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: IconButton(
              tooltip: attachDisabled ? 'Max 10 files' : 'Attach file',
              onPressed: attachDisabled ? null : onAttach,
              icon: const Icon(Icons.attach_file_rounded, size: 16),
              color: PrivetTheme.mist,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              padding: EdgeInsets.zero,
            ),
          ),
        if (editable && onEdit != null)
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: IconButton(
              tooltip: 'Edit text',
              onPressed: onEdit,
              icon: const Icon(Icons.edit_outlined, size: 16),
              color: PrivetTheme.mist,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              padding: EdgeInsets.zero,
            ),
          ),
        if (onDelete != null)
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: IconButton(
              onPressed: onDelete,
              icon: const Icon(Icons.close_rounded, size: 14),
              color: PrivetTheme.mist.withValues(alpha: 0.7),
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              padding: EdgeInsets.zero,
            ),
          ),
        if (editable && onConfirm != null)
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Tooltip(
              message: 'Approve subtask',
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: onConfirm,
                mouseCursor: SystemMouseCursors.click,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: PrivetTheme.signal.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: PrivetTheme.signal.withValues(alpha: 0.5),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.done_all_rounded,
                          size: 12,
                          color: PrivetTheme.signal,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          'Approve',
                          style: GoogleFonts.syne(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: PrivetTheme.signal,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _showMenu(BuildContext context) {
    final tiles = <Widget>[];
    void addTile({
      required IconData icon,
      required String label,
      VoidCallback? onTap,
      bool disabled = false,
      Color? color,
      bool prominent = false,
    }) {
      tiles.add(
        ListTile(
          enabled: !disabled && onTap != null,
          leading: Icon(
            icon,
            color: color ?? (prominent ? PrivetTheme.signal : null),
          ),
          title: Text(
            label,
            style: prominent
                ? GoogleFonts.syne(
                    fontWeight: FontWeight.w700,
                    color: PrivetTheme.signal,
                  )
                : null,
          ),
          onTap: (disabled || onTap == null)
              ? null
              : () {
                  Navigator.pop(context);
                  onTap!();
                },
        ),
      );
    }

    if (editable && onAttach != null) {
      addTile(
        icon: Icons.attach_file_rounded,
        label: attachDisabled ? 'Max 10 files' : 'Attach file',
        onTap: onAttach,
        disabled: attachDisabled,
      );
    }
    if (editable && onEdit != null) {
      addTile(icon: Icons.edit_outlined, label: 'Edit text', onTap: onEdit);
    }
    if (editable && onConfirm != null) {
      addTile(
        icon: Icons.done_all_rounded,
        label: 'Approve subtask',
        onTap: onConfirm,
        prominent: true,
      );
    }
    if (onDelete != null) {
      addTile(
        icon: Icons.close_rounded,
        label: 'Remove',
        onTap: onDelete,
        color: PrivetTheme.danger,
      );
    }
    if (tiles.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: PrivetTheme.panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: tiles),
      ),
    );
  }
}

class _ReminderRow extends StatelessWidget {
  const _ReminderRow({
    required this.reminder,
    required this.onTap,
    required this.onMarkDone,
    required this.onPin,
    this.onDelete,
  });
  final PaymentReminder reminder;
  final VoidCallback? onTap;
  final VoidCallback? onMarkDone;
  final VoidCallback? onPin;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final overdue = reminder.isOverdue;
    final paid = reminder.paid;
    final isPayment = reminder.isPayment;

    final Color accent = paid
        ? PrivetTheme.signal
        : overdue
            ? PrivetTheme.danger
            : isPayment
                ? PrivetTheme.signal
                : PrivetTheme.signalDim;

    final IconData icon = paid
        ? Icons.check_circle_rounded
        : isPayment
            ? Icons.account_balance_wallet_rounded
            : Icons.notifications_active_outlined;
    final String title = _buildTitle();
    final String sub = _buildSub();

    return MouseRegion(
      cursor: onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: PrivetTheme.panelElevated,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: paid ? PrivetTheme.line : accent.withValues(alpha: 0.35)),
          ),
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(color: accent.withValues(alpha: 0.12), shape: BoxShape.circle),
                alignment: Alignment.center,
                child: Icon(icon, size: 18, color: accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: GoogleFonts.syne(fontWeight: FontWeight.w700, fontSize: 14, color: paid ? PrivetTheme.mist : PrivetTheme.paper, decoration: isPayment ? null : (paid ? TextDecoration.lineThrough : null))),
                    const SizedBox(height: 2),
                    Text(sub, style: GoogleFonts.ibmPlexSans(fontSize: 12, color: accent)),
                    if (reminder.note.isNotEmpty && isPayment)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(reminder.note, style: GoogleFonts.ibmPlexSans(fontSize: 12, color: PrivetTheme.mist.withValues(alpha: 0.65)), maxLines: 2, overflow: TextOverflow.ellipsis),
                      ),
                    if (paid && reminder.paidBy != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text('Marked by ${reminder.paidBy!.displayName}', style: GoogleFonts.ibmPlexSans(fontSize: 11, color: PrivetTheme.mist.withValues(alpha: 0.5))),
                      ),
                  ],
                ),
              ),
              if (onPin != null) ...[
                const SizedBox(width: 4),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Tooltip(
                    message: reminder.pinned ? 'Unpin from header' : 'Pin to header',
                    child: GestureDetector(
                      onTap: onPin,
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Icon(
                          reminder.pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                          size: 16,
                          color: reminder.pinned ? PrivetTheme.signal : PrivetTheme.mist,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
              if (onMarkDone != null) ...[
                const SizedBox(width: 8),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: onMarkDone,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: PrivetTheme.signal.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: PrivetTheme.signal.withValues(alpha: 0.4)),
                      ),
                      child: Text(isPayment ? 'Paid' : 'Done', style: GoogleFonts.syne(fontSize: 12, fontWeight: FontWeight.w700, color: PrivetTheme.signal)),
                    ),
                  ),
                ),
              ],
              if (onDelete != null) ...[
                const SizedBox(width: 2),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Tooltip(
                    message: 'Delete',
                    child: GestureDetector(
                      onTap: onDelete,
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Icon(
                          Icons.delete_outline_rounded,
                          size: 17,
                          color: PrivetTheme.danger.withValues(alpha: 0.75),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _buildTitle() {
    if (!reminder.isPayment) return reminder.note.isNotEmpty ? reminder.note : 'Reminder';
    return reminder.formattedAmount;
  }

  String _buildSub() {
    final paid = reminder.paid;
    if (paid) {
      final at = reminder.paidAt;
      final ds = at != null ? ' on ${at.year}-${at.month.toString().padLeft(2,'0')}-${at.day.toString().padLeft(2,'0')}' : '';
      return 'Completed$ds';
    }
    final overdue = reminder.isOverdue;
    return overdue ? 'Overdue — was due ${reminder.dueDate}' : 'Due ${reminder.dueDate}';
  }
}

class _AddReminderBtn extends StatelessWidget {
  const _AddReminderBtn({
    required this.label,
    required this.onTap,
    this.icon = Icons.add_rounded,
  });
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: PrivetTheme.ink.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PrivetTheme.line),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: PrivetTheme.mist),
        const SizedBox(width: 5),
        Text(label, style: GoogleFonts.syne(fontSize: 12, fontWeight: FontWeight.w600, color: PrivetTheme.mist)),
      ]),
    ),
  );
}

class _NumberBadge extends StatelessWidget {
  const _NumberBadge({required this.number, this.large = false, this.tiny = false});
  final int number;
  final bool large;
  final bool tiny;
  @override
  Widget build(BuildContext context) {
    final size = large ? 28.0 : (tiny ? 16.0 : 22.0);
    final font = large ? 14.0 : (tiny ? 9.0 : 12.0);
    return Container(
      width: size, height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: PrivetTheme.signal,
        borderRadius: BorderRadius.circular(size / 3),
        boxShadow: tiny ? null : [BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 4, offset: const Offset(0, 1))],
      ),
      child: Text('$number', style: GoogleFonts.syne(fontWeight: FontWeight.w800, fontSize: font, color: PrivetTheme.ink, height: 1)),
    );
  }
}

// ─── Header chips for Payment / Reminder ─────────────────────────────────────

/// Compact header chip for a pinned payment or plain reminder.
class ReminderHeaderChip extends StatelessWidget {
  const ReminderHeaderChip({
    super.key,
    required this.reminder,
    required this.onTap,
    this.onUnpin,
  });

  final PaymentReminder reminder;
  final VoidCallback onTap;
  final VoidCallback? onUnpin;

  @override
  Widget build(BuildContext context) {
    final overdue = reminder.isOverdue;
    final paid = reminder.paid;
    final isPayment = reminder.isPayment;

    final Color fill = paid
        ? PrivetTheme.signal
        : overdue
            ? PrivetTheme.danger
            : isPayment
                ? PrivetTheme.signal
                : PrivetTheme.signalDim;

    final String label = _buildLabel();

    return Semantics(
      button: true,
      label: isPayment ? 'Payment: $label' : 'Reminder: $label',
      child: Tooltip(
        message: paid
            ? 'Done — tap to open'
            : overdue
                ? 'Overdue! — tap to open'
                : isPayment
                    ? '${reminder.formattedAmount} — tap to open wallet'
                    : 'Due ${reminder.dueDate} — tap to open',
        child: _HeaderChipHoverClose(
          onClose: onUnpin,
          child: Material(
            color: Colors.transparent,
            child: Ink(
              decoration: BoxDecoration(
                color: PrivetTheme.ink.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: paid
                      ? PrivetTheme.signal.withValues(alpha: 0.55)
                      : overdue
                          ? PrivetTheme.danger.withValues(alpha: 0.7)
                          : fill.withValues(alpha: 0.55),
                ),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                mouseCursor: SystemMouseCursors.click,
                onTap: onTap,
                child: Container(
                  height: kChatHeaderChipHeight,
                  constraints: BoxConstraints(
                    minWidth: isPayment ? 52 : 64,
                    maxWidth: isPayment ? 100 : 150,
                  ),
                  padding: const EdgeInsets.fromLTRB(10, 0, 6, 0),
                  alignment: Alignment.centerLeft,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        paid
                            ? Icons.check_circle_rounded
                            : overdue
                                ? Icons.error_rounded
                                : isPayment
                                    ? Icons.account_balance_wallet_rounded
                                    : Icons.notifications_active_outlined,
                        size: 12,
                        color: fill,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          label,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.syne(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: fill,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _buildLabel() {
    if (!reminder.isPayment) {
      final text = reminder.note.isNotEmpty ? reminder.note : 'Reminder';
      return text.length > 18 ? '${text.substring(0, 16)}…' : text;
    }
    return reminder.compactAmount;
  }
}

// ─── Add / Edit Reminder Dialog ──────────────────────────────────────────────

/// Asks for confirmation and deletes a payment/reminder. Returns true if deleted.
Future<bool> _confirmDeleteReminder(
  BuildContext context, {
  required PrivetState state,
  required PaymentReminder reminder,
}) async {
  final label = reminder.isPayment ? 'payment' : 'reminder';
  final message = reminder.paid && reminder.expenses.isNotEmpty
      ? 'Delete this paid $label? Its ${reminder.expenses.length} logged expense(s) will also be removed.'
      : 'Delete this $label? This cannot be undone.';
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: PrivetTheme.panelElevated,
      title: Text(
        'Delete $label?',
        style: GoogleFonts.syne(color: PrivetTheme.mist, fontWeight: FontWeight.w700),
      ),
      content: Text(
        message,
        style: GoogleFonts.ibmPlexSans(color: PrivetTheme.paper, fontSize: 14),
      ),
      actions: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Cancel', style: TextStyle(color: PrivetTheme.mist)),
          ),
        ),
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              'Delete',
              style: TextStyle(color: PrivetTheme.danger, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  try {
    await state.deleteReminder(reminder);
    return true;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
    return false;
  }
}

Future<void> showReminderDialog(
  BuildContext context, {
  required PrivetState state,
  required String conversationId,
  PaymentReminder? existing,
  String? initialKind,
}) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => _ReminderDialog(
      state: state,
      conversationId: conversationId,
      existing: existing,
      initialKind: initialKind,
    ),
  );
}

class _ReminderDialog extends StatefulWidget {
  const _ReminderDialog({
    required this.state,
    required this.conversationId,
    this.existing,
    this.initialKind,
  });

  final PrivetState state;
  final String conversationId;
  final PaymentReminder? existing;
  final String? initialKind;

  @override
  State<_ReminderDialog> createState() => _ReminderDialogState();
}

class _ReminderDialogState extends State<_ReminderDialog> {
  final _amountCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  String _kind = 'payment';
  String _currency = 'USD';
  String _direction = 'owe';
  DateTime _dueDate = DateTime.now().add(const Duration(days: 7));
  bool _saving = false;

  static const _currencies = ['USD', 'EUR', 'GBP', 'RUB', 'UAH'];
  bool get _isPayment => _kind == 'payment';

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _kind = e.kind;
      final a = e.amountDouble;
      if (a != null) {
        _amountCtrl.text = a % 1 == 0 ? a.toInt().toString() : a.toStringAsFixed(2);
      }
      _noteCtrl.text = e.note;
      _currency = e.currency;
      _direction = e.direction;
      _dueDate = DateTime.tryParse(e.dueDate) ?? _dueDate;
    } else if (widget.initialKind != null) {
      _kind = widget.initialKind!;
    }
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDialog<DateTime>(
      context: context,
      builder: (ctx) => PrivetDateDialog(
        initialDate: _dueDate,
        firstDate: DateTime.now().subtract(const Duration(days: 365)),
        lastDate: DateTime.now().add(const Duration(days: 365 * 5)),
      ),
    );
    if (picked != null) setState(() => _dueDate = picked);
  }

  String _fmtDate(DateTime d) {
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }

  String _isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4,'0')}-${d.month.toString().padLeft(2,'0')}-${d.day.toString().padLeft(2,'0')}';

  Future<void> _save() async {
    int? amountCents;
    if (_isPayment) {
      final amountText = _amountCtrl.text.trim().replaceAll(',', '.');
      final amount = double.tryParse(amountText);
      if (amount == null || amount <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter a valid amount')),
        );
        return;
      }
      amountCents = (amount * 100).round();
    } else {
      if (_noteCtrl.text.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter a reminder text')),
        );
        return;
      }
    }

    setState(() => _saving = true);
    try {
      if (widget.existing == null) {
        await widget.state.addReminder(
          conversationId: widget.conversationId,
          kind: _kind,
          amountCents: amountCents,
          currency: _currency,
          direction: _direction,
          dueDate: _isoDate(_dueDate),
          note: _noteCtrl.text.trim(),
        );
      } else {
        await widget.state.updateReminderDetails(
          widget.existing!,
          amountCents: amountCents,
          currency: _currency,
          direction: _direction,
          dueDate: _isoDate(_dueDate),
          note: _noteCtrl.text.trim(),
        );
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;

    return AlertDialog(
      backgroundColor: PrivetTheme.panelElevated,
      title: Text(
        isEdit ? 'Edit' : (_isPayment ? 'Payment reminder' : 'Reminder'),
        style: GoogleFonts.syne(color: PrivetTheme.mist, fontWeight: FontWeight.w700),
      ),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Kind toggle only when creating without a preselected kind
            if (!isEdit && widget.initialKind == null) ...[
              Row(
                children: [
                  _kindBtn('Payment', Icons.account_balance_wallet_rounded, 'payment'),
                  const SizedBox(width: 8),
                  _kindBtn('Reminder', Icons.notifications_active_outlined, 'reminder'),
                ],
              ),
              const SizedBox(height: 14),
            ],
            // Payment-only fields
            if (_isPayment) ...[
              Row(
                children: [
                  _dirBtn('I pay', 'owe'),
                  const SizedBox(width: 8),
                  _dirBtn('I receive', 'owed'),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _amountCtrl,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.,]'))],
                      style: GoogleFonts.syne(color: PrivetTheme.paper, fontSize: 14),
                      decoration: _inputDeco('Amount'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  DropdownButton<String>(
                    value: _currency,
                    dropdownColor: PrivetTheme.panelElevated,
                    style: GoogleFonts.syne(color: PrivetTheme.mist, fontSize: 14),
                    underline: const SizedBox(),
                    items: _currencies.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                    onChanged: (v) => setState(() => _currency = v!),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            // Note — required for reminder, optional for payment
            TextField(
              controller: _noteCtrl,
              style: GoogleFonts.ibmPlexSans(color: PrivetTheme.paper, fontSize: 14),
              cursorColor: PrivetTheme.signal,
              decoration: _inputDeco(_isPayment ? 'Note (optional)' : 'Reminder text *'),
              maxLength: 120,
              maxLines: 2,
            ),
            const SizedBox(height: 4),
            // Due date
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: InkWell(
                onTap: _pickDate,
                mouseCursor: SystemMouseCursors.click,
                borderRadius: BorderRadius.circular(8),
                child: InputDecorator(
                  decoration: _inputDeco(_isPayment ? 'Due date' : 'Remind on'),
                  child: Text(
                    _fmtDate(_dueDate),
                    style: GoogleFonts.syne(color: PrivetTheme.paper, fontSize: 14),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (isEdit)
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: TextButton(
              onPressed: _saving ? null : () async {
                await widget.state.deleteReminder(widget.existing!);
                if (context.mounted) Navigator.of(context).pop();
              },
              child: Text('Delete', style: TextStyle(color: PrivetTheme.danger)),
            ),
          ),
        if (isEdit && _isPayment && !(widget.existing!.paid))
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: TextButton(
              onPressed: _saving ? null : () async {
                await widget.state.markReminderPaid(widget.existing!);
                if (context.mounted) Navigator.of(context).pop();
              },
              child: Text('Mark paid', style: TextStyle(color: PrivetTheme.signal)),
            ),
          ),
        if (isEdit && !_isPayment && !(widget.existing!.paid))
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: TextButton(
              onPressed: _saving ? null : () async {
                await widget.state.markReminderPaid(widget.existing!);
                if (context.mounted) Navigator.of(context).pop();
              },
              child: Text('Done', style: TextStyle(color: PrivetTheme.signal)),
            ),
          ),
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: Text('Cancel', style: TextStyle(color: PrivetTheme.mist)),
          ),
        ),
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: FilledButton(
            style: FilledButton.styleFrom(backgroundColor: PrivetTheme.signal),
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(isEdit ? 'Save' : 'Add', style: TextStyle(color: PrivetTheme.onAccent)),
          ),
        ),
      ],
    );
  }

  Widget _kindBtn(String label, IconData icon, String value) => MouseRegion(
        cursor: SystemMouseCursors.click,
        child: ChoiceChip(
        avatar: Icon(icon, size: 15, color: _kind == value ? PrivetTheme.signal : PrivetTheme.paper),
        label: Text(label, style: GoogleFonts.syne(fontSize: 12)),
        selected: _kind == value,
        selectedColor: PrivetTheme.signal.withValues(alpha: 0.25),
        backgroundColor: PrivetTheme.ink.withValues(alpha: 0.4),
        labelStyle: TextStyle(color: _kind == value ? PrivetTheme.signal : PrivetTheme.paper),
        side: BorderSide(color: _kind == value ? PrivetTheme.signal.withValues(alpha: 0.6) : PrivetTheme.line),
        onSelected: (_) => setState(() => _kind = value),
      ),
      );

  Widget _dirBtn(String label, String value) => MouseRegion(
        cursor: SystemMouseCursors.click,
        child: ChoiceChip(
        label: Text(label, style: GoogleFonts.syne(fontSize: 12)),
        selected: _direction == value,
        selectedColor: PrivetTheme.signal.withValues(alpha: 0.25),
        backgroundColor: PrivetTheme.ink.withValues(alpha: 0.4),
        labelStyle: TextStyle(color: _direction == value ? PrivetTheme.signal : PrivetTheme.paper),
        side: BorderSide(color: _direction == value ? PrivetTheme.signal.withValues(alpha: 0.6) : PrivetTheme.line),
        onSelected: (_) => setState(() => _direction = value),
      ),
      );

  InputDecoration _inputDeco(String label) => InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: PrivetTheme.mist.withValues(alpha: 0.75), fontSize: 13),
        hintStyle: TextStyle(color: PrivetTheme.mist.withValues(alpha: 0.45)),
        filled: true,
        fillColor: PrivetTheme.ink.withValues(alpha: 0.35),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: PrivetTheme.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: PrivetTheme.signal),
        ),
        counterStyle: TextStyle(color: PrivetTheme.mist.withValues(alpha: 0.4), fontSize: 10),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      );
}
