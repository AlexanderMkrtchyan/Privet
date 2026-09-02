import 'dart:async';
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../models.dart';
import '../theme.dart';
import '../util/agent_debug.dart';
import '../util/ai_turn.dart';
import '../util/app_clipboard.dart';
import '../util/call_history.dart';
import '../util/copy_image.dart';
import '../util/low_resource.dart';
import '../util/media_download.dart';
import '../util/perf.dart';
import '../util/rich_text_markup.dart';
import '../util/task_event_payload.dart';
import '../util/web_select_cursor.dart';
import 'compact_emoji_picker.dart';
import 'cached_media_image.dart';
import 'image_lightbox.dart';
import 'inline_video_player.dart';
import 'privet_emoji.dart';
import 'selectable_markup_text.dart';

const kQuickReactions = ['❤️', '👍', '😂', '😮'];

/// Shared — constructing [DateFormat] per bubble every frame is wasteful.
final _messageTimeFormat = DateFormat.jm();

/// Prevents double-open from Listener + GestureDetector both firing on web.
bool _reactionMenuOpen = false;

/// Media item the user right-clicked inside a chat image tile, set
/// synchronously by the tile's pointer handler (which runs before the bubble's
/// own handler on the same event) so the bubble menu can apply Copy image /
/// Reply / Forward / Add to task to THAT image instead of the first one.
MediaAttachment? _imageMenuTarget;

/// Selection state for message-body text lives in the shared
/// [MarkupTextSelectionScope] (messages and tasks both select through
/// `SelectableMarkupText`, and only one surface is mounted at a time).

/// Set while a bubble is being horizontally dragged for swipe-to-reply so
/// nested text MouseRegions can [MouseCursor.defer] and show grab/grabbing.
bool privetBubbleDragging = false;

/// True while a web message-body drag-select is in progress (after slop).
bool get privetMessageSelectionDragging => MarkupTextSelectionScope.dragging;
set privetMessageSelectionDragging(bool v) =>
    MarkupTextSelectionScope.dragging = v;

/// Set on pointer-down when the message body text claims the hit; bubble
/// chrome / empty-space probes use this so text taps are not treated as
/// outside clicks.
bool get privetMessageBodyClaimedPointer =>
    MarkupTextSelectionScope.bodyClaimedPointer;
set privetMessageBodyClaimedPointer(bool v) =>
    MarkupTextSelectionScope.bodyClaimedPointer = v;

/// Clear message text selection + floating Copy/Reply/Forward bar.
void privetClearMessageSelection() => MarkupTextSelectionScope.clearSelection();

/// Non-empty while message body text is selected (floating Copy bar).
String? get privetActiveMessageSelection => MarkupTextSelectionScope.activeText;

/// Same as the floating **Copy** button: write selection to [AppClipboard]
/// and dismiss the selection UI. Returns true when something was copied.
bool privetCopyActiveMessageSelection() {
  final text = MarkupTextSelectionScope.activeText;
  if (text == null || text.isEmpty) return false;
  MarkupTextSelectionScope.clearSelection();
  AppClipboard.setText(text);
  return true;
}

