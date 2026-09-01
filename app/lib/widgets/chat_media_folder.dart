import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../api/client.dart';
import '../models.dart';
import '../theme.dart';
import '../util/media_cache.dart';
import '../util/perf.dart';
import 'cached_media_image.dart';
import 'image_lightbox.dart';
import 'inline_video_player.dart';

enum ChatMediaFolderKind { photos, files }

/// Collect shared media from the currently loaded chat messages (and task
/// attachments) newest first (Teams-style). This is the instant/local view;
/// [ChatMediaFolderPane] layers the full server media history on top.
List<SharedMediaItem> collectSharedMedia(
  List<ChatMessage> messages, {
  required ChatMediaFolderKind folder,
  List<TaskItem>? tasks,
}) {
  final out = <SharedMediaItem>[];
  void add(MediaAttachment item, DateTime createdAt, String senderName,
      {String source = 'message', String? messageId}) {
    if (!_matchesFolder(item, folder)) return;
    out.add(
      SharedMediaItem(
        attachment: item,
        createdAt: createdAt,
        senderName: senderName,
        source: source,
        messageId: messageId,
      ),
    );
  }

  for (final m in messages) {
    for (final item in m.mediaItems) {
      add(item, m.createdAt, m.sender.displayName, messageId: m.id);
    }
  }
  // Images/files attached to tasks show up in shared media too, so nothing
  // shared in a task is hidden from the chat's Photos / Files browser.
  for (final t in tasks ?? const <TaskItem>[]) {
    for (final item in t.mediaItems) {
      add(item, t.createdAt, t.createdBy?.displayName ?? 'Task',
          source: 'task');
    }
  }
  out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return out;
}

bool _matchesFolder(MediaAttachment item, ChatMediaFolderKind folder) {
  final isPhoto = item.kind == 'image';
  final isFile = item.kind == 'file' ||
      item.kind == 'video' ||
      item.kind == 'audio' ||
      item.kind == 'voice';
  if (folder == ChatMediaFolderKind.photos && !isPhoto) return false;
  if (folder == ChatMediaFolderKind.files && !isFile) return false;
  return true;
}

List<SharedMediaItem> filterSharedMedia(
  List<SharedMediaItem> items,
  ChatMediaFolderKind folder,
) =>
    [for (final e in items) if (_matchesFolder(e.attachment, folder)) e];

/// Merge server-side history with locally known items, deduped per share.
List<SharedMediaItem> mergeSharedMedia(
  List<SharedMediaItem> server,
  List<SharedMediaItem> local,
) {
  final seen = <String>{};
  final out = <SharedMediaItem>[];
  for (final item in [...server, ...local]) {
    if (seen.add(item.dedupeKey)) out.add(item);
  }
  out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return out;
}

String mediaAbsoluteUrl(String mediaBase, String path) {
  if (path.startsWith('http://') || path.startsWith('https://')) return path;
  return '$mediaBase$path';
}

String _downloadName(MediaAttachment item) {
  if (item.fileName != null && item.fileName!.isNotEmpty) return item.fileName!;
  return switch (item.kind) {
    'image' => 'image.jpg',
    'video' => 'video.mp4',
    'audio' || 'voice' => 'audio.webm',
    _ => 'attachment',
  };
}

String _formatSize(int? bytes) {
  if (bytes == null || bytes <= 0) return '';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Saves [url] locally, serving cached bytes when available so the save is
/// instant instead of a fresh server download. On native platforms the saved
/// path is shown via a snackbar.
Future<void> saveMediaFromCache(
  BuildContext context,
  String url, {
  required String filename,
}) async {
  final saved = await downloadMediaFromCache(url, filename: filename);
  if (!context.mounted) return;
  if (saved != null) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(content: Text('Saved to $saved')),
    );
  }
}

