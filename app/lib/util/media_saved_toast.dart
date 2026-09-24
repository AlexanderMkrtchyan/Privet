import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../theme.dart';
import 'media_kind.dart';
import 'reveal_file.dart';

/// Status shown in the persistent download toast.
class MediaDownloadStatus {
  const MediaDownloadStatus({
    this.progress,
    this.savedPath,
    this.error,
    this.isVideo = false,
    this.filename,
  });

  final double? progress;
  final String? savedPath;
  final String? error;
  final bool isVideo;
  final String? filename;

  MediaDownloadStatus copyWith({
    double? progress,
    String? savedPath,
    String? error,
    bool? isVideo,
    String? filename,
  }) =>
      MediaDownloadStatus(
        progress: progress ?? this.progress,
        savedPath: savedPath ?? this.savedPath,
        error: error ?? this.error,
        isVideo: isVideo ?? this.isVideo,
        filename: filename ?? this.filename,
      );
}

/// Shows a bottom toast that stays until the user closes it or opens the
/// saved file. [status] updates in place (video download %).
void showMediaDownloadToast(
  BuildContext context, {
  required ValueNotifier<MediaDownloadStatus> status,
  GlobalKey<ScaffoldMessengerState>? messengerKey,
}) {
  final messenger =
      messengerKey?.currentState ?? ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(days: 365),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.transparent,
          elevation: 0,
          padding: EdgeInsets.zero,
          width: PrivetTheme.isCompact(context) ? null : 420,
          content: _MediaDownloadToastBody(status: status),
        ),
      );
}

class _MediaDownloadToastBody extends StatelessWidget {
  const _MediaDownloadToastBody({required this.status});

  final ValueNotifier<MediaDownloadStatus> status;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<MediaDownloadStatus>(
      valueListenable: status,
      builder: (context, s, _) {
        final saved = s.savedPath;
        final name = (s.filename?.trim().isNotEmpty == true)
            ? s.filename!.trim()
            : (saved != null && saved.isNotEmpty ? p.basename(saved) : '');
        final String label;
        if (s.error != null && s.error!.isNotEmpty) {
          label = s.error!;
        } else if (saved != null && saved.isNotEmpty) {
          label = 'Saved $name';
        } else if (s.isVideo) {
          final pct = s.progress == null
              ? ''
              : ' ${formatTransferPercent(s.progress!)}';
          label = 'Downloading video…$pct';
        } else {
          label = 'Downloading…';
        }
        final showView = saved != null && saved.isNotEmpty && s.error == null;
        return Material(
          color: PrivetTheme.panelElevated,
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: PrivetTheme.line),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: PrivetTheme.paper,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (showView) ...[
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: () {
                      ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
                      unawaited(revealInFileManager(saved));
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: PrivetTheme.signal,
                      foregroundColor: PrivetTheme.onAccent,
                      elevation: 0,
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      minimumSize: const Size(0, 34),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      textStyle: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    child: const Text('View in Downloads'),
                  ),
                ],
                IconButton(
                  tooltip: 'Dismiss',
                  onPressed: () =>
                      ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar(),
                  icon: Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: PrivetTheme.paper.withValues(alpha: 0.8),
                  ),
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
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

/// Runs [download] while showing a persistent toast. Video transfers report %.
Future<void> downloadMediaWithToast(
  BuildContext context, {
  required String url,
  required String filename,
  required Future<String?> Function({
    required String url,
    String? filename,
    void Function(double progress)? onProgress,
  }) download,
  bool isVideo = false,
  GlobalKey<ScaffoldMessengerState>? messengerKey,
}) async {
  final status = ValueNotifier(
    MediaDownloadStatus(
      isVideo: isVideo,
      filename: filename,
      progress: isVideo ? 0 : null,
    ),
  );
  showMediaDownloadToast(
    context,
    status: status,
    messengerKey: messengerKey,
  );
  try {
    final saved = await download(
      url: url,
      filename: filename,
      onProgress: isVideo
          ? (value) {
              status.value = status.value.copyWith(progress: value);
            }
          : null,
    );
    if (saved == null) {
      status.value = status.value.copyWith(
        error: 'Could not download $filename',
      );
      return;
    }
    status.value = status.value.copyWith(
      savedPath: saved,
      progress: 1,
      filename: filename,
    );
  } catch (e) {
    status.value = status.value.copyWith(
      error: 'Could not download $filename',
    );
  }
}