/// Epoch used by the chat list to clear selection on empty-space clicks.
int get privetMessageBodyPointerEpoch => MarkupTextSelectionScope.pointerEpoch;

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.mine,
    required this.mediaBase,
    required this.selfId,
    this.showSender = false,
    this.highlighted = false,
    this.readByPeer = false,
    this.seenByLabel,
    this.addedToTask = false,
    this.onReply,
    this.onForward,
    this.onReact,
    this.onAddToTask,
    this.onOpenTasks,
    this.onAskAi,
    this.aiActive = false,
    this.onEdit,
    this.onDelete,
    this.onSeenBy,
    this.onReplyTap,
    this.onFormatMessage,
    this.fontScale = 1.0,
    this.defaultFontFamily = '',
    this.onSetDefaultFont,
    this.onTaskEventTap,
  });

  final ChatMessage message;
  final bool mine;
  final String mediaBase;
  final String? selfId;
  final bool showSender;
  final bool highlighted;
  final bool readByPeer;
  final String? seenByLabel;

  /// Scales the message content text (body, captions, reply quote, big emoji)
  /// around the 15px default. Set from [PrivetState.chatFontSize].
  final double fontScale;

  /// Default font family ('' = app default) for message text, from
  /// [PrivetState.chatFontFamily]. Messages with an explicit `[font=…]` run
  /// still use that run's font on top of this base.
  final String defaultFontFamily;

  /// Persists a font picked in the message text "Aa" menu as the app-wide
  /// default message font (see [PrivetState.setChatFontFamily]).
  final ValueChanged<String>? onSetDefaultFont;

  /// True when a shared task item was created from this message.
  final bool addedToTask;
  final void Function(ChatMessage message, {String? selectedText})? onReply;
  final void Function(ChatMessage message, {String? selectedText})? onForward;
  final void Function(ChatMessage message, String emoji)? onReact;
  final ValueChanged<ChatMessage>? onAddToTask;

  /// Opens the conversation task board (e.g. when tapping the "added to task" note).
  final VoidCallback? onOpenTasks;
  final ValueChanged<ChatMessage>? onAskAi;

  /// When false, Ask AI is shown but not tappable.
  final bool aiActive;
  final ValueChanged<ChatMessage>? onEdit;
  final ValueChanged<ChatMessage>? onDelete;
  final ValueChanged<ChatMessage>? onSeenBy;

  /// Tapping the reply quote jumps to and highlights the replied-to message.
  final ValueChanged<ReplyPreview>? onReplyTap;

  /// Redacts a text selection in this message (bold / italic / highlight).
  /// Receives the selection in plain-text coordinates plus the full format the
  /// selection should have.
  final void Function(TextSelection selection, TextFormat format)?
      onFormatMessage;

  /// Tapped a task-change row (kind 'task_event') — open the task in Tasks.
  final VoidCallback? onTaskEventTap;

  @override
  Widget build(BuildContext context) {
    final bubble = _buildBubble(context);
    if (!highlighted) return bubble;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: PrivetTheme.signal.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: PrivetTheme.signal.withValues(alpha: 0.55),
          width: 1.5,
        ),
      ),
      child: bubble,
    );
  }

  Widget _buildBubble(BuildContext context) {
    if (message.isDeleted) {
      return Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: PrivetTheme.panelElevated.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: PrivetTheme.line),
            ),
            child: Text(
              'Message deleted',
              style: GoogleFonts.ibmPlexSans(
                fontSize: 13,
                fontStyle: FontStyle.italic,
                color: PrivetTheme.mist,
              ),
            ),
          ),
        ),
      );
    }

    if (message.isCallHistory) {
      return _CallHistoryChip(message: message);
    }

    if (message.isTaskEvent) {
      return _TaskEventChip(
        message: message,
        onTap: onTaskEventTap,
      );
    }

    if (message.aiLocal || message.kind == 'ai') {
      final maxBubble = MediaQuery.sizeOf(context).width * 0.78;
      final payload = AiTurnPayload.tryParse(message.body);
      final onlyYou = message.aiLocal || (payload?.private ?? false);
      final header =
          payload?.headerLabel ??
          (onlyYou ? 'Privet AI · only you' : 'Privet AI');
      final question = payload?.question.trim() ?? '';
      final answer = payload?.answer ?? message.body;
      // Same side as the asker: yours on the right, a peer's shared AI on the left.
      return Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Container(
            constraints: BoxConstraints(maxWidth: maxBubble),
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            decoration: BoxDecoration(
              color: PrivetTheme.panelElevated,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: PrivetTheme.signal.withValues(alpha: 0.45),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.auto_awesome_rounded,
                      size: 16,
                      color: PrivetTheme.signal.withValues(alpha: 0.9),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        header,
                        style: GoogleFonts.ibmPlexSans(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: PrivetTheme.signal,
                        ),
                      ),
                    ),
                  ],
                ),
                if (question.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    question,
                    style: GoogleFonts.ibmPlexSans(
                      fontSize: 13,
                      height: 1.35,
                      color: PrivetTheme.mist,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(height: 1, color: PrivetTheme.line),
                ],
                const SizedBox(height: 8),
                if (message.pending)
                  Text(
                    answer,
                    style: GoogleFonts.ibmPlexSans(
                      fontSize: 14,
                      fontStyle: FontStyle.italic,
                      color: PrivetTheme.mist,
                    ),
                  )
                else
                  SelectableMarkupText(
                    text: answer,
                    fontScale: fontScale,
                    defaultFont: defaultFontFamily,
                    onSetDefaultFont: onSetDefaultFont,
                    onReply: onReply == null
                        ? null
                        : (selected) =>
                              onReply!(message, selectedText: selected),
                    onForward: onForward == null
                        ? null
                        : (selected) =>
                              onForward!(message, selectedText: selected),
                    hoverStyle: TextStyle(
                      height: 1.35,
                      fontSize: 15 * fontScale,
                      color: PrivetTheme.signal,
                    ),
                    toolbarSuppressed: () => _reactionMenuOpen,
                    dragging: () => privetBubbleDragging,
                  ),
              ],
            ),
          ),
        ),
      );
    }

    // Teams-style: own messages on the right, others on the left.
    final maxBubble = MediaQuery.sizeOf(context).width * 0.68;
    final accent = message.hasAccentWrap;
    final bubble = Listener(
      onPointerDown: message.pending
          ? null
          : (event) {
              // Flutter web: secondary mouse button (right-click).
              if (event.buttons == kSecondaryMouseButton) {
                // One menu only — never stack with SelectableText / browser menus.
                // An image tile's handler already ran (leaf-first) and, when the
                // click was on an image, recorded it as the menu target.
                final target = _imageMenuTarget;
                _imageMenuTarget = null;
                MarkupTextSelectionScope.clearSelection();
                _openMenu(context, event.position, imageTarget: target);
              }
            },
      child: ExcludeSemantics(
        // Long-press must not become a semantics button — on web that forces
        // CSS `cursor: pointer` over the whole bubble, including selectable text.
        child: GestureDetector(
          // Long-press for touch; right-click is handled by Listener above
          // so we don't open two stacked dialogs on web.
          onLongPressStart: message.pending
              ? null
              : (details) {
                  MarkupTextSelectionScope.clearSelection();
                  // Long-press never targets a specific image.
                  _imageMenuTarget = null;
                  _openMenu(context, details.globalPosition);
                },
          child: Container(
            constraints: BoxConstraints(maxWidth: maxBubble),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: mine ? PrivetTheme.mine : PrivetTheme.panelElevated,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(mine ? 16 : 4),
                bottomRight: Radius.circular(mine ? 4 : 16),
              ),
              border: Border.all(
                // Privet-P green wrap only for replies + link metadata cards.
                color: accent
                    ? PrivetTheme.signal.withValues(alpha: 0.75)
                    : PrivetTheme.line,
                width: accent ? 1.4 : 1,
              ),
            ),
            // Hug content width (no IntrinsicWidth).
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (showSender && !mine)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      widthFactor: 1,
                      child: Text(
                        message.sender.displayName.isNotEmpty
                            ? message.sender.displayName
                            : (message.sender.handle.isNotEmpty
                                  ? '@${message.sender.handle}'
                                  : ''),
                        textAlign: TextAlign.left,
                        style: GoogleFonts.syne(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: PrivetTheme.signal,
                        ),
                      ),
                    ),
                  ),
                if (message.forwardedFrom != null) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: _MessageStatusNote(
                      icon: Icons.shortcut_rounded,
                      label: 'Forwarded from ${message.forwardedFrom!.label}',
                      prominent: true,
                    ),
                  ),
                ],
                if (message.forwardedToLabel != null) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: _MessageStatusNote(
                      icon: Icons.arrow_outward_rounded,
                      label: message.forwardedToLabel!,
                      prominent: true,
                    ),
                  ),
                ],
                if (message.replyTo != null) ...[
                  _ReplyQuote(
                    reply: message.replyTo!,
                    fontScale: fontScale,
                    defaultFont: defaultFontFamily,
                    mediaBase: mediaBase,
                    onTap: onReplyTap == null
                        ? null
                        : () => onReplyTap!(message.replyTo!),
                  ),
                  const SizedBox(height: 6),
                ],
                Align(
                  alignment: Alignment.centerLeft,
                  widthFactor: 1,
                  child: _body(mediaBase),
                ),
                if (message.linkPreview != null) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    widthFactor: 1,
                    child: _LinkPreviewCard(preview: message.linkPreview!),
                  ),
                ],
                if (addedToTask) ...[
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    widthFactor: 1,
                    child: _MessageStatusNote(
                      icon: Icons.playlist_add_check_rounded,
                      label: 'Added to task',
                      onTap: onOpenTasks,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  widthFactor: 1,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (message.editedAt != null)
                        const Padding(
                          padding: EdgeInsets.only(right: 6),
                          child: _MessageStatusNote(
                            icon: Icons.edit_rounded,
                            label: 'edited',
                            compact: true,
                          ),
                        ),
                      Text(
                        _messageTimeFormat.format(message.createdAt.toLocal()),
                        style: TextStyle(
                          color: PrivetTheme.mist.withValues(alpha: 0.8),
                          fontSize: 10,
                        ),
                      ),
                      if (mine) ...[
                        const SizedBox(width: 4),
                        GestureDetector(
                          onTap: readByPeer && onSeenBy != null
                              ? () => onSeenBy!(message)
                              : null,
                          child: Icon(
                            readByPeer
                                ? Icons.done_all_rounded
                                : Icons.done_rounded,
                            size: 14,
                            color: readByPeer
                                ? PrivetTheme.signal
                                : PrivetTheme.mist.withValues(alpha: 0.75),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (mine &&
                    seenByLabel != null &&
                    seenByLabel!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  GestureDetector(
                    onTap: onSeenBy == null
                        ? null
                        : () => onSeenBy!(message),
                    child: Text(
                      seenByLabel!,
                      style: TextStyle(
                        color: PrivetTheme.mist.withValues(alpha: 0.85),
                        fontSize: 10,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );

    // Mobile: whole bubble is the swipe-to-reply target (no text selection).
    final swipeableBubble = PrivetTheme.isCompact(context)
        ? _SwipeReplyHandle(child: bubble)
        : bubble;

    return _SwipeToReply(
      mine: mine,
      enabled: onReply != null &&
          !message.pending &&
          PrivetTheme.isCompact(context),
      onReply: () => onReply?.call(message),
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: mine
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              swipeableBubble,
              if (message.reactions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    alignment: mine ? WrapAlignment.end : WrapAlignment.start,
                    children: message.reactions.map((r) {
                      final mineReact = r.reactedBy(selfId);
                      return Material(
                        color: mineReact
                            ? PrivetTheme.signal.withValues(alpha: 0.18)
                            : PrivetTheme.panelElevated,
                        borderRadius: BorderRadius.circular(999),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(999),
                          onTap: onReact == null
                              ? null
                              : () => onReact!(message, r.emoji),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: mineReact
                                    ? PrivetTheme.signal.withValues(alpha: 0.55)
                                    : PrivetTheme.line,
                              ),
                            ),
                            child: PrivetEmoji(r.emoji, size: 16),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openMenu(
    BuildContext context,
    Offset globalPosition, {
    MediaAttachment? imageTarget,
  }) async {
    if (_reactionMenuOpen) return;
    _reactionMenuOpen = true;

    final size = MediaQuery.sizeOf(context);
    final left = (globalPosition.dx - 8).clamp(8.0, size.width - 288.0);
    final top =
        (globalPosition.dy - 8).clamp(8.0, (size.height - 440.0).clamp(8.0, size.height));
    final hasImage = message.mediaItems.any((e) => e.kind == 'image');
    // Warm the copy cache while the menu is up so "Copy image" is instant —
    // the tap then just writes already-local bytes to the clipboard. Prefer
    // the right-clicked image over the message's first image.
    if (hasImage) {
      final copyUrl =
          imageTarget != null ? _mediaUrl(imageTarget) : _firstImageCopyUrl();
      if (copyUrl != null) unawaited(prefetchImageForCopy(copyUrl));
    }

    String? result;
    try {
      final instant = privetLowResource;
      result = await showGeneralDialog<String>(
        context: context,
        barrierDismissible: true,
        barrierLabel: 'Message actions',
        barrierColor: Colors.black.withValues(alpha: 0.25),
        transitionDuration: privetAnim(const Duration(milliseconds: 140)),
        pageBuilder: (dialogCtx, anim, secondary) {
          var showMore = false;
          return StatefulBuilder(
            builder: (ctx, setLocal) {
              void close([String? value]) {
                final nav = Navigator.of(dialogCtx);
                if (nav.canPop()) nav.pop(value);
              }

              final hasTextToCopy = message.body.trim().isNotEmpty;

              Widget menu = Material(
                          color: PrivetTheme.panelElevated,
                          elevation: privetElevation(16),
                          shadowColor: Colors.black54,
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            width: showMore ? 260 : 232,
                            padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: PrivetTheme.line),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    for (final e in kQuickReactions)
                                      _ReactionChip(
                                        emoji: e,
                                        onTap: () => close('react:$e'),
                                      ),
                                    _ReactionChip(
                                      emoji: '+',
                                      isPlus: true,
                                      onTap: () =>
                                          setLocal(() => showMore = !showMore),
                                    ),
                                    const Spacer(),
                                    InkWell(
                                      borderRadius: BorderRadius.circular(8),
                                      mouseCursor: SystemMouseCursors.click,
                                      onTap: () => close(),
                                      child: Padding(
                                        padding: EdgeInsets.all(4),
                                        child: Icon(
                                          Icons.close_rounded,
                                          size: 16,
                                          color: PrivetTheme.mist,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                if (showMore) ...[
                                  const SizedBox(height: 6),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(10),
                                    child: CompactEmojiPicker(
                                      height: 192,
                                      showDivider: false,
                                      onSelected: (e) => close('react:$e'),
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 6),
                                Divider(height: 1, color: PrivetTheme.line),
                                const SizedBox(height: 2),
                                if (hasImage) ...[
                                  InkWell(
                                    borderRadius: BorderRadius.circular(10),
                                    mouseCursor: SystemMouseCursors.click,
                                    onTap: () => close('copy_image'),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 8,
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.image_outlined,
                                            size: 18,
                                            color: PrivetTheme.signal.withValues(
                                              alpha: 0.95,
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          Text(
                                            'Copy image',
                                            style: GoogleFonts.ibmPlexSans(
                                              fontWeight: FontWeight.w600,
                                              fontSize: 14,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  if (hasTextToCopy)
                                    InkWell(
                                      borderRadius: BorderRadius.circular(10),
                                      mouseCursor: SystemMouseCursors.click,
                                      onTap: () => close('copy_text'),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 8,
                                        ),
                                        child: Row(
                                          children: [
                                            Icon(
                                              Icons.copy_rounded,
                                              size: 18,
                                              color: PrivetTheme.signal
                                                  .withValues(alpha: 0.95),
                                            ),
                                            const SizedBox(width: 10),
                                            Text(
                                              'Copy text',
                                              style: GoogleFonts.ibmPlexSans(
                                                fontWeight: FontWeight.w600,
                                                fontSize: 14,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                ] else if (hasTextToCopy)
                                  InkWell(
                                    borderRadius: BorderRadius.circular(10),
                                    mouseCursor: SystemMouseCursors.click,
                                    onTap: () => close('copy'),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 8,
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.copy_rounded,
                                            size: 18,
                                            color: PrivetTheme.signal.withValues(
                                              alpha: 0.95,
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          Text(
                                            'Copy',
                                            style: GoogleFonts.ibmPlexSans(
                                              fontWeight: FontWeight.w600,
                                              fontSize: 14,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                InkWell(
                                  borderRadius: BorderRadius.circular(10),
                                  mouseCursor: SystemMouseCursors.click,
                                  onTap: () => close('reply'),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 8,
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.reply_rounded,
                                          size: 18,
                                          color: PrivetTheme.signal.withValues(
                                            alpha: 0.95,
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Text(
                                          'Reply',
                                          style: GoogleFonts.ibmPlexSans(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 14,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                if (onForward != null)
                                  InkWell(
                                    borderRadius: BorderRadius.circular(10),
                                    mouseCursor: SystemMouseCursors.click,
                                    onTap: () => close('forward'),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 8,
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.shortcut_rounded,
                                            size: 18,
                                            color: PrivetTheme.signal
                                                .withValues(alpha: 0.95),
                                          ),
                                          const SizedBox(width: 10),
                                          Text(
                                            'Forward',
                                            style: GoogleFonts.ibmPlexSans(
                                              fontWeight: FontWeight.w600,
                                              fontSize: 14,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                if (onAddToTask != null)
                                  InkWell(
                                    borderRadius: BorderRadius.circular(10),
                                    mouseCursor: SystemMouseCursors.click,
                                    onTap: () => close('task'),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 8,
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.playlist_add_check_rounded,
                                            size: 18,
                                            color: PrivetTheme.signal,
                                          ),
                                          const SizedBox(width: 10),
                                          Text(
                                            'Add to task',
                                            style: GoogleFonts.ibmPlexSans(
                                              fontWeight: FontWeight.w600,
                                              fontSize: 14,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                if (onAskAi != null)
                                  Opacity(
                                    opacity: aiActive ? 1 : 0.38,
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(10),
                                      mouseCursor: aiActive
                                          ? SystemMouseCursors.click
                                          : SystemMouseCursors.basic,
                                      onTap: aiActive
                                          ? () => close('ask_ai')
                                          : null,
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 8,
                                        ),
                                        child: Row(
                                          children: [
                                            Icon(
                                              Icons.auto_awesome_rounded,
                                              size: 18,
                                              color: PrivetTheme.signal
                                                  .withValues(alpha: 0.95),
                                            ),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child: Text(
                                                aiActive
                                                    ? 'Ask AI'
                                                    : 'Ask AI (turn on in settings)',
                                                style: GoogleFonts.ibmPlexSans(
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: 14,
                                                  color: aiActive
                                                      ? null
                                                      : PrivetTheme.mist,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                if (mine &&
                                    onEdit != null &&
                                    (message.kind == 'text' ||
                                        message.body.trim().isNotEmpty ||
                                        message.kind == 'image' ||
                                        message.kind == 'video' ||
                                        message.kind == 'file' ||
                                        message.kind == 'album' ||
                                        message.kind == 'audio'))
                                  InkWell(
                                    borderRadius: BorderRadius.circular(10),
                                    mouseCursor: SystemMouseCursors.click,
                                    onTap: () => close('edit'),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 8,
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.edit_outlined,
                                            size: 18,
                                            color: PrivetTheme.signal
                                                .withValues(alpha: 0.95),
                                          ),
                                          const SizedBox(width: 10),
                                          Text(
                                            'Edit',
                                            style: GoogleFonts.ibmPlexSans(
                                              fontWeight: FontWeight.w600,
                                              fontSize: 14,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                if (mine && onDelete != null)
                                  InkWell(
                                    borderRadius: BorderRadius.circular(10),
                                    mouseCursor: SystemMouseCursors.click,
                                    onTap: () => close('delete'),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 8,
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.delete_outline_rounded,
                                            size: 18,
                                            color: PrivetTheme.danger,
                                          ),
                                          const SizedBox(width: 10),
                                          Text(
                                            'Delete',
                                            style: GoogleFonts.ibmPlexSans(
                                              fontWeight: FontWeight.w600,
                                              fontSize: 14,
                                              color: PrivetTheme.danger,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        );
              if (!instant) {
                menu = FadeTransition(
                  opacity: anim,
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 0.94, end: 1).animate(
                      CurvedAnimation(
                        parent: anim,
                        curve: Curves.easeOutCubic,
                      ),
                    ),
                    alignment: Alignment.topLeft,
                    child: menu,
                  ),
                );
              }
              return Stack(
                children: [
                  // Explicit dismiss layer — barrier alone is unreliable on web.
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => close(),
                      onSecondaryTap: () => close(),
                    ),
                  ),
                  Positioned(
                    left: left,
                    top: top,
                    child: menu,
                  ),
                ],
              );
            },
          );
        },
      );
    } finally {
      _reactionMenuOpen = false;
    }

    if (!context.mounted || result == null) return;
    // When the menu was opened by right-clicking one image in a multi-image
    // message, the actions that reference media apply to that image only.
    final scoped = (imageTarget != null && imageTarget.kind == 'image')
        ? message.copyWith(kind: 'image', attachments: [imageTarget])
        : message;
    if (result == 'copy_image') {
      final image = imageTarget ?? _firstImage();
      if (image != null) {
        final ok = await copyImageToClipboard(
          _mediaUrl(image),
          filename: image.fileName ?? 'image',
        );
        if (!ok && context.mounted) {
          _showImageCopyError(context);
        }
      }
      return;
    }
    if (result == 'copy_text') {
      final text = message.body.trim();
      if (text.isNotEmpty) {
        await AppClipboard.setText(text);
      }
      return;
    }
    if (result == 'copy') {
      final text = message.body.trim();
      if (text.isNotEmpty) {
        await AppClipboard.setText(text);
      }
      return;
    }
    if (result == 'reply') {
      onReply?.call(scoped);
      return;
    }
    if (result == 'forward') {
      onForward?.call(scoped);
      return;
    }
    if (result == 'task') {
      onAddToTask?.call(scoped);
      return;
    }
    if (result == 'ask_ai') {
      onAskAi?.call(scoped);
      return;
    }
    if (result == 'edit') {
      onEdit?.call(message);
      return;
    }
    if (result == 'delete') {
      onDelete?.call(message);
      return;
    }
    if (result.startsWith('react:')) {
      onReact?.call(message, result.substring(6));
    }
  }

  Widget _body(String mediaBase) {
    final items = message.mediaItems;
    void replyWithSelection(String selected) =>
        onReply?.call(message, selectedText: selected);
    void forwardWithSelection(String selected) =>
        onForward?.call(message, selectedText: selected);
    void formatSelection(TextSelection sel, TextFormat f) =>
        onFormatMessage?.call(sel, f);

    if (items.length > 1 || message.kind == 'album') {
      return _AlbumBody(
        items: items,
        mediaBase: mediaBase,
        caption: message.body,
        pending: message.pending,
        fontScale: fontScale,
        defaultFont: defaultFontFamily,
        onSetDefaultFont: onSetDefaultFont,
        onReplySelection: onReply == null ? null : replyWithSelection,
        onForwardSelection: onForward == null ? null : forwardWithSelection,
        onFormatSelection: onFormatMessage == null ? null : formatSelection,
      );
    }
    if (items.length == 1) {
      return _SingleMediaBody(
        item: items.first,
        mediaBase: mediaBase,
        caption: message.body,
        pending: message.pending,
        voiceLabel: message.kind == 'voice',
        fontScale: fontScale,
        defaultFont: defaultFontFamily,
        onSetDefaultFont: onSetDefaultFont,
        onReplySelection: onReply == null ? null : replyWithSelection,
        onForwardSelection: onForward == null ? null : forwardWithSelection,
        onFormatSelection: onFormatMessage == null ? null : formatSelection,
      );
    }
    final onlyEmoji = _emojiOnlyPayload(message.body);
    if (onlyEmoji != null) {
      return _BigEmoji(text: onlyEmoji, fontScale: fontScale);
    }
    return SelectableMarkupText(
      text: message.body,
      fontScale: fontScale,
      defaultFont: defaultFontFamily,
      onSetDefaultFont: onSetDefaultFont,
      onReply: onReply == null ? null : replyWithSelection,
      onForward: onForward == null ? null : forwardWithSelection,
      onFormat: onFormatMessage == null ? null : formatSelection,
      hoverStyle: TextStyle(
        height: 1.35,
        fontSize: 15 * fontScale,
        color: PrivetTheme.signal,
      ),
      toolbarSuppressed: () => _reactionMenuOpen,
      dragging: () => privetBubbleDragging,
    );
  }

  /// Full URL of the first image attachment, or null when the message has no
  /// image. Shared by the Copy image menu action and copy-cache prefetch.
  String? _firstImageCopyUrl() {
    final image = _firstImage();
    return image == null ? null : _mediaUrl(image);
  }

  /// First image attachment of this message, or null.
  MediaAttachment? _firstImage() {
    for (final e in message.mediaItems) {
      if (e.kind == 'image') return e;
    }
    return null;
  }

  /// Absolute URL for a media item (server paths are relative to [mediaBase]).
  String _mediaUrl(MediaAttachment e) {
    final path = e.mediaUrl;
    return path.startsWith('http') ? path : '$mediaBase$path';
  }

  void _showImageCopyError(BuildContext context) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Could not copy image — use Download'),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }
}

/// Centered Teams-style call history chip (not a message bubble).
class _CallHistoryChip extends StatelessWidget {
  const _CallHistoryChip({required this.message});

  final ChatMessage message;

  IconData _iconFor(CallHistoryPayload? payload) {
    final mode = payload?.mode ?? 'video';
    final outcome = payload?.outcome ?? 'completed';
    if (outcome == 'missed' || outcome == 'declined' || outcome == 'canceled') {
      switch (mode) {
        case 'audio':
          return Icons.call_missed_outgoing_rounded;
        case 'screen':
          return Icons.screen_share_outlined;
        case 'control':
          return Icons.mouse_outlined;
        default:
          return Icons.missed_video_call_outlined;
      }
    }
    switch (mode) {
      case 'audio':
        return Icons.call_rounded;
      case 'screen':
        return Icons.screen_share_rounded;
      case 'control':
        return Icons.mouse_rounded;
      default:
        return Icons.videocam_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final payload = CallHistoryPayload.tryParse(message.body);
    final label = payload?.label ?? CallHistoryPayload.preview(message.body);
    final muted = payload != null &&
        (payload.outcome == 'missed' ||
            payload.outcome == 'declined' ||
            payload.outcome == 'canceled');
    // paper = primary text (light on dark / dark on light). Never use ink —
    // that is the app background and vanishes on dark theme.
    final textColor = muted ? PrivetTheme.mist : PrivetTheme.paper;
    final iconColor = muted
        ? PrivetTheme.mist
        : PrivetTheme.signal.withValues(alpha: 0.95);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: PrivetTheme.panelElevated,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: PrivetTheme.line),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_iconFor(payload), size: 15, color: iconColor),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  label,
                  style: GoogleFonts.ibmPlexSans(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: textColor,
                    letterSpacing: 0.1,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Centered clickable pill for server-authored task changes (kind
/// 'task_event'): "Alex added subtask “Chapter 1” to “Book”". Tapping it opens
/// the Tasks pane and reveals the affected task.
class _TaskEventChip extends StatelessWidget {
  const _TaskEventChip({required this.message, this.onTap});

  final ChatMessage message;
  final VoidCallback? onTap;

  (IconData, Color) _look(TaskEventPayload p) {
    switch (p.action) {
      case 'created':
      case 'subtask':
        return (Icons.add_circle_outline_rounded, PrivetTheme.signal);
      case 'status':
        return (
          p.to == 'Done'
              ? Icons.check_circle_outline_rounded
              : Icons.swap_horiz_rounded,
          p.to == 'Done'
              ? PrivetTheme.signal
              : PrivetTheme.mist,
        );
      case 'priority':
        return (
          Icons.flag_outlined,
          p.to == 'High' || p.to == 'Highest'
              ? PrivetTheme.danger
              : PrivetTheme.mist,
        );
      case 'assigned':
        return (Icons.person_add_alt_1_rounded, PrivetTheme.signal);
      case 'deleted':
        return (Icons.delete_outline_rounded, PrivetTheme.danger);
      default:
        return (Icons.history_rounded, PrivetTheme.mist);
    }
  }

  @override
  Widget build(BuildContext context) {
    final payload = TaskEventPayload.tryParse(message.body);
    final label = payload?.label ?? TaskEventPayload.preview(message.body);
    final (icon, color) = payload == null
        ? (Icons.history_rounded, PrivetTheme.mist)
        : _look(payload);
    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
      decoration: BoxDecoration(
        color: PrivetTheme.panelElevated,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              label,
              style: GoogleFonts.ibmPlexSans(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: PrivetTheme.paper,
                height: 1.25,
              ),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 6),
            Icon(
              Icons.open_in_new_rounded,
              size: 12,
              color: PrivetTheme.mist.withValues(alpha: 0.7),
            ),
          ],
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: onTap == null
            ? pill
            : MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Tooltip(
                  message: 'Open in Tasks',
                  waitDuration: const Duration(milliseconds: 400),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onTap,
                    child: pill,
                  ),
                ),
              ),
      ),
    );
  }
}

/// Returns the trimmed body when it is 1–3 emoji graphemes and nothing else.
String? _emojiOnlyPayload(String raw) {
  // Bodies can wrap the emoji in markup — e.g. `applyDefaultMessageFont` bakes
  // `[font=…]…[/font]` around the text — so detect on the visible plain text,
  // not the raw tag soup, or a lone emoji degrades to inline size.
  final text = markupToPlain(raw).trim();
  if (text.isEmpty || text.length > 24) return null;
  final chars = text.characters;
  if (chars.isEmpty || chars.length > 3) return null;
  // Reject plain latin/digit/punctuation-heavy text. A grapheme that mixes in
  // a letter/digit is still a single emoji only when it is a keycap (e.g. 1️⃣).
  for (final g in chars) {
    if (RegExp(r'[A-Za-z0-9]').hasMatch(g) && !g.contains('\u20e3')) {
      return null;
    }
  }
  return text;
}

class _BigEmoji extends StatefulWidget {
  const _BigEmoji({required this.text, this.fontScale = 1.0});

  final String text;
  final double fontScale;

  @override
  State<_BigEmoji> createState() => _BigEmojiState();
}

class _BigEmojiState extends State<_BigEmoji>
    with SingleTickerProviderStateMixin {
  AnimationController? _ctrl;
  Animation<double>? _scale;

  @override
  void initState() {
    super.initState();
    privetLowResourceListenable.addListener(_sync);
    _sync();
  }

  @override
  void dispose() {
    privetLowResourceListenable.removeListener(_sync);
    _ctrl?.dispose();
    super.dispose();
  }

  void _sync() {
    if (privetLowResource) {
      if (_ctrl != null) {
        _ctrl!.dispose();
        _ctrl = null;
        _scale = null;
        if (mounted) setState(() {});
      }
      return;
    }
    if (_ctrl != null) return;
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..forward();
    _scale = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.6, end: 1.18), weight: 45),
      TweenSequenceItem(tween: Tween(begin: 1.18, end: 0.95), weight: 25),
      TweenSequenceItem(tween: Tween(begin: 0.95, end: 1.0), weight: 30),
    ]).animate(CurvedAnimation(parent: _ctrl!, curve: Curves.easeOutCubic));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // One emoji is the hero of the message — render it extra large so it reads
    // as a big animated sticker rather than inline text. 2–3 stay medium.
    final base = widget.text.characters.length == 1 ? 80.0 : 48.0;
    final size = base * widget.fontScale;
    final scale = _scale;
    if (privetLowResource || scale == null) {
      return PrivetEmoji(widget.text, size: size, animate: false);
    }
    return ScaleTransition(
      scale: scale,
      child: PrivetEmoji(widget.text, size: size),
    );
  }
}

class _AlbumBody extends StatelessWidget {
  const _AlbumBody({
    required this.items,
    required this.mediaBase,
    required this.caption,
    this.pending = false,
    this.fontScale = 1.0,
    this.defaultFont = '',
    this.onSetDefaultFont,
    this.onReplySelection,
    this.onForwardSelection,
    this.onFormatSelection,
  });

  final List<MediaAttachment> items;
  final String mediaBase;
  final String caption;

  /// Message is still being sent — the bubble menu (and right-click image
  /// targeting) is disabled while it is.
  final bool pending;
  final double fontScale;
  final String defaultFont;
  final ValueChanged<String>? onSetDefaultFont;
  final ValueChanged<String>? onReplySelection;
  final ValueChanged<String>? onForwardSelection;
  final void Function(TextSelection selection, TextFormat format)?
      onFormatSelection;

  String _url(MediaAttachment item) {
    final path = item.mediaUrl;
    if (path.isEmpty) return '';
    if (path.startsWith('http')) return path;
    return '$mediaBase$path';
  }

  String _downloadName(MediaAttachment item) {
    if (item.fileName != null && item.fileName!.isNotEmpty) {
      return item.fileName!;
    }
    return switch (item.kind) {
      'image' => 'image.jpg',
      'video' => 'video.mp4',
      'audio' || 'voice' => 'audio.webm',
      _ => 'attachment',
    };
  }

  @override
  Widget build(BuildContext context) {
    final tileW = items.length == 1 ? 260.0 : 124.0;
    final tileH = items.every((e) => e.kind == 'image' || e.kind == 'video')
        ? (items.length == 1 ? 160.0 : 110.0)
        : 72.0;

    final imageItems = [
      for (final item in items)
        if (item.kind == 'image') item,
    ];
    final galleryUrls = [for (final item in imageItems) _url(item)];
    final galleryFilenames = [
      for (final item in imageItems) _downloadName(item),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (var i = 0; i < items.length; i++)
              Builder(
                builder: (context) {
                  final item = items[i];
                  final galleryIndex = item.kind == 'image'
                      ? imageItems.indexOf(item)
                      : 0;
                  return SizedBox(
                    width: items.length == 1 ? 260 : tileW,
                    child: _AttachmentTile(
                      item: item,
                      url: _url(item),
                      width: items.length == 1 ? 260 : tileW,
                      height: item.kind == 'video' && items.length > 1
                          ? 140
                          : tileH,
                      compact: items.length > 1 && item.kind != 'video',
                      pending: pending,
                      galleryUrls: galleryUrls,
                      galleryFilenames: galleryFilenames,
                      galleryIndex: galleryIndex < 0 ? 0 : galleryIndex,
                    ),
                  );
                },
              ),
          ],
        ),
        if (caption.isNotEmpty) ...[
          const SizedBox(height: 8),
          SelectableMarkupText(
            text: caption,
            fontScale: fontScale,
            defaultFont: defaultFont,
            onSetDefaultFont: onSetDefaultFont,
            onReply: onReplySelection,
            onForward: onForwardSelection,
            onFormat: onFormatSelection,
            hoverStyle: TextStyle(
              height: 1.35,
              fontSize: 15 * fontScale,
              color: PrivetTheme.signal,
            ),
            toolbarSuppressed: () => _reactionMenuOpen,
            dragging: () => privetBubbleDragging,
          ),
        ],
      ],
    );
  }
}

class _SingleMediaBody extends StatelessWidget {
  const _SingleMediaBody({
    required this.item,
    required this.mediaBase,
    required this.caption,
    required this.voiceLabel,
    this.pending = false,
    this.fontScale = 1.0,
    this.defaultFont = '',
    this.onSetDefaultFont,
    this.onReplySelection,
    this.onForwardSelection,
    this.onFormatSelection,
  });

  final MediaAttachment item;
  final String mediaBase;
  final String caption;
  final bool voiceLabel;

  /// Message is still being sent — the bubble menu (and right-click image
  /// targeting) is disabled while it is.
  final bool pending;
  final double fontScale;
  final String defaultFont;
  final ValueChanged<String>? onSetDefaultFont;
  final ValueChanged<String>? onReplySelection;
  final ValueChanged<String>? onForwardSelection;
  final void Function(TextSelection selection, TextFormat format)?
      onFormatSelection;

  String get _url {
    final path = item.mediaUrl;
    if (path.isEmpty) return '';
    if (path.startsWith('http')) return path;
    return '$mediaBase$path';
  }

  String get _downloadName {
    if (item.fileName != null && item.fileName!.isNotEmpty) {
      return item.fileName!;
    }
    return switch (item.kind) {
      'image' => 'image.jpg',
      'video' => 'video.mp4',
      'audio' || 'voice' => 'audio.webm',
      _ => 'attachment',
    };
  }

  Widget _captionText() => SelectableMarkupText(
    text: caption,
    fontScale: fontScale,
    defaultFont: defaultFont,
    onSetDefaultFont: onSetDefaultFont,
    onReply: onReplySelection,
    onForward: onForwardSelection,
    onFormat: onFormatSelection,
    hoverStyle: TextStyle(
      height: 1.35,
      fontSize: 15 * fontScale,
      color: PrivetTheme.signal,
    ),
    toolbarSuppressed: () => _reactionMenuOpen,
    dragging: () => privetBubbleDragging,
  );

  @override
  Widget build(BuildContext context) {
    switch (item.kind) {
      case 'image':
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ExcludeSemantics: on Flutter web, Image+Download otherwise merge
            // into one oversized a11y hit target covering the whole green bubble.
            Semantics(
              button: true,
              label: 'View image',
              child: ExcludeSemantics(
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  hitTestBehavior: HitTestBehavior.opaque,
                  // #region agent log
                  onEnter: (_) {
                    agentDebugLog(
                      hypothesisId: 'H5',
                      location: 'message_bubble.dart:_SingleMediaBody(image)',
                      message: 'hover image',
                      data: {
                        'selectActive': privetWebSelectHoverActive(),
                        'bodyCursor': privetWebBodyCursor(),
                      },
                    );
                  },
                  // #endregion
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (event) {
                      // Right-click on a chat image: the bubble menu opens and
                      // its actions (Copy image / Reply / Forward / Add to task)
                      // target THIS image.
                      if (event.buttons == kSecondaryMouseButton) {
                        if (!pending && item.kind == 'image') {
                          _imageMenuTarget = item;
                        } else {
                          _imageMenuTarget = null;
                        }
                      }
                    },
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _url.isEmpty
                          ? null
                          : () => showImageLightbox(
                                context,
                                urls: [_url],
                                filenames: [_downloadName],
                              ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        // Morph the loading "ready box" (fixed height) into the
                        // image's natural aspect instead of popping.
                        child: AnimatedSize(
                          duration: privetAnim(
                            const Duration(milliseconds: 220),
                          ),
                          curve: Curves.easeOutCubic,
                          alignment: Alignment.topCenter,
                          child: _ChatImage(
                            url: _url,
                            fit: BoxFit.cover,
                            width: 260,
                            placeholderHeight: 180,
                            cacheWidth: ImageDecodeCaps.cacheWidth(
                              260,
                              dpr: MediaQuery.devicePixelRatioOf(context),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (_url.isNotEmpty) ...[
              const SizedBox(height: 4),
              _DownloadChip(url: _url, filename: _downloadName),
            ],
            if (caption.isNotEmpty) ...[
              const SizedBox(height: 6),
              _captionText(),
            ],
          ],
        );
      case 'video':
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(child: InlineVideoPlayer(url: _url)),
            const SizedBox(height: 4),
            _DownloadChip(url: _url, filename: _downloadName),
            if (caption.isNotEmpty) ...[
              const SizedBox(height: 6),
              _captionText(),
            ],
          ],
        );
      case 'audio':
      case 'voice':
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ExcludeSemantics(
                  child: VoicePlayer(
                    url: _url,
                    label: voiceLabel || item.kind == 'voice'
                        ? 'Voice message'
                        : (item.fileName ?? 'Audio'),
                  ),
                ),
                const SizedBox(width: 4),
                _DownloadChip(url: _url, filename: _downloadName),
              ],
            ),
            if (caption.isNotEmpty) ...[
              const SizedBox(height: 6),
              _captionText(),
            ],
          ],
        );
      case 'file':
      default:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MouseRegion(
              cursor: SystemMouseCursors.click,
              hitTestBehavior: HitTestBehavior.opaque,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () =>
                    _downloadMedia(context, _url, filename: _downloadName),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ExcludeSemantics(
                      child: Icon(
                        Icons.attach_file_rounded,
                        color: PrivetTheme.signal,
                      ),
                    ),
                    const SizedBox(width: 8),
                    ExcludeSemantics(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 200),
                        child: Text(
                          item.fileName ?? caption,
                          style: const TextStyle(fontSize: 14, height: 1.3),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    _DownloadChip(url: _url, filename: _downloadName),
                  ],
                ),
              ),
            ),
            if (caption.isNotEmpty && item.kind != 'file') ...[
              const SizedBox(height: 6),
              _captionText(),
            ],
            if (caption.isNotEmpty &&
                item.kind == 'file' &&
                caption != (item.fileName ?? '')) ...[
              const SizedBox(height: 6),
              _captionText(),
            ],
          ],
        );
    }
  }
}

class _AttachmentTile extends StatelessWidget {
  const _AttachmentTile({
    required this.item,
    required this.url,
    required this.width,
    required this.height,
    required this.compact,
    this.pending = false,
    this.galleryUrls = const [],
    this.galleryFilenames = const [],
    this.galleryIndex = 0,
  });

  final MediaAttachment item;
  final String url;
  final double width;
  final double height;
  final bool compact;

  /// Message is still being sent — the bubble menu (and right-click image
  /// targeting) is disabled while it is.
  final bool pending;
  final List<String> galleryUrls;
  final List<String?> galleryFilenames;
  final int galleryIndex;

  String get _downloadName {
    if (item.fileName != null && item.fileName!.isNotEmpty) {
      return item.fileName!;
    }
    return switch (item.kind) {
      'image' => 'image.jpg',
      'video' => 'video.mp4',
      'audio' || 'voice' => 'audio.webm',
      _ => 'attachment',
    };
  }

  Widget _clickableFileTile({
    required BuildContext context,
    required IconData icon,
    required String label,
  }) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      hitTestBehavior: HitTestBehavior.opaque,
      // #region agent log
      onEnter: (_) {
        agentDebugLog(
          hypothesisId: 'H5',
          location: 'message_bubble.dart:_AttachmentTile(file tile)',
          message: 'hover file tile',
          data: {
            'selectActive': privetWebSelectHoverActive(),
            'bodyCursor': privetWebBodyCursor(),
          },
        );
      },
      // #endregion
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _downloadMedia(context, url, filename: _downloadName),
        child: ColoredBox(
          color: PrivetTheme.ink,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Icon(icon, color: PrivetTheme.signal),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget content;
    switch (item.kind) {
      case 'image':
        content = MouseRegion(
          cursor: SystemMouseCursors.click,
          hitTestBehavior: HitTestBehavior.opaque,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (event) {
              // Right-click a tile in a multi-image album: the bubble menu
              // opens and its actions (Copy image / Reply / Forward / Add to
              // task) target THIS image, not the message's first image.
              if (event.buttons == kSecondaryMouseButton) {
                if (!pending && item.kind == 'image') {
                  _imageMenuTarget = item;
                } else {
                  _imageMenuTarget = null;
                }
              }
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: url.isEmpty
                  ? null
                  : () {
                      final urls =
                          galleryUrls.isNotEmpty ? galleryUrls : [url];
                      final names = galleryFilenames.isNotEmpty
                          ? galleryFilenames
                          : <String?>[_downloadName];
                      showImageLightbox(
                        context,
                        urls: urls,
                        initialIndex: galleryIndex.clamp(0, urls.length - 1),
                        filenames: names,
                      );
                    },
              child: _ChatImage(
                url: url,
                fit: BoxFit.cover,
                width: width,
                height: height,
                cacheWidth: ImageDecodeCaps.cacheWidth(
                  width,
                  dpr: MediaQuery.devicePixelRatioOf(context),
                ),
              ),
            ),
          ),
        );
      case 'video':
        content = InlineVideoPlayer(url: url, width: width, height: height);
      case 'audio':
      case 'voice':
        content = _clickableFileTile(
          context: context,
          icon: Icons.audiotrack_rounded,
          label: item.fileName ?? 'Audio',
        );
      default:
        content = _clickableFileTile(
          context: context,
          icon: Icons.insert_drive_file_rounded,
          label: item.fileName ?? 'File',
        );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(
          child: SizedBox(
            width: width,
            height: height,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: content,
            ),
          ),
        ),
        if (url.isNotEmpty) ...[
          const SizedBox(height: 2),
          _DownloadChip(url: url, filename: _downloadName),
        ],
      ],
    );
  }
}

/// A chat image with a Teams-style "ready box": while bytes are still being
/// uploaded / fetched it reserves a fixed box with an animated shimmer sweep
/// (and a muted image glyph), then fades the decoded frame in instead of
/// popping it. An empty [url] (the optimistic pre-upload bubble) keeps the
/// ready box animating until the real URL replaces it.
class _ChatImage extends StatefulWidget {
  const _ChatImage({
    required this.url,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.cacheWidth,
    this.placeholderHeight = 180,
  });

  final String url;
  final BoxFit fit;
  final double? width;
  final double? height;
  final int? cacheWidth;

  /// Height the ready box reserves while no image size is known yet (single
  /// images size to their natural aspect once decoded).
  final double placeholderHeight;

  @override
  State<_ChatImage> createState() => _ChatImageState();
}

class _ChatImageState extends State<_ChatImage>
    with SingleTickerProviderStateMixin {
  /// Fade-in after the first decoded frame.
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: privetAnim(const Duration(milliseconds: 260)),
  );

  /// Drives the placeholder shimmer sweep.
  late final AnimationController _shimmer = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );

  bool _frameReady = false;

  @override
  void initState() {
    super.initState();
    if (!privetLowResource) _shimmer.repeat();
  }

  @override
  void didUpdateWidget(covariant _ChatImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _frameReady = false;
      _fade.value = 0;
      if (!privetLowResource && !_shimmer.isAnimating) _shimmer.repeat();
    }
  }

  @override
  void dispose() {
    _fade.dispose();
    _shimmer.dispose();
    super.dispose();
  }

  void _markLoaded() {
    if (_frameReady) return;
    _frameReady = true;
    _shimmer.stop();
    _fade.forward(from: 0);
    if (widget.url.isNotEmpty) unawaited(prefetchImageForCopy(widget.url));
  }

  Widget _readyBox() {
    return SizedBox(
      width: widget.width,
      height: widget.height ?? widget.placeholderHeight,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: _ShimmerBox(
          animation: _shimmer,
          child: Center(
            child: Icon(
              Icons.image_outlined,
              size: 30,
              color: PrivetTheme.paper.withValues(alpha: 0.38),
            ),
          ),
        ),
      ),
    );
  }

  Widget _errorBox() {
    return SizedBox(
      width: widget.width,
      height: widget.height ?? widget.placeholderHeight,
      child: ColoredBox(
        color: PrivetTheme.ink,
        child: Center(
          child: Icon(
            Icons.broken_image_outlined,
            color: PrivetTheme.mist.withValues(alpha: 0.8),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.url.isEmpty) {
      // Optimistic pre-upload bubble — no URL yet, keep the ready box going.
      return _readyBox();
    }
    // Prefer the on-device cache (instant when already seen); the network
    // path warms the cache in the background via the widget.
    return CachedMediaImage(
      url: widget.url,
      fit: widget.fit,
      width: widget.width,
      height: widget.height,
      cacheWidth: widget.cacheWidth,
      placeholderHeight: widget.placeholderHeight,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded) {
          _frameReady = true;
          _shimmer.stop();
          return child;
        }
        if (frame != null) {
          if (!_frameReady) _markLoaded();
          return FadeTransition(opacity: _fade, child: child);
        }
        return _readyBox();
      },
      errorBuilder: (_, error, stack) => _errorBox(),
    );
  }
}

/// Animated "ready box" surface: a soft diagonal highlight sweeping across
/// the fill, Teams-style. Static flat fill in low-resource mode.
class _ShimmerBox extends StatelessWidget {
  const _ShimmerBox({required this.animation, required this.child});

  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (privetLowResource) {
      return ColoredBox(color: _base(), child: child);
    }
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) => CustomPaint(
        painter: _ShimmerPainter(
          slide: animation.value,
          base: _base(),
          highlight: PrivetTheme.isLight
              ? Colors.black.withValues(alpha: 0.05)
              : Colors.white.withValues(alpha: 0.08),
        ),
        child: child,
      ),
    );
  }

  Color _base() => PrivetTheme.panelElevated.withValues(alpha: 0.65);
}

class _ShimmerPainter extends CustomPainter {
  const _ShimmerPainter({
    required this.slide,
    required this.base,
    required this.highlight,
  });

  final double slide;
  final Color base;
  final Color highlight;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = base);
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [base, highlight, base],
        stops: const [0.35, 0.5, 0.65],
        transform: _SlidingGradientTransform(slidePercent: slide),
      ).createShader(rect);
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(covariant _ShimmerPainter oldDelegate) =>
      oldDelegate.slide != slide ||
      oldDelegate.base != base ||
      oldDelegate.highlight != highlight;
}

/// Slides a [LinearGradient] horizontally so the shimmer highlight sweeps
/// across the ready box. Based on the standard Flutter docs shimmer recipe.
class _SlidingGradientTransform extends GradientTransform {
  const _SlidingGradientTransform({required this.slidePercent});

  final double slidePercent;

  @override
  Matrix4? transform(Rect bounds, {ui.TextDirection? textDirection}) {
    return Matrix4.translationValues(
      bounds.width * (slidePercent * 2 - 1) * 1.5,
      0,
      0,
    );
  }
}

/// Tight download control. Kept as its own Semantics node so Flutter web
/// does not merge it with the media above (that made the whole green bubble
/// act as Download).
class _DownloadChip extends StatelessWidget {
  const _DownloadChip({required this.url, required this.filename});

  final String url;
  final String filename;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          container: true,
          label: 'Download $filename',
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => _downloadMedia(context, url, filename: filename),
              mouseCursor: SystemMouseCursors.click,
              borderRadius: BorderRadius.circular(6),
              hoverColor: PrivetTheme.signal.withValues(alpha: 0.14),
              splashColor: PrivetTheme.signal.withValues(alpha: 0.22),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.download_rounded,
                      size: 15,
                      color: PrivetTheme.signal,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Download',
                      style: TextStyle(
                        fontSize: 11,
                        color: PrivetTheme.signal.withValues(alpha: 0.95),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ReactionChip extends StatelessWidget {
  const _ReactionChip({
    required this.emoji,
    required this.onTap,
    this.isPlus = false,
  });

  final String emoji;
  final VoidCallback onTap;
  final bool isPlus;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 2),
      child: Material(
        color: PrivetTheme.ink.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          mouseCursor: SystemMouseCursors.click,
          hoverColor: PrivetTheme.paper.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 32,
            height: 32,
            child: Center(
              child: isPlus
                  ? Icon(Icons.add_rounded, size: 20, color: PrivetTheme.mist)
                  : PrivetEmoji(emoji, size: 26),
            ),
          ),
        ),
      ),
    );
  }
}

/// Telegram-style swipe-to-reply on compact/mobile. The whole bubble is the
/// drag target (no message text selection on mobile). Others swipe right;
/// own swipe left.
///
/// Drag offset lives in a [ValueNotifier] so per-frame updates only rebuild
/// the transform/arrow layer — not the message contents underneath. That
/// matters on Linux/GTK where full bubble rebuilds during drag starve frames.
class _SwipeToReply extends StatefulWidget {
  const _SwipeToReply({
    required this.child,
    required this.mine,
    required this.enabled,
    required this.onReply,
  });

  final Widget child;
  final bool mine;
  final bool enabled;
  final VoidCallback onReply;

  @override
  State<_SwipeToReply> createState() => _SwipeToReplyState();

  static _SwipeToReplyState? maybeOf(BuildContext context) {
    return context.findAncestorStateOfType<_SwipeToReplyState>();
  }
}

class _SwipeToReplyState extends State<_SwipeToReply> {
  static const _trigger = 48.0;
  static const _maxDrag = 84.0;
  final ValueNotifier<double> _dx = ValueNotifier(0);
  bool _dragging = false;
  bool _fired = false;

  bool get dragging => _dragging;

  void onDragStart() {
    if (!widget.enabled || _dragging) return;
    privetBubbleDragging = true;
    setState(() {
      _dragging = true;
      _fired = false;
    });
  }

  void onDragUpdate(double deltaDx) {
    if (!_dragging) return;
    var next = _dx.value + deltaDx;
    next = widget.mine ? next.clamp(-_maxDrag, 0.0) : next.clamp(0.0, _maxDrag);
    if (!_fired && next.abs() >= _trigger) {
      _fired = true;
      HapticFeedback.selectionClick();
    }
    _dx.value = next;
  }

  void onDragEnd() {
    if (!_dragging) return;
    final fire = _dx.value.abs() >= _trigger;
    privetBubbleDragging = false;
    _dx.value = 0;
    setState(() => _dragging = false);
    if (fire) widget.onReply();
  }

  void onDragCancel() {
    if (!_dragging) return;
    privetBubbleDragging = false;
    _dx.value = 0;
    setState(() => _dragging = false);
  }

  @override
  void dispose() {
    if (_dragging) privetBubbleDragging = false;
    _dx.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return Stack(
      children: [
        Positioned.fill(
          child: ValueListenableBuilder<double>(
            valueListenable: _dx,
            builder: (context, dx, _) {
              final progress = (dx.abs() / _trigger).clamp(0.0, 1.0);
              return Align(
                alignment: widget.mine
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Opacity(
                    opacity: progress,
                    child: Transform.scale(
                      scale: 0.7 + 0.3 * progress,
                      child: Icon(
                        Icons.reply_rounded,
                        size: 22,
                        color: progress >= 1
                            ? PrivetTheme.signal
                            : PrivetTheme.mist,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        // ValueListenableBuilder keeps [child] stable across drag frames so
        // the bubble tree is not rebuilt/laid out on every pointer move.
        ValueListenableBuilder<double>(
          valueListenable: _dx,
          builder: (context, dx, child) {
            return Transform.translate(offset: Offset(dx, 0), child: child);
          },
          child: widget.child,
        ),
      ],
    );
  }
}

/// Whole-bubble drag-to-reply hit target (compact/mobile only).
///
/// Uses a custom horizontal recognizer so a slightly diagonal finger still
/// wins against the chat ListView's vertical scroll.
class _SwipeReplyHandle extends StatefulWidget {
  const _SwipeReplyHandle({required this.child});

  final Widget child;

  @override
  State<_SwipeReplyHandle> createState() => _SwipeReplyHandleState();
}

class _SwipeReplyHandleState extends State<_SwipeReplyHandle> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final swipe = _SwipeToReply.maybeOf(context);
    if (swipe == null || !swipe.widget.enabled) {
      return widget.child;
    }

    final grabbing = _pressed || swipe.dragging;
    return MouseRegion(
      cursor: grabbing ? SystemMouseCursors.grabbing : SystemMouseCursors.grab,
      child: RawGestureDetector(
        behavior: HitTestBehavior.translucent,
        gestures: <Type, GestureRecognizerFactory>{
          HorizontalDragGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<
                  HorizontalDragGestureRecognizer>(
            () {
              // Beat the ListView's ~18px vertical slop: claim horizontal
              // reply swipes after a shorter travel so diagonal wobble still
              // starts a drag instead of canceling into scroll.
              final recognizer =
                  HorizontalDragGestureRecognizer(debugOwner: this);
              recognizer.gestureSettings =
                  const DeviceGestureSettings(touchSlop: 8);
              return recognizer;
            },
            (instance) {
              instance.onStart = (_) {
                setState(() => _pressed = true);
                swipe.onDragStart();
              };
              instance.onUpdate = (d) {
                swipe.onDragUpdate(d.delta.dx);
              };
              instance.onEnd = (_) {
                setState(() => _pressed = false);
                swipe.onDragEnd();
              };
              instance.onCancel = () {
                setState(() => _pressed = false);
                swipe.onDragCancel();
              };
            },
          ),
        },
        child: widget.child,
      ),
    );
  }
}

/// Compact italic status chip used for edited / forwarded / added-to-task notes.
class _MessageStatusNote extends StatelessWidget {
  const _MessageStatusNote({
    required this.icon,
    required this.label,
    this.compact = false,
    this.prominent = false,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final bool compact;
  final bool prominent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final alpha = compact ? 0.75 : 0.9;
    final size = compact ? 10.0 : (prominent ? 14.0 : 12.0);
    final fontSize = compact ? 10.0 : (prominent ? 11.0 : 10.5);
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: size,
          color: PrivetTheme.mist.withValues(alpha: alpha),
        ),
        SizedBox(width: compact ? 3 : 4),
        Flexible(
          child: Text(
            label,
            style: GoogleFonts.ibmPlexSans(
              fontSize: fontSize,
              fontStyle: FontStyle.italic,
              color: PrivetTheme.mist.withValues(alpha: alpha),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
    if (onTap == null) return row;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: row,
      ),
    );
  }
}

class _ReplyQuote extends StatelessWidget {
  const _ReplyQuote({
    required this.reply,
    this.fontScale = 1.0,
    this.defaultFont = '',
    this.mediaBase = '',
    this.onTap,
  });

  final ReplyPreview reply;
  final double fontScale;
  final String defaultFont;

  /// Base URL prefix for the reply thumbnail (image media is stored relative).
  final String mediaBase;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final name = reply.senderHandle.isNotEmpty
        ? '@${reply.senderHandle}'
        : reply.senderName;
    final thumbs = reply.allThumbnails;
    final hasThumbs = thumbs.isNotEmpty;

    final box = Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      decoration: BoxDecoration(
        color: PrivetTheme.ink.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(10),
        border: Border(left: BorderSide(color: PrivetTheme.signal, width: 3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasThumbs) ...[
            _ReplyThumbnailRow(
              thumbs: thumbs,
              mediaBase: mediaBase,
              context: context,
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: GoogleFonts.syne(
                    fontSize: 11 * fontScale,
                    fontWeight: FontWeight.w700,
                    color: PrivetTheme.signal,
                  ),
                ),
                const SizedBox(height: 2),
                // Soft-wrap without forcing the bubble to maxWidth (ellipsis
                // Text does).
                Text(
                  markupToPlain(reply.body),
                  maxLines: 2,
                  style: defaultFont.isEmpty
                      ? TextStyle(
                          fontSize: 12 * fontScale,
                          height: 1.25,
                          color: PrivetTheme.mist.withValues(alpha: 0.95),
                        )
                      : messageFontStyle(
                          defaultFont,
                          TextStyle(
                            fontSize: 12 * fontScale,
                            height: 1.25,
                            color: PrivetTheme.mist.withValues(alpha: 0.95),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    if (onTap == null) return box;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) {
          // Use onTapDown so it wins over the HorizontalDragGestureRecognizer
          // of _SwipeReplyHandle on compact/mobile layouts (touch-slope drag).
          onTap?.call();
        },
        child: box,
      ),
    );
  }
}

/// Renders up to 3 image thumbnails in a reply quote, with a "+N" overflow
/// badge when the replied-to message has more than 3 images.
class _ReplyThumbnailRow extends StatelessWidget {
  const _ReplyThumbnailRow({
    required this.thumbs,
    required this.mediaBase,
    required this.context,
  });

  final List<ReplyThumbnail> thumbs;
  final String mediaBase;
  final BuildContext context;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < thumbs.length && i < 3; i++)
          Padding(
            padding: EdgeInsets.only(right: i < thumbs.length - 1 ? 4 : 0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: CachedMediaImage(
                url: thumbs[i].mediaUrl.startsWith('http')
                    ? thumbs[i].mediaUrl
                    : '$mediaBase${thumbs[i].mediaUrl}',
                width: 36,
                height: 36,
                fit: BoxFit.cover,
                cacheWidth: ImageDecodeCaps.cacheWidth(
                  36,
                  dpr: MediaQuery.devicePixelRatioOf(context),
                ),
                errorBuilder: (_, error, stack) => const SizedBox.shrink(),
              ),
            ),
          ),
        if (thumbs.length > 3)
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: PrivetTheme.ink,
              borderRadius: BorderRadius.circular(6),
            ),
            alignment: Alignment.center,
            child: Text(
              '+${thumbs.length - 3}',
              style: TextStyle(
                fontSize: 10,
                color: PrivetTheme.mist,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    );
  }
}

/// Downloads [url] with [filename]. On native platforms the file lands in the
/// OS Downloads folder and the saved path is confirmed via snackbar; on web
/// the browser's own download handles it (no snackbar).
Future<void> _downloadMedia(
  BuildContext context,
  String url, {
  required String filename,
}) async {
  final saved = await downloadMedia(url, filename: filename);
  if (saved == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger?.showSnackBar(
    SnackBar(content: Text('Saved to $saved')),
  );
}

class _LinkPreviewCard extends StatelessWidget {
  const _LinkPreviewCard({required this.preview});

  final LinkPreview preview;

  @override
  Widget build(BuildContext context) {
    final host =
        Uri.tryParse(preview.url)?.host.replaceFirst(RegExp(r'^www\.'), '') ??
        preview.siteName;
    final title = (preview.title?.trim().isNotEmpty ?? false)
        ? preview.title!.trim()
        : (host ?? preview.url);
    final desc = preview.description?.trim();

    // Preview is display-only — open the URL only via the underlined
    // message link text, not by tapping empty space on this card.
    return Container(
      width: 260,
      decoration: BoxDecoration(
        color: PrivetTheme.ink.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: PrivetTheme.signal.withValues(alpha: 0.55)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (preview.image != null && preview.image!.isNotEmpty)
            ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(9),
              ),
              child: AspectRatio(
                aspectRatio: 1.91,
                child: Image.network(
                  preview.image!,
                  fit: BoxFit.cover,
                  cacheWidth: ImageDecodeCaps.cacheWidth(
                    260,
                    dpr: MediaQuery.devicePixelRatioOf(context),
                  ),
                  errorBuilder: (_, error, stack) => const SizedBox.shrink(),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (host != null && host.isNotEmpty)
                  Text(
                    (preview.siteName?.trim().isNotEmpty ?? false)
                        ? preview.siteName!.trim()
                        : host.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.syne(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                      color: PrivetTheme.signal,
                    ),
                  ),
                const SizedBox(height: 3),
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.25,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (desc != null && desc.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    desc,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.3,
                      color: PrivetTheme.mist.withValues(alpha: 0.95),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class VoicePlayer extends StatefulWidget {
  const VoicePlayer({super.key, required this.url, required this.label});

  final String url;
  final String label;

  @override
  State<VoicePlayer> createState() => _VoicePlayerState();
}

class _VoicePlayerState extends State<VoicePlayer> {
  final _player = AudioPlayer();
  StreamSubscription? _completeSub;
  bool _playing = false;

  @override
  void dispose() {
    _completeSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _player.stop();
      setState(() => _playing = false);
      return;
    }
    await _player.play(UrlSource(widget.url));
    setState(() => _playing = true);
    await _completeSub?.cancel();
    _completeSub = _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playing = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: _toggle,
          icon: Icon(
            _playing
                ? Icons.stop_circle_rounded
                : Icons.play_circle_filled_rounded,
            color: PrivetTheme.signal,
          ),
        ),
        Text(widget.label, style: const TextStyle(fontSize: 14)),
      ],
    );
  }
}
