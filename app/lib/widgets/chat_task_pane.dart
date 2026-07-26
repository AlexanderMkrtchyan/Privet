import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models.dart';
import '../state.dart';
import '../theme.dart';
import '../util/clipboard_files.dart';
import '../util/perf.dart';
import 'web_attach_button.dart';

/// Compact header control: green "Task done" or a live 3/7 progress bar.
class TaskHeaderChip extends StatelessWidget {
  const TaskHeaderChip({
    super.key,
    required this.board,
    required this.active,
    required this.onTap,
  });

  final ConversationTasks board;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final done = board.isComplete;
    final fill = done ? PrivetTheme.signal : const Color(0xFF3D9CF0);
    final track = done
        ? PrivetTheme.signal.withValues(alpha: 0.22)
        : const Color(0xFF3D9CF0).withValues(alpha: 0.18);
    final label = done
        ? 'Task done'
        : '${board.doneCount}/${board.total}';

    return Semantics(
      button: true,
      label: done
          ? 'Tasks: all done. Open task board'
          : 'Tasks: ${board.doneCount} of ${board.total} done. Open task board',
      child: Tooltip(
      message: done
          ? 'Open tasks — all clear'
          : 'Open tasks — ${board.doneCount} of ${board.total} done',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            constraints: const BoxConstraints(minWidth: 128, maxWidth: 240),
            padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
            decoration: BoxDecoration(
              color: active
                  ? PrivetTheme.panelElevated
                  : PrivetTheme.ink.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: active
                    ? fill.withValues(alpha: 0.7)
                    : done
                        ? PrivetTheme.signal.withValues(alpha: 0.45)
                        : PrivetTheme.line,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      done
                          ? Icons.check_circle_rounded
                          : Icons.checklist_rtl_rounded,
                      size: 16,
                      color: fill,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        label,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.syne(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: done ? PrivetTheme.signal : PrivetTheme.paper,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                IgnorePointer(
                  child: ExcludeSemantics(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(99),
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: board.progress),
                        duration: const Duration(milliseconds: 280),
                        curve: Curves.easeOutCubic,
                        builder: (context, value, _) {
                          return LinearProgressIndicator(
                            value: value.clamp(0.0, 1.0),
                            minHeight: 5,
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
    );
  }
}

/// Full-pane task board (like Photos/Files). Close with X.
class ChatTaskPane extends StatefulWidget {
  const ChatTaskPane({
    super.key,
    required this.state,
    required this.conversationId,
    required this.mediaBase,
    required this.onClose,
  });

  final PrivetState state;
  final String conversationId;
  final String mediaBase;
  final VoidCallback onClose;

  @override
  State<ChatTaskPane> createState() => _ChatTaskPaneState();
}

class _ChatTaskPaneState extends State<ChatTaskPane> {
  final _addCtrl = TextEditingController();
  final _addFocus = FocusNode();
  PickedBytes? _draftAttach;
  bool _saving = false;

  @override
  void dispose() {
    _addCtrl.dispose();
    _addFocus.dispose();
    super.dispose();
  }

  String _abs(String? path) {
    if (path == null || path.isEmpty) return '';
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    return '${widget.mediaBase}$path';
  }

  Future<void> _submitNew() async {
    final text = _addCtrl.text.trim();
    if (text.isEmpty && _draftAttach == null) return;
    if (_saving) return;
    setState(() => _saving = true);
    try {
      String? mediaUrl;
      String? mimeType;
      String? fileName;
      final draft = _draftAttach;
      if (draft != null) {
        final up = await widget.state.api.uploadBytes(
          bytes: draft.bytes,
          filename: draft.filename,
          mimeType: draft.mimeType,
        );
        mediaUrl = up.mediaUrl;
        mimeType = up.mimeType;
        fileName = up.fileName;
      }
      await widget.state.addTask(
        conversationId: widget.conversationId,
        body: text.isEmpty ? (fileName ?? 'Screenshot') : text,
        mediaUrl: mediaUrl,
        mimeType: mimeType,
        fileName: fileName,
      );
      _addCtrl.clear();
      setState(() => _draftAttach = null);
      _addFocus.requestFocus();
    } catch (e) {
      widget.state.setError('Could not add task: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _attachToItem(TaskItem item) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        withData: true,
        type: FileType.any,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) return;
      final mime = _mimeFor(file.name);
      final up = await widget.state.api.uploadBytes(
        bytes: bytes,
        filename: file.name,
        mimeType: mime,
      );
      await widget.state.attachTaskMedia(
        item: item,
        mediaUrl: up.mediaUrl,
        mimeType: up.mimeType,
        fileName: up.fileName,
      );
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
    final items = board.items;
    final done = board.isComplete;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: PrivetTheme.line)),
          ),
          child: Row(
            children: [
              const Spacer(),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    'Tasks',
                    style: GoogleFonts.syne(
                      fontWeight: FontWeight.w700,
                      fontSize: 18,
                    ),
                  ),
                  Text(
                    done
                        ? (items.isEmpty
                            ? 'Nothing open — add a step below'
                            : 'All ${items.length} done')
                        : '${board.doneCount} of ${board.total} done',
                    style: TextStyle(
                      color: done ? PrivetTheme.signal : PrivetTheme.mist,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              if (board.doneCount > 0)
                TextButton(
                  onPressed: () =>
                      widget.state.clearDoneTasks(widget.conversationId),
                  child: const Text('Clear done'),
                ),
              IconButton(
                tooltip: 'Back to chat',
                onPressed: widget.onClose,
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: _TaskProgressBanner(board: board),
        ),
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.task_alt_rounded,
                          size: 48,
                          color: PrivetTheme.signal.withValues(alpha: 0.85),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Task done',
                          style: GoogleFonts.syne(
                            fontWeight: FontWeight.w700,
                            fontSize: 22,
                            color: PrivetTheme.signal,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Add steps here, or right-click any message → Add to task',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.ibmPlexSans(
                            color: PrivetTheme.mist,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return _TaskRow(
                      number: index + 1,
                      item: item,
                      mediaUrl: _abs(item.mediaUrl),
                      onToggle: () => widget.state.toggleTaskDone(item),
                      onSaveBody: (body) =>
                          widget.state.updateTaskBody(item, body),
                      onDelete: () => widget.state.deleteTask(item),
                      onClearMedia: () => widget.state.clearTaskMedia(item),
                      onAttach: () => _attachToItem(item),
                    );
                  },
                ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: PrivetTheme.line)),
            color: PrivetTheme.panelElevated,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_draftAttach != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: _draftAttach!.mimeType.startsWith('image/')
                              ? Image.memory(
                                  _draftAttach!.bytes,
                                  width: 72,
                                  height: 72,
                                  fit: BoxFit.cover,
                                )
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
                          child: Material(
                            color: PrivetTheme.panelElevated,
                            shape: const CircleBorder(),
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: () => setState(() => _draftAttach = null),
                              child: const Padding(
                                padding: EdgeInsets.all(2),
                                child: Icon(Icons.close_rounded, size: 16),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              Row(
                children: [
                  WebAttachButton(
                    tooltip: 'Attach screenshot',
                    onPicked: (file) => setState(() => _draftAttach = file),
                    onPressedFallback: () {},
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
                        hintText: 'Add a task step…',
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _saving ? null : _submitNew,
                    child: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Add'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TaskProgressBanner extends StatelessWidget {
  const _TaskProgressBanner({required this.board});

  final ConversationTasks board;

  @override
  Widget build(BuildContext context) {
    final done = board.isComplete;
    final fill = done ? PrivetTheme.signal : const Color(0xFF3D9CF0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              done ? 'Complete' : 'Progress',
              style: GoogleFonts.ibmPlexSans(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: PrivetTheme.mist,
              ),
            ),
            const Spacer(),
            Text(
              board.total == 0
                  ? '0 / 0'
                  : '${board.doneCount} / ${board.total}',
              style: GoogleFonts.syne(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: done ? PrivetTheme.signal : PrivetTheme.paper,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: LinearProgressIndicator(
            value: board.progress,
            minHeight: 8,
            backgroundColor: fill.withValues(alpha: 0.16),
            color: fill,
          ),
        ),
      ],
    );
  }
}

class _TaskRow extends StatefulWidget {
  const _TaskRow({
    required this.number,
    required this.item,
    required this.mediaUrl,
    required this.onToggle,
    required this.onSaveBody,
    required this.onDelete,
    required this.onClearMedia,
    required this.onAttach,
  });

  final int number;
  final TaskItem item;
  final String mediaUrl;
  final VoidCallback onToggle;
  final ValueChanged<String> onSaveBody;
  final VoidCallback onDelete;
  final VoidCallback onClearMedia;
  final VoidCallback onAttach;

  @override
  State<_TaskRow> createState() => _TaskRowState();
}

class _TaskRowState extends State<_TaskRow> {
  late final TextEditingController _ctrl;
  late final FocusNode _focus;

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
    if (!_focus.hasFocus) {
      final next = _ctrl.text.trim();
      if (next.isNotEmpty && next != widget.item.body) {
        widget.onSaveBody(next);
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

  void _openPreview() {
    if (widget.mediaUrl.isEmpty || !widget.item.isImage) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: PrivetTheme.ink,
        insetPadding: const EdgeInsets.all(24),
        child: Stack(
          children: [
            InteractiveViewer(
              child: Image.network(widget.mediaUrl, fit: BoxFit.contain),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                onPressed: () => Navigator.pop(ctx),
                icon: const Icon(Icons.close_rounded),
              ),
            ),
            Positioned(
              top: 12,
              left: 12,
              child: _NumberBadge(number: widget.number, large: true),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return Material(
      color: PrivetTheme.panelElevated,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 6, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _NumberBadge(number: widget.number),
            const SizedBox(width: 8),
            InkWell(
              onTap: widget.onToggle,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  item.done
                      ? Icons.check_box_rounded
                      : Icons.check_box_outline_blank_rounded,
                  color: item.done ? PrivetTheme.signal : PrivetTheme.mist,
                  size: 22,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _ctrl,
                focusNode: _focus,
                maxLines: null,
                style: GoogleFonts.ibmPlexSans(
                  fontSize: 14,
                  decoration:
                      item.done ? TextDecoration.lineThrough : null,
                  color: item.done ? PrivetTheme.mist : PrivetTheme.paper,
                ),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  contentPadding: EdgeInsets.symmetric(vertical: 4),
                ),
              ),
            ),
            if (item.hasMedia)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    GestureDetector(
                      onTap: _openPreview,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: item.isImage
                            ? Image.network(
                                widget.mediaUrl,
                                width: 52,
                                height: 52,
                                fit: BoxFit.cover,
                                cacheWidth: ImageDecodeCaps.cacheWidth(
                                  52,
                                  dpr: MediaQuery.devicePixelRatioOf(context),
                                ),
                                cacheHeight: ImageDecodeCaps.cacheHeight(
                                  52,
                                  dpr: MediaQuery.devicePixelRatioOf(context),
                                ),
                                errorBuilder: (_, __, ___) =>
                                    _fileThumb(item.fileName),
                              )
                            : _fileThumb(item.fileName),
                      ),
                    ),
                    Positioned(
                      top: -6,
                      right: -6,
                      child: Material(
                        color: PrivetTheme.panel,
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: widget.onClearMedia,
                          child: const Padding(
                            padding: EdgeInsets.all(2),
                            child: Icon(Icons.close_rounded, size: 14),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: 2,
                      left: 2,
                      child: _NumberBadge(number: widget.number, tiny: true),
                    ),
                  ],
                ),
              )
            else
              IconButton(
                tooltip: 'Attach screenshot',
                onPressed: widget.onAttach,
                icon: const Icon(Icons.image_outlined, size: 20),
                color: PrivetTheme.mist,
                visualDensity: VisualDensity.compact,
              ),
            IconButton(
              tooltip: 'Remove',
              onPressed: widget.onDelete,
              icon: const Icon(Icons.close_rounded, size: 18),
              color: PrivetTheme.mist,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }

  Widget _fileThumb(String? name) {
    return Container(
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
}

class _NumberBadge extends StatelessWidget {
  const _NumberBadge({
    required this.number,
    this.large = false,
    this.tiny = false,
  });

  final int number;
  final bool large;
  final bool tiny;

  @override
  Widget build(BuildContext context) {
    final size = large ? 28.0 : (tiny ? 16.0 : 22.0);
    final font = large ? 14.0 : (tiny ? 9.0 : 12.0);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFF3D9CF0),
        borderRadius: BorderRadius.circular(size / 3),
        boxShadow: tiny
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ],
      ),
      child: Text(
        '$number',
        style: GoogleFonts.syne(
          fontWeight: FontWeight.w800,
          fontSize: font,
          color: PrivetTheme.ink,
          height: 1,
        ),
      ),
    );
  }
}