/// Teams-style Photos / Files browser over the conversation's full shared
/// media history (chat messages + task attachments). Close (X) returns to chat.
class ChatMediaFolderPane extends StatefulWidget {
  const ChatMediaFolderPane({
    super.key,
    required this.folder,
    required this.messages,
    required this.mediaBase,
    required this.onClose,
    required this.onSelectFolder,
    required this.conversationId,
    required this.api,
    this.tasks,
  });

  final ChatMediaFolderKind folder;
  final List<ChatMessage> messages;
  final String mediaBase;
  final VoidCallback onClose;
  final ValueChanged<ChatMediaFolderKind> onSelectFolder;
  final String conversationId;
  final ApiClient api;

  /// Task attachments (active + history) shown alongside message media.
  final List<TaskItem>? tasks;

  @override
  State<ChatMediaFolderPane> createState() => _ChatMediaFolderPaneState();
}

class _ChatMediaFolderPaneState extends State<ChatMediaFolderPane> {
  List<SharedMediaItem> _serverMedia = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ChatMediaFolderPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationId != widget.conversationId) {
      _serverMedia = const [];
      _loading = true;
      _load();
    }
  }

  Future<void> _load() async {
    final conversationId = widget.conversationId;
    if (conversationId.isEmpty) {
      setState(() => _loading = false);
      return;
    }
    _loadedConversationId = conversationId;
    try {
      final items = await widget.api.sharedMedia(conversationId);
      if (!mounted || _loadedConversationId != conversationId) return;
      setState(() {
        _serverMedia = items;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || _loadedConversationId != conversationId) return;
      // Non-fatal: fall back to whatever is locally loaded in the thread.
      setState(() => _loading = false);
    }
  }

  String? _loadedConversationId;

  @override
  Widget build(BuildContext context) {
    final items = mergeSharedMedia(
      filterSharedMedia(_serverMedia, widget.folder),
      collectSharedMedia(
        widget.messages,
        folder: widget.folder,
        tasks: widget.tasks,
      ),
    );
    final emptyLabel = widget.folder == ChatMediaFolderKind.photos
        ? 'No photos shared yet'
        : 'No files shared yet';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FolderTabBar(
          folder: widget.folder,
          onClose: widget.onClose,
          onSelectFolder: widget.onSelectFolder,
        ),
        Expanded(
          child: _loading && items.isEmpty
              ? const Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : items.isEmpty
                  ? Center(
                      child: Text(
                        emptyLabel,
                        style: GoogleFonts.syne(
                          color: PrivetTheme.mist,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    )
                  : widget.folder == ChatMediaFolderKind.photos
                      ? _PhotosGrid(
                          items: items,
                          mediaBase: widget.mediaBase,
                        )
                      : _FilesList(
                          items: items,
                          mediaBase: widget.mediaBase,
                        ),
        ),
      ],
    );
  }
}

class _FolderTabBar extends StatelessWidget {
  const _FolderTabBar({
    required this.folder,
    required this.onClose,
    required this.onSelectFolder,
  });

