import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../models.dart';
import '../theme.dart';
import '../util/media_download.dart';
import 'inline_video_player.dart';

enum ChatMediaFolderKind { photos, files }

class SharedMediaEntry {
  const SharedMediaEntry({
    required this.attachment,
    required this.createdAt,
    required this.senderName,
  });

  final MediaAttachment attachment;
  final DateTime createdAt;
  final String senderName;
}

/// Collect shared media from chat messages, newest first (Teams-style).
List<SharedMediaEntry> collectSharedMedia(
  List<ChatMessage> messages, {
  required ChatMediaFolderKind folder,
}) {
  final out = <SharedMediaEntry>[];
  for (final m in messages) {
    for (final item in m.mediaItems) {
      final isPhoto = item.kind == 'image';
      final isFile = item.kind == 'file' ||
          item.kind == 'video' ||
          item.kind == 'audio' ||
          item.kind == 'voice';
      if (folder == ChatMediaFolderKind.photos && !isPhoto) continue;
      if (folder == ChatMediaFolderKind.files && !isFile) continue;
      out.add(
        SharedMediaEntry(
          attachment: item,
          createdAt: m.createdAt,
          senderName: m.sender.displayName,
        ),
      );
    }
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

/// Teams-style Photos / Files browser. Close (X) returns to chat.
class ChatMediaFolderPane extends StatelessWidget {
  const ChatMediaFolderPane({
    super.key,
    required this.folder,
    required this.messages,
    required this.mediaBase,
    required this.onClose,
    required this.onSelectFolder,
  });

  final ChatMediaFolderKind folder;
  final List<ChatMessage> messages;
  final String mediaBase;
  final VoidCallback onClose;
  final ValueChanged<ChatMediaFolderKind> onSelectFolder;

  @override
  Widget build(BuildContext context) {
    final items = collectSharedMedia(messages, folder: folder);
    final emptyLabel = folder == ChatMediaFolderKind.photos
        ? 'No photos shared yet'
        : 'No files shared yet';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FolderTabBar(
          folder: folder,
          onClose: onClose,
          onSelectFolder: onSelectFolder,
        ),
        Expanded(
          child: items.isEmpty
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
              : folder == ChatMediaFolderKind.photos
                  ? _PhotosGrid(items: items, mediaBase: mediaBase)
                  : _FilesList(items: items, mediaBase: mediaBase),
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

  final List<SharedMediaEntry> items;
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
            onTap: () => _openPhoto(context, url, entry),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.network(
                  url,
                  fit: BoxFit.cover,
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

  void _openPhoto(BuildContext context, String url, SharedMediaEntry entry) {
    showDialog<void>(
      context: context,
      builder: (ctx) {
        return Dialog(
          backgroundColor: PrivetTheme.ink,
          insetPadding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720, maxHeight: 720),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(ctx),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ),
                Flexible(
                  child: InteractiveViewer(
                    child: Image.network(
                      url,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) =>
                          const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('Image unavailable'),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${entry.senderName} · ${DateFormat.yMMMd().add_jm().format(entry.createdAt.toLocal())}',
                          style: TextStyle(
                            color: PrivetTheme.mist,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => downloadMedia(
                          url,
                          filename: _downloadName(entry.attachment),
                        ),
                        icon: const Icon(Icons.download_rounded, size: 18),
                        label: const Text('Download'),
                      ),
                    ],
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

  final List<SharedMediaEntry> items;
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
                downloadMedia(url, filename: _downloadName(item)),
            icon: Icon(Icons.download_rounded, color: PrivetTheme.signal),
          ),
          onTap: item.kind == 'video'
              ? () => _openVideo(context, url, name)
              : () => downloadMedia(url, filename: _downloadName(item)),
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