  final ChatMediaFolderKind folder;
  final VoidCallback onClose;
  final ValueChanged<ChatMediaFolderKind> onSelectFolder;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: PrivetTheme.line)),
      ),
      child: Row(
        children: [
          const Spacer(),
          _FolderTab(
            label: 'Photos',
            icon: Icons.photo_library_outlined,
            selected: folder == ChatMediaFolderKind.photos,
            onTap: () => onSelectFolder(ChatMediaFolderKind.photos),
          ),
          const SizedBox(width: 4),
          _FolderTab(
            label: 'Files',
            icon: Icons.folder_outlined,
            selected: folder == ChatMediaFolderKind.files,
            onTap: () => onSelectFolder(ChatMediaFolderKind.files),
          ),
          IconButton(
            tooltip: 'Back to chat',
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }
}

class _FolderTab extends StatelessWidget {
  const _FolderTab({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? PrivetTheme.signal : PrivetTheme.mist;
    return Material(
      color: selected
          ? PrivetTheme.signal.withValues(alpha: 0.12)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 6),
              Text(
                label,
                style: GoogleFonts.syne(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PhotosGrid extends StatelessWidget {
  const _PhotosGrid({required this.items, required this.mediaBase});

  final List<SharedMediaItem> items;
  final String mediaBase;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 160,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 1,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final entry = items[i];
        final url = mediaAbsoluteUrl(mediaBase, entry.attachment.mediaUrl);
        return Material(
          color: PrivetTheme.ink,
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            mouseCursor: SystemMouseCursors.click,
            onTap: () {
              final urls = [
                for (final e in items)
                  mediaAbsoluteUrl(mediaBase, e.attachment.mediaUrl),
              ];
              final names = [
                for (final e in items) _downloadName(e.attachment),
              ];
              showImageLightbox(
                context,
                urls: urls,
                initialIndex: i,
                filenames: names,
              );
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Decode width-only so the square cover crops instead of
                // squashing: passing cacheHeight too makes the engine decode
                // the bitmap stretched to a square before cover even runs.
                CachedMediaImage(
                  url: url,
                  fit: BoxFit.cover,
                  cacheWidth: ImageDecodeCaps.cacheWidth(
                    180,
                    dpr: MediaQuery.devicePixelRatioOf(context),
                  ),
                  errorBuilder: (context, error, stackTrace) => Center(
                    child: Icon(
                      Icons.broken_image_outlined,
                      color: PrivetTheme.mist,
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          PrivetTheme.ink.withValues(alpha: 0.75),
                        ],
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(6, 14, 6, 6),
                      child: Text(
                        DateFormat.MMMd().add_jm().format(entry.createdAt.toLocal()),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10,
                          color: PrivetTheme.paper,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _FilesList extends StatelessWidget {
  const _FilesList({required this.items, required this.mediaBase});

  final List<SharedMediaItem> items;
  final String mediaBase;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: items.length,
      separatorBuilder: (context, index) =>
          Divider(height: 1, color: PrivetTheme.line),
      itemBuilder: (context, i) {
        final entry = items[i];
        final item = entry.attachment;
        final url = mediaAbsoluteUrl(mediaBase, item.mediaUrl);
        final name = item.fileName?.isNotEmpty == true
            ? item.fileName!
            : switch (item.kind) {
                'video' => 'Video',
                'audio' => 'Audio',
                'voice' => 'Voice message',
                _ => 'File',
              };
        final size = _formatSize(item.fileSize);
        final meta = [
          if (size.isNotEmpty) size,
          DateFormat.yMMMd().add_jm().format(entry.createdAt.toLocal()),
          entry.senderName,
        ].join(' · ');

        final icon = switch (item.kind) {
          'video' => Icons.videocam_rounded,
          'audio' || 'voice' => Icons.audiotrack_rounded,
          _ => Icons.insert_drive_file_rounded,
        };

        return ListTile(
          leading: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: PrivetTheme.panelElevated,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: PrivetTheme.line),
            ),
            child: Icon(icon, color: PrivetTheme.signal),
          ),
          title: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            meta,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: PrivetTheme.mist, fontSize: 12),
          ),
          trailing: IconButton(
            tooltip: 'Download',
            onPressed: () =>
                saveMediaFromCache(context, url, filename: _downloadName(item)),
            icon: Icon(Icons.download_rounded, color: PrivetTheme.signal),
          ),
          onTap: item.kind == 'video'
              ? () => _openVideo(context, url, name)
              : () => saveMediaFromCache(
                    context,
                    url,
                    filename: _downloadName(item),
                  ),
        );
      },
    );
  }

  void _openVideo(BuildContext context, String url, String title) {
    showDialog<void>(
      context: context,
      builder: (ctx) {
        return Dialog(
          backgroundColor: PrivetTheme.ink,
          insetPadding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 4, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Text(
                            title,
                            style: GoogleFonts.syne(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close',
                        onPressed: () => Navigator.pop(ctx),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: InlineVideoPlayer(url: url),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
