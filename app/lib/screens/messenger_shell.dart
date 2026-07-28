import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../api/client.dart';
import '../models.dart';
import '../state.dart';
import '../theme.dart';
import '../util/agent_debug_log.dart';
import '../util/app_clipboard.dart';
import '../util/app_update.dart';
import '../util/clipboard_files.dart';
import '../util/ai_turn.dart';
import '../util/composer_autocomplete.dart';
import '../util/emoticon_expand.dart';
import '../util/composer_autocorrect.dart';
import '../util/composer_media_attach.dart';
import '../util/desktop_tray.dart';
import '../util/media_permissions.dart';
import '../util/media_ui_wake.dart';
import '../util/people_search.dart';
import '../util/privet_sheet.dart';
import '../util/low_resource.dart';
import '../util/recording_bytes.dart';
import '../util/sounds.dart';
import '../util/throttle.dart';
import '../util/web_bootstrap.dart';
import '../widgets/avatar.dart';
import '../widgets/chat_media_folder.dart';
import '../widgets/chat_task_pane.dart';
import '../widgets/compact_emoji_picker.dart';
import '../widgets/composer_autocomplete_popup.dart';
import '../widgets/composer_spell_layer.dart';
import '../widgets/composer_autocorrect_controller.dart';
import '../widgets/message_bubble.dart';
import '../widgets/screen_share_picker.dart';
import '../widgets/user_name.dart';
import '../widgets/typing_indicator.dart';
import '../widgets/web_attach_button.dart';
import 'call_screen.dart';

class MessengerShell extends StatefulWidget {
  const MessengerShell({super.key, required this.state});

  final PrivetState state;

  @override
  State<MessengerShell> createState() => _MessengerShellState();
}

class _MessengerShellState extends State<MessengerShell> {
  /// First frame after login is a huge tree. Show a static placeholder (not a
  /// spinner) for one frame so we never freeze an indeterminate indicator
  /// mid-arc while the inbox builds — that looked like a slideshow.
  bool _shellReady = false;

  @override
  void initState() {
    super.initState();
    widget.state.sessionTick.addListener(_onSessionHints);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _shellReady = true);
      _maybeShowWelcome();
      _maybeShowLowResourceHint();
    });
  }

  @override
  void dispose() {
    widget.state.sessionTick.removeListener(_onSessionHints);
    super.dispose();
  }

  void _onSessionHints() {
    if (widget.state.lowResourceAutoHint) {
      _maybeShowLowResourceHint();
    }
  }

  void _maybeShowLowResourceHint() {
    if (!mounted || !widget.state.lowResourceAutoHint) return;
    widget.state.clearLowResourceAutoHint();
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(
        content: const Text(
          'Smooth mode on — this device was dropping frames. '
          'You can change it in Profile → Low RAM & CPU mode.',
        ),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 6),
      ),
    );
  }

  Future<void> _maybeShowWelcome() async {
    final creds = widget.state.welcomeCredentials;
    if (creds == null || !mounted) return;
    final link = widget.state.inviteLink();
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          backgroundColor: PrivetTheme.panel,
          title: Text(
            'Welcome to Privet',
            style: GoogleFonts.syne(fontWeight: FontWeight.w700),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Save these credentials to sign in again:',
                style: TextStyle(color: PrivetTheme.mist),
              ),
              const SizedBox(height: 14),
              SelectableText(
                'Handle: @${creds['handle']}',
                style: GoogleFonts.ibmPlexSans(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              SelectableText(
                'Password: ${creds['password']}',
                style: GoogleFonts.ibmPlexSans(fontWeight: FontWeight.w600),
              ),
              if (link != null) ...[
                const SizedBox(height: 18),
                Text(
                  'Invite a friend — they join in one tap and land in a chat with you:',
                  style: TextStyle(color: PrivetTheme.mist),
                ),
                const SizedBox(height: 8),
                SelectableText(
                  link,
                  style: GoogleFonts.ibmPlexSans(
                    fontSize: 13,
                    color: PrivetTheme.signal,
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                AppClipboard.setText(
                  '@${creds['handle']} / ${creds['password']}',
                );
              },
              child: const Text('Copy login'),
            ),
            if (link != null)
              TextButton(
                onPressed: () {
                  AppClipboard.setText(link);
                },
                child: const Text('Copy invite'),
              ),
            ElevatedButton(
              onPressed: () {
                widget.state.clearWelcomeCredentials();
                Navigator.pop(context);
              },
              child: const Text('Continue'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    if (!_shellReady) {
      return Scaffold(
        backgroundColor: PrivetTheme.ink,
        body: const SizedBox.expand(),
      );
    }
    final wide = PrivetTheme.isWide(context);

    // Cache the messenger tree as a layer so modal/dialog transitions do not
    // re-paint the entire inbox every animation frame (Linux slideshow jank).
    return RepaintBoundary(
      child: Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => state.noteUserPresence(),
      onPointerSignal: (_) => state.noteUserPresence(),
      child: Stack(
        children: [
          // Structure (inbox vs chat) only when the open conversation changes.
          ListenableBuilder(
            listenable: state.shellTick,
            builder: (context, _) {
              final hasChat = state.activeConversationId != null;
              if (wide) {
                return Scaffold(
                  body: Row(
                    children: [
                      SizedBox(
                        width: 360,
                        child: ListenableBuilder(
                          listenable: Listenable.merge([
                            state.inboxTick,
                            state.typingTick,
                          ]),
                          builder: (context, _) => InboxPane(state: state),
                        ),
                      ),
                      Container(width: 1, color: PrivetTheme.line),
                      Expanded(
                        child: hasChat
                            ? ListenableBuilder(
                                listenable: Listenable.merge([
                                  state.chatTick,
                                  state.typingTick,
                                ]),
                                builder: (context, _) => ConversationPane(
                                  key: ValueKey(state.activeConversationId),
                                  state: state,
                                ),
                              )
                            : const _EmptyChat(),
                      ),
                    ],
                  ),
                );
              }
              return Scaffold(
                body: hasChat
                    ? ListenableBuilder(
                        listenable: Listenable.merge([
                          state.chatTick,
                          state.typingTick,
                        ]),
                        builder: (context, _) => ConversationPane(
                          key: ValueKey(state.activeConversationId),
                          state: state,
                          showBack: true,
                        ),
                      )
                    : ListenableBuilder(
                        listenable: Listenable.merge([
                          state.inboxTick,
                          state.typingTick,
                        ]),
                        builder: (context, _) => InboxPane(state: state),
                      ),
              );
            },
          ),
          ListenableBuilder(
            listenable: state.callTick,
            builder: (context, _) {
              final inCall =
                  state.callSession != null || state.ringing != null;
              if (!inCall) return const SizedBox.shrink();
              return Positioned.fill(child: CallOverlay(state: state));
            },
          ),
        ],
      ),
    ),
    );
  }
}

/// Active AI model badge — lives in the left sidebar under the signed-in line.
class AiModelChip extends StatelessWidget {
  const AiModelChip({super.key, required this.state});

  final PrivetState state;

  @override
  Widget build(BuildContext context) {
    if (!state.aiActive) return const SizedBox.shrink();
    return Tooltip(
      message: '${state.aiModelLabel} · # shared · #me private',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: PrivetTheme.signal.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: PrivetTheme.signal.withValues(alpha: 0.35),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_awesome_rounded,
              size: 12,
              color: PrivetTheme.signal,
            ),
            const SizedBox(width: 4),
            Text(
              state.aiModelLabel,
              style: GoogleFonts.ibmPlexSans(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: PrivetTheme.signal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class InboxPane extends StatelessWidget {
  const InboxPane({super.key, required this.state});

  final PrivetState state;

  @override
  Widget build(BuildContext context) {
    final compact = PrivetTheme.isCompact(context);
    return ColoredBox(
      color: PrivetTheme.ink,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                compact ? 16 : 20,
                compact ? 12 : 16,
                12,
                4,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: 'P',
                        style: GoogleFonts.syne(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          color: PrivetTheme.signal,
                        ),
                      ),
                      TextSpan(
                        text: 'rivet',
                        style: GoogleFonts.syne(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(compact ? 8 : 12, 0, 8, 8),
              child: Row(
                children: [
                  Tooltip(
                    message: 'Profile & settings',
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: InkWell(
                        onTap: () => _showProfile(context),
                        mouseCursor: SystemMouseCursors.click,
                        customBorder: const CircleBorder(),
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: state.user == null
                              ? const Icon(Icons.settings_rounded)
                              : Stack(
                                  clipBehavior: Clip.none,
                                  children: [
                                    PrivetAvatar(
                                      name: state.user!.displayName,
                                      hue: state.user!.avatarHue,
                                      avatarUrl: state.user!.avatarUrl == null
                                          ? null
                                          : state.api.absoluteMediaUrl(
                                              state.user!.avatarUrl,
                                            ),
                                      size: compact ? 36 : 32,
                                    ),
                                    Positioned(
                                      right: -3,
                                      bottom: -3,
                                      child: Container(
                                        width: 16,
                                        height: 16,
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(
                                          color: PrivetTheme.panel,
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color: PrivetTheme.line,
                                          ),
                                        ),
                                        child: Icon(
                                          Icons.settings_rounded,
                                          size: 11,
                                          color: PrivetTheme.mist,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'People',
                    onPressed: () => _showPeople(context),
                    visualDensity: compact
                        ? VisualDensity.standard
                        : VisualDensity.compact,
                    icon: const Icon(Icons.person_add_alt_1_rounded),
                  ),
                  IconButton(
                    tooltip: 'New group',
                    onPressed: () => _showNewGroup(context),
                    visualDensity: compact
                        ? VisualDensity.standard
                        : VisualDensity.compact,
                    icon: const Icon(Icons.group_add_rounded),
                  ),
                  IconButton(
                    tooltip: 'Invite someone',
                    onPressed: () => _showInvite(context),
                    visualDensity: compact
                        ? VisualDensity.standard
                        : VisualDensity.compact,
                    icon: const Icon(Icons.link_rounded),
                  ),
                  IconButton(
                    tooltip: 'Search',
                    onPressed: () => _showSearch(context),
                    visualDensity: compact
                        ? VisualDensity.standard
                        : VisualDensity.compact,
                    icon: const Icon(Icons.search_rounded),
                  ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: compact ? 16 : 20),
              child: Text(
                state.user == null
                    ? ''
                    : 'Signed in as ${state.user!.displayName} · @${state.user!.handle}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: PrivetTheme.mist, fontSize: 13),
              ),
            ),
            ListenableBuilder(
              listenable: state,
              builder: (context, _) {
                if (!state.aiActive) return const SizedBox.shrink();
                return Padding(
                  padding: EdgeInsets.fromLTRB(
                    compact ? 16 : 20,
                    6,
                    compact ? 16 : 20,
                    0,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: AiModelChip(state: state),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                itemCount: state.conversations.length,
                itemBuilder: (context, i) {
                  final c = state.conversations[i];
                  final selected = c.id == state.activeConversationId;
                  final peerOnline =
                      c.peer != null && state.online.contains(c.peer!.id);
                  return Material(
                    color: selected
                        ? PrivetTheme.panelElevated
                        : Colors.transparent,
                    child: InkWell(
                      onTap: () => state.openConversation(c.id),
                      mouseCursor: SystemMouseCursors.click,
                      onSecondaryTapUp: (details) {
                        _openConversationMenu(
                          context,
                          c,
                          details.globalPosition,
                        );
                      },
                      onLongPress: () {
                        // Prefer the ink well's own box; fall back if not laid out yet.
                        final box = context.findRenderObject();
                        final Offset pos;
                        if (box is RenderBox && box.hasSize) {
                          pos = box.localToGlobal(const Offset(72, 36));
                        } else {
                          pos = const Offset(72, 120);
                        }
                        _openConversationMenu(context, c, pos);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        child: Row(
                          children: [
                            PrivetAvatar(
                              name: c.title,
                              hue: c.peer?.avatarHue ?? (c.isGroup ? 90 : 160),
                              avatarUrl: c.peer?.avatarUrl == null
                                  ? null
                                  : state.api.absoluteMediaUrl(
                                      c.peer!.avatarUrl,
                                    ),
                              online: peerOnline,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          c.title,
                                          style: GoogleFonts.syne(
                                            fontWeight: c.unreadCount > 0
                                                ? FontWeight.w800
                                                : FontWeight.w700,
                                            fontSize: 16,
                                          ),
                                        ),
                                      ),
                                      if (c.muted)
                                        Padding(
                                          padding: EdgeInsets.only(right: 4),
                                          child: Icon(
                                            Icons.notifications_off_outlined,
                                            size: 14,
                                            color: PrivetTheme.mist,
                                          ),
                                        ),
                                      if (c.isGroup)
                                        Icon(
                                          Icons.groups_rounded,
                                          size: 16,
                                          color: PrivetTheme.mist,
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  if (state.isTypingIn(c.id))
                                    Text(
                                      state.typingLabel(conversationId: c.id),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: PrivetTheme.signal,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        fontStyle: FontStyle.italic,
                                      ),
                                    )
                                  else if (c.peer != null &&
                                      c.peer!.handle.isNotEmpty)
                                    Text(
                                      '@${c.peer!.handle}',
                                      style: TextStyle(
                                        color: PrivetTheme.signal,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    )
                                  else
                                    Text(
                                      c.lastMessage?.body ?? 'No messages yet',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: PrivetTheme.mist,
                                        fontSize: 13,
                                        fontWeight: c.unreadCount > 0
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                      ),
                                    ),
                                  if (!state.isTypingIn(c.id) &&
                                      c.peer != null &&
                                      c.peer!.handle.isNotEmpty &&
                                      c.lastMessage != null)
                                    Text(
                                      c.lastMessage!.body,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: PrivetTheme.mist,
                                        fontSize: 12,
                                        fontWeight: c.unreadCount > 0
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                      ),
                                    )
                                  else if (!state.isTypingIn(c.id) &&
                                      c.peer != null &&
                                      c.peer!.handle.isNotEmpty &&
                                      c.lastMessage == null)
                                    Text(
                                      'No messages yet — say hi',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: PrivetTheme.mist.withValues(
                                          alpha: 0.7,
                                        ),
                                        fontSize: 12,
                                        fontStyle: FontStyle.italic,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                if (c.lastMessage != null)
                                  Text(
                                    DateFormat.Hm().format(
                                      c.lastMessage!.createdAt.toLocal(),
                                    ),
                                    style: TextStyle(
                                      color: PrivetTheme.mist,
                                      fontSize: 11,
                                    ),
                                  )
                                else if (c.pinned)
                                  Icon(
                                    Icons.push_pin_rounded,
                                    size: 14,
                                    color: PrivetTheme.mist.withValues(
                                      alpha: 0.85,
                                    ),
                                  ),
                                if (c.unreadCount > 0) ...[
                                  const SizedBox(height: 6),
                                  Container(
                                    constraints: const BoxConstraints(
                                      minWidth: 20,
                                      minHeight: 20,
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: c.muted
                                          ? PrivetTheme.mist.withValues(
                                              alpha: 0.45,
                                            )
                                          : PrivetTheme.signal,
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    alignment: Alignment.center,
                                    child: Text(
                                      c.unreadCount > 99
                                          ? '99+'
                                          : '${c.unreadCount}',
                                      style: TextStyle(
                                        color: PrivetTheme.onAccent,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ] else if (c.pinned &&
                                    c.lastMessage != null) ...[
                                  const SizedBox(height: 6),
                                  Icon(
                                    Icons.push_pin_rounded,
                                    size: 15,
                                    color: PrivetTheme.mist.withValues(
                                      alpha: 0.8,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showSearch(BuildContext context) async {
    await showPrivetSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: PrivetTheme.panel,
      builder: (ctx) => _SearchSheet(state: state),
    );
  }

  Future<void> _openConversationMenu(
    BuildContext context,
    Conversation chat,
    Offset globalPosition,
  ) async {
    if (!context.mounted) return;
    final me = state.user?.id;
    final canDeleteGroup = chat.isOwnedBy(me);
    final deleteLabel = chat.isGroup
        ? (canDeleteGroup ? 'Delete group' : 'Leave group')
        : 'Delete conversation';

    // Use the overlay size so the menu always has a valid RelativeRect.
    final overlay = Overlay.maybeOf(context)?.context.findRenderObject();
    final overlaySize = overlay is RenderBox && overlay.hasSize
        ? overlay.size
        : MediaQuery.sizeOf(context);
    final dx = globalPosition.dx.clamp(0.0, overlaySize.width);
    final dy = globalPosition.dy.clamp(0.0, overlaySize.height);

    String? action;
    try {
      action = await showMenu<String>(
        context: context,
        color: PrivetTheme.panelElevated,
        elevation: 8,
        position: RelativeRect.fromLTRB(
          dx,
          dy,
          overlaySize.width - dx,
          overlaySize.height - dy,
        ),
        items: [
          PopupMenuItem<String>(
            value: chat.pinned ? 'unpin' : 'pin',
            height: 44,
            child: Row(
              children: [
                Icon(
                  chat.pinned
                      ? Icons.push_pin_rounded
                      : Icons.push_pin_outlined,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Text(chat.pinned ? 'Unpin' : 'Pin chat'),
              ],
            ),
          ),
          PopupMenuItem<String>(
            value: chat.muted ? 'unmute' : 'mute',
            height: 44,
            child: Row(
              children: [
                Icon(
                  chat.muted
                      ? Icons.notifications_active_outlined
                      : Icons.notifications_off_outlined,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Text(chat.muted ? 'Unmute' : 'Mute'),
              ],
            ),
          ),
          if (!chat.isGroup && chat.peer != null)
            PopupMenuItem<String>(
              value: 'block',
              height: 44,
              child: Row(
                children: const [
                  Icon(Icons.block_rounded, size: 20),
                  SizedBox(width: 12),
                  Text('Block user'),
                ],
              ),
            ),
          PopupMenuItem<String>(
            value: 'hide',
            height: 44,
            child: Row(
              children: const [
                Icon(Icons.visibility_off_outlined, size: 20),
                SizedBox(width: 12),
                Text('Hide conversation'),
              ],
            ),
          ),
          PopupMenuItem<String>(
            value: 'delete',
            height: 44,
            child: Row(
              children: [
                Icon(
                  Icons.delete_outline_rounded,
                  size: 20,
                  color: PrivetTheme.danger,
                ),
                const SizedBox(width: 12),
                Text(deleteLabel, style: TextStyle(color: PrivetTheme.danger)),
              ],
            ),
          ),
        ],
      );
    } catch (_) {
      if (context.mounted) _toast(context, 'Could not open menu');
      return;
    }

    if (action == null || !context.mounted) return;

    if (action == 'pin' || action == 'unpin') {
      try {
        await state.setPinned(chat.id, pinned: action == 'pin');
        if (context.mounted) {
          _toast(context, action == 'pin' ? 'Pinned' : 'Unpinned');
        }
      } catch (e) {
        if (context.mounted) {
          _toast(
            context,
            e is ApiException ? e.message : e.toString(),
            error: true,
          );
        }
      }
      return;
    }

    if (action == 'block' && chat.peer != null) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: PrivetTheme.panelElevated,
          title: const Text('Block user?'),
          content: Text(
            'Block @${chat.peer!.handle}? They won’t be able to message you.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Block'),
            ),
          ],
        ),
      );
      if (ok == true && context.mounted) {
        try {
          await state.blockUser(chat.peer!.id);
          if (context.mounted) _toast(context, 'Blocked');
        } catch (e) {
          if (context.mounted) {
            _toast(
              context,
              e is ApiException ? e.message : e.toString(),
              error: true,
            );
          }
        }
      }
      return;
    }

    if (action == 'mute' || action == 'unmute') {
      try {
        await state.setMuted(chat.id, muted: action == 'mute');
        if (context.mounted) {
          _toast(context, action == 'mute' ? 'Muted' : 'Unmuted');
        }
      } catch (e) {
        if (context.mounted) {
          _toast(
            context,
            e is ApiException ? e.message : e.toString(),
            error: true,
          );
        }
      }
      return;
    }

    if (action == 'hide') {
      try {
        await state.hideConversation(chat.id);
        if (context.mounted) _toast(context, 'Conversation hidden');
      } catch (e) {
        if (context.mounted) {
          _toast(
            context,
            e is ApiException ? e.message : e.toString(),
            error: true,
          );
        }
      }
      return;
    }

    if (action == 'delete') {
      // Wait until the popup route fully pops — showDialog right after
      // showMenu often fails silently on Flutter web.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (!context.mounted) return;

      final confirmTitle = chat.isGroup
          ? (canDeleteGroup ? 'Delete group?' : 'Leave group?')
          : 'Delete conversation?';
      final confirmBody = chat.isGroup
          ? (canDeleteGroup
                ? '“${chat.title}” will be deleted for everyone. This cannot be undone.'
                : 'You will leave “${chat.title}”.')
          : '“${chat.title}” will be deleted for both of you.';
      final confirmAction = chat.isGroup && !canDeleteGroup
          ? 'Leave'
          : 'Delete';

      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: PrivetTheme.panel,
          title: Text(
            confirmTitle,
            style: GoogleFonts.syne(fontWeight: FontWeight.w700),
          ),
          content: Text(confirmBody, style: TextStyle(color: PrivetTheme.mist)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: PrivetTheme.danger,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(confirmAction),
            ),
          ],
        ),
      );
      if (ok != true || !context.mounted) return;
      try {
        await state.deleteConversation(chat.id);
        if (context.mounted) {
          _toast(
            context,
            chat.isGroup
                ? (canDeleteGroup ? 'Group deleted' : 'Left group')
                : 'Conversation deleted',
          );
        }
      } catch (e) {
        if (context.mounted) {
          _toast(
            context,
            e is ApiException ? e.message : e.toString(),
            error: true,
          );
        }
      }
    }
  }

  void _toast(BuildContext context, String message, {bool error = false}) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: error
              ? PrivetTheme.danger
              : PrivetTheme.panelElevated,
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Future<void> _showInvite(BuildContext context) async {
    final link = state.inviteLink();
    if (link == null) return;
    final me = state.user!;
    final shareText =
        'Join me on Privet — open this link to get an account instantly and chat with @${me.handle}:\n$link';
    await showPrivetSheet<void>(
      context: context,
      backgroundColor: PrivetTheme.panel,
      showDragHandle: true,
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Invite someone',
                style: GoogleFonts.syne(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Send this link. They open it, get a handle + password automatically, and land in a chat with you.',
                style: GoogleFonts.ibmPlexSans(
                  color: PrivetTheme.mist,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: PrivetTheme.panelElevated,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: PrivetTheme.line),
                ),
                child: SelectableText(
                  link,
                  style: GoogleFonts.ibmPlexSans(
                    color: PrivetTheme.signal,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () async {
                  await AppClipboard.setText(link);
                  if (!ctx.mounted) return;
                  Navigator.pop(ctx);
                  if (context.mounted) _toast(context, 'Invite link copied');
                },
                icon: const Icon(Icons.copy_rounded),
                label: const Text('Copy invite link'),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () async {
                  await AppClipboard.setText(shareText);
                  if (!ctx.mounted) return;
                  Navigator.pop(ctx);
                  if (context.mounted) {
                    _toast(context, 'Invite message copied');
                  }
                },
                icon: const Icon(Icons.chat_bubble_outline_rounded),
                label: const Text('Copy message with link'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: PrivetTheme.paper,
                  side: BorderSide(color: PrivetTheme.line),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showPeople(BuildContext context) async {
    final pasteCtrl = TextEditingController();
    var lookingUp = false;
    PrivetUser? resolved;
    String? resolveError;
    var queryText = '';
    Timer? debounce;

    void disposeSheet() {
      debounce?.cancel();
      pasteCtrl.dispose();
    }

    await showPrivetSheet<void>(
      context: context,
      backgroundColor: PrivetTheme.panel,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setModal) {
            Future<void> resolveExactHandle(String handle) async {
              // Prefer local directory match first.
              PrivetUser? local;
              for (final u in state.directory) {
                if (u.handle.toLowerCase() == handle) {
                  local = u;
                  break;
                }
              }
              if (local != null) {
                setModal(() {
                  resolved = local;
                  resolveError = null;
                  lookingUp = false;
                });
                return;
              }
              setModal(() {
                resolved = null;
                resolveError = null;
                lookingUp = true;
              });
              try {
                final info = await state.api.inviteInfo(handle);
                final id = info['id'] as String?;
                if (!sheetContext.mounted) return;
                if (id == null || id.isEmpty) {
                  setModal(() {
                    resolved = null;
                    resolveError = 'Invite not found';
                    lookingUp = false;
                  });
                  return;
                }
                setModal(() {
                  resolved = PrivetUser(
                    id: id,
                    handle: (info['handle'] as String?) ?? handle,
                    displayName: (info['displayName'] as String?) ?? handle,
                    avatarHue: (info['avatarHue'] as num?)?.toInt() ?? 160,
                    avatarUrl: info['avatarUrl'] as String?,
                  );
                  resolveError = null;
                  lookingUp = false;
                });
              } catch (e) {
                if (!sheetContext.mounted) return;
                setModal(() {
                  resolved = null;
                  resolveError = e is ApiException
                      ? e.message
                      : 'Invite not found';
                  lookingUp = false;
                });
              }
            }

            void onQueryChanged(String _) {
              debounce?.cancel();
              final raw = pasteCtrl.text;
              setModal(() {
                queryText = raw;
                resolveError = null;
                // Keep a prior exact resolve only while the field still
                // matches that handle / invite paste.
                if (resolved != null) {
                  final q = normalizePeopleQuery(raw);
                  final still =
                      looksLikeInviteUrl(raw) ||
                      q == resolved!.handle.toLowerCase();
                  if (!still) resolved = null;
                }
              });
              // Exact remote lookup only for invite links or explicit @handle.
              final trimmed = raw.trim();
              final wantsExact =
                  looksLikeInviteUrl(trimmed) || trimmed.startsWith('@');
              if (!wantsExact) {
                setModal(() => lookingUp = false);
                return;
              }
              final handle = PrivetState.parseInviteHandle(trimmed);
              if (handle == null || handle.isEmpty) {
                setModal(() {
                  resolved = null;
                  lookingUp = false;
                });
                return;
              }
              debounce = Timer(const Duration(milliseconds: 200), () {
                unawaited(resolveExactHandle(handle));
              });
            }

            Future<void> openPeer(PrivetUser peer) async {
              try {
                Navigator.pop(sheetContext);
                await state.openDm(peer);
              } catch (e) {
                if (!context.mounted) return;
                final msg = e is ApiException ? e.message : e.toString();
                _toast(context, msg, error: true);
              }
            }

            Future<void> onSubmitted() async {
              if (lookingUp) return;
              if (resolved != null) {
                await openPeer(resolved!);
                return;
              }
              final matches = filterPeople(state.directory, queryText);
              if (matches.isNotEmpty) {
                await openPeer(matches.first);
                return;
              }
              final handle = PrivetState.parseInviteHandle(queryText);
              if (handle == null || handle.isEmpty) return;
              await resolveExactHandle(handle);
              if (!sheetContext.mounted) return;
              if (resolved != null) await openPeer(resolved!);
            }

            final filtering = normalizePeopleQuery(queryText).isNotEmpty;
            final localMatches = filterPeople(state.directory, queryText);
            // Exact invite/@resolve may surface someone not yet in directory.
            final matches = <PrivetUser>[
              if (resolved != null &&
                  !localMatches.any((u) => u.id == resolved!.id))
                resolved!,
              ...localMatches,
            ];
            final blocked = filtering ? const <PrivetUser>[] : state.blocked;
            final showEmpty =
                filtering &&
                !lookingUp &&
                matches.isEmpty &&
                resolveError == null;

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
              ),
              child: CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                        child: Text(
                          'Start a chat',
                          style: GoogleFonts.syne(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                        child: TextField(
                          controller: pasteCtrl,
                          textInputAction: TextInputAction.go,
                          onChanged: onQueryChanged,
                          onSubmitted: (_) => onSubmitted(),
                          decoration: InputDecoration(
                            hintText: 'Search people, @handle, or invite link',
                            prefixIcon: const Icon(Icons.search_rounded),
                            suffixIcon: lookingUp
                                ? const Padding(
                                    padding: EdgeInsets.all(12),
                                    child: SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  )
                                : (pasteCtrl.text.isNotEmpty
                                      ? IconButton(
                                          tooltip: 'Clear',
                                          onPressed: () {
                                            pasteCtrl.clear();
                                            onQueryChanged('');
                                          },
                                          icon: const Icon(Icons.close_rounded),
                                        )
                                      : null),
                          ),
                        ),
                      ),
                    ),
                    if (!filtering)
                      SliverToBoxAdapter(
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: PrivetTheme.signal.withValues(
                              alpha: 0.15,
                            ),
                            child: Icon(
                              Icons.ios_share_rounded,
                              color: PrivetTheme.signal,
                            ),
                          ),
                          title: const Text('Share my invite link'),
                          subtitle: const Text('Copy a one-tap join link'),
                          onTap: () {
                            Navigator.pop(sheetContext);
                            _showInvite(context);
                          },
                        ),
                      ),
                    if (!filtering)
                      const SliverToBoxAdapter(
                        child: Divider(height: 1),
                      ),
                    if (filtering && lookingUp && matches.isEmpty)
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                      )
                    else if (filtering &&
                        resolveError != null &&
                        matches.isEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                          child: Text(
                            resolveError!,
                            style: GoogleFonts.ibmPlexSans(
                              color: PrivetTheme.danger,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      )
                    else if (showEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
                          child: Text(
                            'No people match “${normalizePeopleQuery(queryText)}”',
                            textAlign: TextAlign.center,
                            style: GoogleFonts.ibmPlexSans(
                              color: PrivetTheme.mist,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      )
                    else
                      SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, i) {
                            final u = matches[i];
                            final exact = resolved?.id == u.id ||
                                u.handle.toLowerCase() ==
                                    normalizePeopleQuery(queryText);
                            return ListTile(
                              leading: PrivetAvatar(
                                name: u.displayName,
                                hue: u.avatarHue,
                                avatarUrl: u.avatarUrl == null
                                    ? null
                                    : state.api.absoluteMediaUrl(u.avatarUrl),
                                online: state.online.contains(u.id),
                              ),
                              title: UserNameBlock.fromUser(u, titleSize: 15),
                              subtitle: Text(
                                filtering
                                    ? '@${u.handle}'
                                    : state.presenceLabel(u.id),
                              ),
                              trailing: exact && filtering
                                  ? TextButton(
                                      onPressed: () => openPeer(u),
                                      child: const Text('Chat'),
                                    )
                                  : null,
                              onTap: () => openPeer(u),
                            );
                          },
                          childCount: matches.length,
                          addAutomaticKeepAlives: false,
                          addRepaintBoundaries: true,
                        ),
                      ),
                    if (blocked.isNotEmpty) ...[
                      const SliverToBoxAdapter(child: Divider(height: 1)),
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                          child: Text(
                            'Blocked',
                            style: GoogleFonts.syne(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                      SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, i) {
                            final u = blocked[i];
                            return ListTile(
                              leading: PrivetAvatar(
                                name: u.displayName,
                                hue: u.avatarHue,
                                avatarUrl: u.avatarUrl == null
                                    ? null
                                    : state.api.absoluteMediaUrl(u.avatarUrl),
                              ),
                              title: Text(u.displayName),
                              subtitle: Text('@${u.handle}'),
                              trailing: TextButton(
                                onPressed: () async {
                                  await state.unblockUser(u.id);
                                  if (sheetContext.mounted) {
                                    Navigator.pop(sheetContext);
                                  }
                                },
                                child: const Text('Unblock'),
                              ),
                            );
                          },
                          childCount: blocked.length,
                          addAutomaticKeepAlives: false,
                        ),
                      ),
                    ],
                  ],
                ),
            );
          },
        );
      },
    );
    disposeSheet();
  }

  Future<void> _showProfile(BuildContext context) async {
    final me = state.user;
    if (me == null) return;
    // Opening the sheet used to await two network calls (AI status +
    // update check) before the animation started, which made the click
    // feel like ~2fps. Kick both off in the background instead — the
    // sheet reacts to `state` as they finish.
    final versionLabelFuture = PackageInfo.fromPlatform().then((info) =>
        info.buildNumber.isEmpty
            ? info.version
            : '${info.version} (${info.buildNumber})');
    unawaited(state.refreshAiStatus());
    final updateStatusFuture = AppUpdate.check(baseUrl: state.api.baseUrl);
    final nameCtrl = TextEditingController(text: me.displayName);
    var enabled = state.aiEnabled && state.aiActive;
    Uint8List? pendingAvatarBytes;
    String? pendingAvatarFilename;
    String pendingAvatarMime = 'image/jpeg';
    var pendingClearAvatar = false;
    var updating = false;
    var updateProgress = 0.0;
    var versionLabel = '';
    var updateStatus = AppUpdateStatus.unavailable;
    var subscribedToVersion = false;
    var subscribedToUpdate = false;
    await showPrivetSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: PrivetTheme.panel,
      showDragHandle: true,
      builder: (ctx) {
        // Listening to the whole `state` here caused the entire
        // 500-line sheet to rebuild on every notifyListeners tick
        // (typing, presence, WS pings). Scope down to the ticks that
        // actually change what this sheet renders.
        return ListenableBuilder(
          listenable: Listenable.merge([
            state.sessionTick,
            state.shellTick,
          ]),
          builder: (ctx, _) {
            return StatefulBuilder(
              builder: (ctx, setSheet) {
                if (!subscribedToVersion) {
                  subscribedToVersion = true;
                  versionLabelFuture.then((label) {
                    if (ctx.mounted) setSheet(() => versionLabel = label);
                  });
                }
                if (!subscribedToUpdate) {
                  subscribedToUpdate = true;
                  updateStatusFuture.then((status) {
                    if (ctx.mounted) setSheet(() => updateStatus = status);
                  });
                }
                final active = state.activeAiProfile;
                final inUseLabel = !enabled || active == null || !active.isReady
                    ? 'Not activated — add an AI and turn it on'
                    : 'In use · ${active.displayName}';
                final previewName = nameCtrl.text.trim().isEmpty
                    ? me.displayName
                    : nameCtrl.text.trim();
                final showRemove =
                    !pendingClearAvatar &&
                    (pendingAvatarBytes != null || me.avatarUrl != null);
                final previewUrl =
                    pendingClearAvatar ||
                        pendingAvatarBytes != null ||
                        me.avatarUrl == null
                    ? null
                    : state.api.absoluteMediaUrl(me.avatarUrl);
                return Padding(
                  padding: EdgeInsets.only(
                    left: 20,
                    right: 20,
                    bottom: MediaQuery.viewInsetsOf(ctx).bottom + 24,
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Your profile',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.syne(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Center(
                          child: PrivetAvatar(
                            name: previewName,
                            hue: me.avatarHue,
                            avatarUrl: previewUrl,
                            avatarImage: pendingAvatarBytes == null
                                ? null
                                : MemoryImage(pendingAvatarBytes!),
                            size: 72,
                            online: true,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '@${me.handle}',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: PrivetTheme.mist),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: nameCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Display name',
                          ),
                          onChanged: (_) => setSheet(() {}),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () async {
                                  final result = await FilePicker.platform
                                      .pickFiles(
                                        type: FileType.image,
                                        withData: true,
                                      );
                                  final file = result?.files.single;
                                  if (file?.bytes == null) return;
                                  setSheet(() {
                                    pendingAvatarBytes = file!.bytes;
                                    pendingAvatarFilename = file.name;
                                    pendingAvatarMime = file.extension == 'png'
                                        ? 'image/png'
                                        : 'image/jpeg';
                                    pendingClearAvatar = false;
                                  });
                                },
                                icon: const Icon(Icons.photo_camera_outlined),
                                label: const Text('Photo'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            if (showRemove)
                              TextButton(
                                onPressed: () {
                                  setSheet(() {
                                    pendingAvatarBytes = null;
                                    pendingAvatarFilename = null;
                                    pendingClearAvatar = true;
                                  });
                                },
                                child: const Text('Remove'),
                              ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        Text(
                          'Privet AI',
                          style: GoogleFonts.syne(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                          decoration: BoxDecoration(
                            color: PrivetTheme.panelElevated,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: PrivetTheme.line),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    enabled && active != null && active.isReady
                                        ? Icons.check_circle_outline_rounded
                                        : Icons.key_off_rounded,
                                    size: 18,
                                    color:
                                        enabled &&
                                            active != null &&
                                            active.isReady
                                        ? PrivetTheme.signal
                                        : PrivetTheme.mist,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      inUseLabel,
                                      style: TextStyle(
                                        color:
                                            enabled &&
                                                active != null &&
                                                active.isReady
                                            ? PrivetTheme.paper
                                            : PrivetTheme.mist,
                                        height: 1.35,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Text(
                                'Add one or more AIs, then toggle which one is active.\n\n'
                                '• Gemini: API key (AIza…) + model\n'
                                '• OpenAI-compatible: API key + base URL + model '
                                '(OpenAI, DeepSeek, Groq, OpenRouter, Ollama, …)\n\n'
                                '• # question — shared grouped Q+A\n'
                                '• #me question — only you\n\n'
                                'Keys stay on this device.',
                                style: TextStyle(
                                  color: PrivetTheme.mist,
                                  height: 1.4,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (state.aiProfiles.isEmpty)
                          Padding(
                            padding: EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              'No AIs yet — tap Add AI.',
                              style: TextStyle(color: PrivetTheme.mist),
                            ),
                          ),
                        for (final p in state.aiProfiles)
                          // IconButtons must sit outside RadioListTile — on web,
                          // secondary/trailing inside the tile swallows taps
                          // (MergeSemantics / ensureSemantics).
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                child: RadioListTile<String>(
                                  contentPadding: EdgeInsets.zero,
                                  dense: true,
                                  value: p.id,
                                  groupValue:
                                      state.activeAiProfileId ??
                                      state.aiProfiles.first.id,
                                  activeColor: PrivetTheme.signal,
                                  title: Text(
                                    p.displayName,
                                    style: GoogleFonts.ibmPlexSans(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  subtitle: Text(
                                    [
                                      p.maskedKey,
                                      if (p.baseUrl.trim().isNotEmpty)
                                        p.baseUrl.trim(),
                                    ].join(' · '),
                                    style: TextStyle(
                                      color: PrivetTheme.mist,
                                      fontSize: 12,
                                    ),
                                  ),
                                  onChanged: (id) async {
                                    if (id == null) return;
                                    await state.setActiveAiProfile(id);
                                    setSheet(() {});
                                  },
                                ),
                              ),
                              IconButton(
                                tooltip: 'Edit',
                                visualDensity: VisualDensity.compact,
                                onPressed: () async {
                                  await _editAiProfileDialog(ctx, existing: p);
                                  setSheet(() {});
                                },
                                icon: const Icon(Icons.edit_outlined, size: 20),
                              ),
                              IconButton(
                                tooltip: 'Remove',
                                visualDensity: VisualDensity.compact,
                                onPressed: () async {
                                  await state.deleteAiProfile(p.id);
                                  setSheet(() {
                                    enabled = state.aiEnabled && state.aiActive;
                                  });
                                },
                                icon: const Icon(
                                  Icons.delete_outline_rounded,
                                  size: 20,
                                ),
                              ),
                            ],
                          ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: () async {
                              await _editAiProfileDialog(context);
                              setSheet(() {});
                            },
                            icon: const Icon(Icons.add_rounded),
                            label: const Text('Add AI'),
                          ),
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Enable Privet AI'),
                          subtitle: Text(
                            state.aiProfiles.isEmpty
                                ? 'Add an AI first'
                                : 'Active: ${state.aiModelLabel.isEmpty ? '—' : state.aiModelLabel}',
                            style: TextStyle(
                              color: PrivetTheme.mist,
                              fontSize: 12,
                            ),
                          ),
                          value: enabled,
                          activeThumbColor: PrivetTheme.onAccent,
                          activeTrackColor: PrivetTheme.signal,
                          onChanged: (v) {
                            if (v &&
                                !(state.activeAiProfile?.isReady ?? false)) {
                              if (context.mounted) {
                                _toast(
                                  context,
                                  'Add an AI with key + model (and base URL if needed) first',
                                  error: true,
                                );
                              }
                              return;
                            }
                            setSheet(() => enabled = v);
                          },
                        ),
                        const SizedBox(height: 16),
                        Divider(color: PrivetTheme.line, height: 1),
                        const SizedBox(height: 12),
                        Text(
                          'Notifications',
                          style: GoogleFonts.syne(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Message sound'),
                          subtitle: Text(
                            'Play a sound on new messages',
                            style: TextStyle(
                              color: PrivetTheme.mist,
                              fontSize: 12,
                            ),
                          ),
                          value: state.soundEnabled,
                          activeThumbColor: PrivetTheme.onAccent,
                          activeTrackColor: PrivetTheme.signal,
                          onChanged: (v) => state.setSoundEnabled(v),
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Notification pop-ups'),
                          subtitle: Text(
                            'Show a toast when a message arrives',
                            style: TextStyle(
                              color: PrivetTheme.mist,
                              fontSize: 12,
                            ),
                          ),
                          value: state.notificationsEnabled,
                          activeThumbColor: PrivetTheme.onAccent,
                          activeTrackColor: PrivetTheme.signal,
                          onChanged: (v) => state.setNotificationsEnabled(v),
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Low RAM & CPU mode'),
                          subtitle: Text(
                            'Turns off UI motion, uses static emoji, smaller '
                            'images. On a GPU PC (e.g. RTX) this stays off '
                            'unless you flip it — one check at startup.',
                            style: TextStyle(
                              color: PrivetTheme.mist,
                              fontSize: 12,
                            ),
                          ),
                          value: state.lowResourceMode,
                          activeThumbColor: PrivetTheme.onAccent,
                          activeTrackColor: PrivetTheme.signal,
                          onChanged: (v) {
                            state.setLowResourceMode(v);
                            setSheet(() {});
                          },
                        ),
                        const SizedBox(height: 16),
                        Divider(color: PrivetTheme.line, height: 1),
                        const SizedBox(height: 12),
                        Text(
                          'Appearance',
                          style: GoogleFonts.syne(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 12),
                        _ThemeModeSelector(
                          mode: state.themeMode,
                          onChanged: (m) {
                            state.setThemeMode(m);
                            setSheet(() {});
                          },
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Accent color',
                          style: TextStyle(
                            color: PrivetTheme.mist,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 10),
                        _AccentPicker(
                          selected: state.accent,
                          onPick: (c) {
                            state.setAccent(c);
                            setSheet(() {});
                          },
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: () async {
                              try {
                                String? uploadedAvatarUrl;
                                if (pendingAvatarBytes != null) {
                                  final uploaded = await state.api.uploadBytes(
                                    bytes: pendingAvatarBytes!,
                                    filename:
                                        pendingAvatarFilename ?? 'avatar.jpg',
                                    mimeType: pendingAvatarMime,
                                  );
                                  uploadedAvatarUrl = uploaded.mediaUrl;
                                }
                                await state.updateProfile(
                                  displayName: nameCtrl.text.trim(),
                                  avatarUrl: uploadedAvatarUrl,
                                  clearAvatar:
                                      pendingClearAvatar &&
                                      uploadedAvatarUrl == null,
                                );
                                if (enabled &&
                                    !(state.activeAiProfile?.isReady ??
                                        false)) {
                                  if (context.mounted) {
                                    _toast(
                                      context,
                                      'Add an AI with key + model (and base URL if needed) first',
                                      error: true,
                                    );
                                  }
                                  return;
                                }
                                await state.setAiEnabled(
                                  enabled &&
                                      (state.activeAiProfile?.isReady ?? false),
                                );
                                if (ctx.mounted) Navigator.pop(ctx);
                              } catch (e) {
                                if (context.mounted) {
                                  _toast(
                                    context,
                                    e is ApiException
                                        ? e.message
                                        : e.toString(),
                                    error: true,
                                  );
                                }
                              }
                            },
                            child: const Text('Save'),
                          ),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: TextButton.icon(
                            onPressed: () {
                              Navigator.pop(ctx);
                              state.logout();
                            },
                            icon: const Icon(Icons.logout_rounded),
                            label: const Text('Sign out'),
                          ),
                        ),
                        if (DesktopTray.isSupported) ...[
                          const SizedBox(height: 4),
                          SizedBox(
                            width: double.infinity,
                            child: TextButton.icon(
                              onPressed: () {
                                Navigator.pop(ctx);
                                unawaited(DesktopTray.quit());
                              },
                              icon: const Icon(Icons.power_settings_new_rounded),
                              label: const Text('Quit Privet'),
                            ),
                          ),
                        ],
                        const SizedBox(height: 4),
                        Text(
                          versionLabel.isEmpty
                              ? 'Privet'
                              : 'Privet $versionLabel',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: PrivetTheme.mist,
                            fontSize: 12,
                          ),
                        ),
                        if (updateStatus.supportsInAppUpdate &&
                            updateStatus.updateAvailable) ...[
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: updating
                                  ? null
                                  : () async {
                                      final latest = updateStatus.latest;
                                      final rel = latest?.windowsSetupUrl;
                                      if (rel == null || rel.isEmpty) return;
                                      final origin = state.api.baseUrl
                                          .replaceAll(RegExp(r'/+$'), '');
                                      final setupUrl = rel.startsWith('http')
                                          ? rel
                                          : '$origin${rel.startsWith('/') ? rel : '/$rel'}';
                                      setSheet(() {
                                        updating = true;
                                        updateProgress = 0;
                                      });
                                      try {
                                        await AppUpdate.applyWindowsUpdate(
                                          setupUrl: setupUrl,
                                          onProgress: (p) {
                                            if (ctx.mounted) {
                                              setSheet(
                                                () => updateProgress = p,
                                              );
                                            }
                                          },
                                        );
                                      } catch (e) {
                                        if (ctx.mounted) {
                                          setSheet(() => updating = false);
                                          _toast(
                                            context,
                                            e.toString(),
                                            error: true,
                                          );
                                        }
                                      }
                                    },
                              icon: updating
                                  ? SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        value: updateProgress > 0 &&
                                                updateProgress < 1
                                            ? updateProgress
                                            : null,
                                        color: PrivetTheme.onAccent,
                                      ),
                                    )
                                  : const Icon(Icons.system_update_alt_rounded),
                              label: Text(
                                updating
                                    ? (updateProgress > 0 && updateProgress < 1
                                          ? 'Downloading ${(updateProgress * 100).round()}%'
                                          : 'Installing…')
                                    : 'Update available',
                              ),
                            ),
                          ),
                          Text(
                            'Downloads and installs v${updateStatus.latest?.version ?? ''} automatically, then restarts.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: PrivetTheme.mist,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
    nameCtrl.dispose();
  }

  Future<void> _editAiProfileDialog(
    BuildContext context, {
    AiProfile? existing,
  }) async {
    final keyCtrl = TextEditingController(text: existing?.apiKey ?? '');
    final baseCtrl = TextEditingController(text: existing?.baseUrl ?? '');
    final modelCtrl = TextEditingController(text: existing?.model ?? '');
    var obscure = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDlg) {
            final looksGemini = keyCtrl.text.trim().startsWith('AIza');
            return AlertDialog(
              backgroundColor: PrivetTheme.panelElevated,
              title: Text(
                existing == null ? 'Add AI' : 'Edit AI',
                style: GoogleFonts.syne(fontWeight: FontWeight.w700),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: keyCtrl,
                      obscureText: obscure,
                      autocorrect: false,
                      enableSuggestions: false,
                      onChanged: (_) => setDlg(() {}),
                      decoration: InputDecoration(
                        labelText: 'API key',
                        helperText: looksGemini
                            ? 'Gemini key — base URL not needed'
                            : 'Any OpenAI-compatible or Gemini key',
                        prefixIcon: const Icon(Icons.key_rounded),
                        suffixIcon: IconButton(
                          onPressed: () => setDlg(() => obscure = !obscure),
                          icon: Icon(
                            obscure
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                        ),
                      ),
                    ),
                    if (!looksGemini) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: baseCtrl,
                        autocorrect: false,
                        enableSuggestions: false,
                        keyboardType: TextInputType.url,
                        decoration: const InputDecoration(
                          labelText: 'Base URL',
                          hintText: 'https://api.openai.com/v1',
                          helperText:
                              'Host before /chat/completions — e.g. OpenAI, '
                              'DeepSeek, Groq, OpenRouter, Ollama',
                          prefixIcon: Icon(Icons.link_rounded),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextField(
                      controller: modelCtrl,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: 'Model id',
                        hintText: looksGemini
                            ? 'gemini-2.5-flash-lite'
                            : 'gpt-4o-mini',
                        helperText: 'Exact model name your key should call',
                        prefixIcon: const Icon(Icons.memory_rounded),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
    if (ok == true) {
      try {
        final profile = await state.upsertAiProfile(
          id: existing?.id,
          apiKey: keyCtrl.text,
          model: modelCtrl.text,
          baseUrl: baseCtrl.text,
        );
        await state.setActiveAiProfile(profile.id);
      } catch (e) {
        if (context.mounted) {
          _toast(context, e.toString(), error: true);
        }
      }
    }
    keyCtrl.dispose();
    baseCtrl.dispose();
    modelCtrl.dispose();
  }

  Future<void> _showNewGroup(BuildContext context) async {
    final selected = <String>{};
    final titleCtrl = TextEditingController();
    final searchCtrl = TextEditingController();
    var peopleQuery = '';
    await showPrivetSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: PrivetTheme.panel,
      showDragHandle: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModal) {
            final sheetH = MediaQuery.sizeOf(context).height * 0.75;
            final directory = filterPeople(state.directory, peopleQuery);
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: SizedBox(
                height: sheetH,
                child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                        child: Text(
                          'New group',
                          style: GoogleFonts.syne(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: TextField(
                          controller: titleCtrl,
                          decoration: const InputDecoration(
                            hintText: 'Group name',
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: TextField(
                          controller: searchCtrl,
                          decoration: InputDecoration(
                            hintText: 'Search people',
                            prefixIcon: const Icon(Icons.search_rounded),
                            suffixIcon: peopleQuery.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: 'Clear',
                                    onPressed: () {
                                      searchCtrl.clear();
                                      setModal(() => peopleQuery = '');
                                    },
                                    icon: const Icon(Icons.close_rounded),
                                  ),
                          ),
                          onChanged: (v) => setModal(() => peopleQuery = v),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: directory.isEmpty
                            ? Center(
                                child: Text(
                                  peopleQuery.trim().isEmpty
                                      ? 'No people yet'
                                      : 'No people match “${normalizePeopleQuery(peopleQuery)}”',
                                  style: GoogleFonts.ibmPlexSans(
                                    color: PrivetTheme.mist,
                                  ),
                                ),
                              )
                            : ListView.builder(
                          itemCount: directory.length,
                          addAutomaticKeepAlives: false,
                          itemBuilder: (context, i) {
                            final u = directory[i];
                            final on = selected.contains(u.id);
                            return CheckboxListTile(
                              value: on,
                              onChanged: (v) {
                                setModal(() {
                                  if (v == true) {
                                    selected.add(u.id);
                                  } else {
                                    selected.remove(u.id);
                                  }
                                });
                              },
                              secondary: PrivetAvatar(
                                name: u.displayName,
                                hue: u.avatarHue,
                                online: state.online.contains(u.id),
                              ),
                              title: UserNameBlock.fromUser(u, titleSize: 15),
                              subtitle: Text('@${u.handle}'),
                            );
                          },
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: selected.isEmpty
                                ? null
                                : () async {
                                    Navigator.pop(context);
                                    await state.createGroup(
                                      title: titleCtrl.text.trim().isEmpty
                                          ? 'Group chat'
                                          : titleCtrl.text.trim(),
                                      memberIds: selected.toList(),
                                    );
                                  },
                            child: const Text('Create group'),
                          ),
                        ),
                      ),
                    ],
                ),
              ),
            );
          },
        );
      },
    );
    titleCtrl.dispose();
    searchCtrl.dispose();
  }
}

class _SearchSheet extends StatefulWidget {
  const _SearchSheet({required this.state});

  final PrivetState state;

  @override
  State<_SearchSheet> createState() => _SearchSheetState();
}

class _SearchSheetState extends State<_SearchSheet> {
  final _controller = TextEditingController();
  SearchResults _results = SearchResults.empty();
  bool _busy = false;
  String? _error;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onQueryChanged(String v) {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => _run(v));
  }

  Future<void> _run(String q) async {
    final query = q.trim();
    if (query.isEmpty) {
      setState(() {
        _results = SearchResults.empty();
        _error = null;
        _busy = false;
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final results = await widget.state.search(query);
      if (!mounted || _controller.text.trim() != query) return;
      setState(() {
        _results = results;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is ApiException ? e.message : e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.82,
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: PrivetTheme.line,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: TextField(
                controller: _controller,
                autofocus: true,
                style: GoogleFonts.ibmPlexSans(),
                decoration: InputDecoration(
                  hintText: 'Search people and chats…',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _busy
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : (_controller.text.isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.clear_rounded),
                                onPressed: () {
                                  _controller.clear();
                                  _run('');
                                },
                              )),
                  filled: true,
                  fillColor: PrivetTheme.panelElevated,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: PrivetTheme.line),
                  ),
                ),
                onChanged: _onQueryChanged,
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  _error!,
                  style: TextStyle(color: PrivetTheme.danger),
                ),
              ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
                children: [
                  if (_results.people.isNotEmpty) ...[
                    _sectionLabel('People'),
                    for (final u in _results.people)
                      ListTile(
                        leading: PrivetAvatar(
                          name: u.displayName,
                          hue: u.avatarHue,
                          avatarUrl: u.avatarUrl == null
                              ? null
                              : widget.state.api.absoluteMediaUrl(u.avatarUrl),
                          online: widget.state.online.contains(u.id),
                        ),
                        title: UserNameBlock.fromUser(u, titleSize: 15),
                        subtitle: Text('@${u.handle}'),
                        onTap: () async {
                          Navigator.pop(context);
                          await widget.state.openDm(u);
                        },
                      ),
                  ],
                  if (_results.chats.isNotEmpty) ...[
                    _sectionLabel('Chats'),
                    for (final hit in _results.chats)
                      ListTile(
                        leading: PrivetAvatar(
                          name: hit.title,
                          hue: hit.avatarHue ?? (hit.isGroup ? 90 : 160),
                          avatarUrl: hit.avatarUrl == null
                              ? null
                              : widget.state.api.absoluteMediaUrl(
                                  hit.avatarUrl,
                                ),
                        ),
                        title: Text(hit.title),
                        subtitle: Text(
                          hit.snippet?.trim().isNotEmpty == true
                              ? hit.snippet!
                              : (hit.peerHandle != null
                                    ? '@${hit.peerHandle}'
                                    : (hit.isGroup ? 'Group' : 'Chat')),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () async {
                          Navigator.pop(context);
                          await widget.state.openConversation(
                            hit.conversationId,
                          );
                        },
                      ),
                  ],
                  if (!_busy &&
                      _controller.text.trim().isNotEmpty &&
                      _results.chats.isEmpty &&
                      _results.people.isEmpty)
                    Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No results',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: PrivetTheme.mist),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String label) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 16, 12, 4),
    child: Text(
      label,
      style: GoogleFonts.syne(
        fontWeight: FontWeight.w700,
        color: PrivetTheme.signal,
        fontSize: 13,
      ),
    ),
  );
}

class ConversationPane extends StatefulWidget {
  const ConversationPane({
    super.key,
    required this.state,
    this.showBack = false,
  });

  final PrivetState state;
  final bool showBack;

  @override
  State<ConversationPane> createState() => _ConversationPaneState();
}

class _ConversationPaneState extends State<ConversationPane>
    with SingleTickerProviderStateMixin {
  final _controller = ComposerAutocorrectController();
  final _composerFieldKey = GlobalKey();
  final _composerFocus = FocusNode();
  final _scroll = ScrollController();
  final _recorder = AudioRecorder();
  final _searchController = TextEditingController();
  final _messageKeys = <String, GlobalKey>{};
  final _composerHasContent = ValueNotifier<bool>(false);
  final _draftDebounce = Debouncer(const Duration(milliseconds: 400));
  OverlayEntry? _composerCtxMenu;
  OverlayEntry? _spellingMenu;
  bool _showEmoji = false;
  bool _recording = false;
  bool _showJumpToBottom = false;
  bool _searchOpen = false;
  bool _searchBusy = false;
  List<String> _searchMatchIds = [];
  int _searchMatchIndex = 0;
  Timer? _searchDebounce;
  final List<PickedBytes> _draftMedia = [];
  ChatMessage? _replyingTo;
  List<ComposerSuggestion> _acSuggestions = [];
  int _acIndex = 0;
  int _acReplaceStart = 0;
  int _acReplaceEnd = 0;

  /// Last text seen for autocorrect — skip re-check on fade paint ticks.
  String _lastAutocorrectText = '';

  /// Selected snippet when replying to part of a message (quote preview).
  String? _replySnippet;
  int? _pasteBindId;
  ChatMediaFolderKind? _mediaFolder;
  bool _showTasks = false;
  String? _folderConversationId;
  String? _draftConversationId;
  /// Optimistic until a real call/getUserMedia — never block chat open on
  /// enumerateDevices (Linux WebRTC ADM stall).
  MediaPermissionStatus _mediaPerms = const MediaPermissionStatus(
    hasMicrophone: true,
    hasCamera: true,
    micGranted: true,
    cameraGranted: true,
    canQuery: false,
    hasDisplayCapture: true,
  );

  @override
  void initState() {
    super.initState();
    _folderConversationId = widget.state.activeConversationId;
    _draftConversationId = widget.state.activeConversationId;
    _controller.attachTicker(this);
    _controller.addListener(_onComposerTextChanged);
    _scroll.addListener(_onScrollForOlder);
    HardwareKeyboard.instance.addHandler(_onGlobalKey);
    unawaited(
      ComposerAutocorrectDictionary.instance.ensureLoaded().then((_) {
        if (mounted) _controller.refreshSpelling();
      }),
    );
    _pasteBindId = bindImagePaste((file) {
      if (!mounted || widget.state.activeConversationId == null) return;
      setState(() {
        _draftMedia.add(file);
        _showEmoji = false;
      });
      _syncComposerHasContent();
    });
    registerComposerMediaAttach(_onAnnotatedImageFromLightbox);
    // Do NOT enumerateDevices / init WebRTC ADM on chat open — on Linux+NVIDIA
    // that stalls frame presentation for many seconds (isolate stays alive,
    // fps→0). Probe lazily when the user opens call controls.
    _restoreDraft();
    final surfaceId = widget.state.activeConversationId;
    if (surfaceId != null) widget.state.attachChatSurface(surfaceId);
  }

  /// Ctrl/Cmd+C copies the message-body selection (web CustomPaint has no
  /// native copy). Same result as the floating Copy button.
  bool _onGlobalKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;

    // Mouse-drag select + mouseup outside often leaves an unfocused (inactive)
    // selection. Still honor Backspace/Delete against that range.
    final sel = _controller.selection;
    if (sel.isValid && !sel.isCollapsed) {
      final del =
          event.logicalKey == LogicalKeyboardKey.backspace ||
          event.logicalKey == LogicalKeyboardKey.delete;
      if (del) {
        final next = _controller.text.replaceRange(sel.start, sel.end, '');
        _controller.value = TextEditingValue(
          text: next,
          selection: TextSelection.collapsed(offset: sel.start),
        );
        _composerFocus.requestFocus();
        widget.state.notifyTyping();
        return true;
      }
    }

    if (event.logicalKey != LogicalKeyboardKey.keyC) return false;
    final keys = HardwareKeyboard.instance;
    if (!keys.isControlPressed && !keys.isMetaPressed) return false;
    // Let TextField handle its own range selection.
    if (_composerFocus.hasFocus) {
      if (sel.isValid && !sel.isCollapsed) return false;
    }
    return privetCopyActiveMessageSelection();
  }

  /// Keep composer focused after a drag-select that ends outside the field.
  void _ensureComposerSelectionFocus() {
    final sel = _controller.selection;
    if (!sel.isValid || sel.isCollapsed) return;
    if (!_composerFocus.hasFocus) {
      _composerFocus.requestFocus();
    }
  }

  /// Honest outside-tap handling: keep focus only while the composer itself
  /// has a range selection (drag ended outside the field). Otherwise unfocus
  /// so message-body select doesn't leave a blinking phantom caret, and so a
  /// later click can re-attach the web TextInput connection.
  void _onComposerTapOutside(PointerDownEvent event) {
    _dismissSpellingMenu();
    final sel = _controller.selection;
    if (sel.isValid && !sel.isCollapsed) {
      _ensureComposerSelectionFocus();
      return;
    }
    _composerFocus.unfocus();
  }

  void _onComposerTap() {
    if (_showEmoji) {
      setState(() => _showEmoji = false);
    }
    if (!_composerFocus.hasFocus) {
      _composerFocus.requestFocus();
    }
    // Caret may have moved without a text change.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refreshComposerAutocomplete();
    });
  }

  void _dismissComposerCtxMenu() {
    _composerCtxMenu?.remove();
    _composerCtxMenu = null;
  }

  void _dismissSpellingMenu() {
    _spellingMenu?.remove();
    _spellingMenu = null;
  }

  void _openComposerCtxMenu(Offset globalPos) {
    _dismissSpellingMenu();
    _dismissComposerCtxMenu();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _openComposerCtxMenuAt(globalPos);
    });
  }

  void _openComposerCtxMenuAt(Offset globalPos) {
    _dismissComposerCtxMenu();
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;

    final hasSelection =
        _controller.selection.isValid && !_controller.selection.isCollapsed;

    final media = MediaQuery.sizeOf(context);
    const menuW = 180.0;
    const menuH = 160.0;
    final left = globalPos.dx.clamp(8.0, media.width - menuW - 8);
    final top = globalPos.dy.clamp(8.0, media.height - menuH - 8);

    void paste() {
      var text = AppClipboard.peek();
      if (text == null || text.isEmpty) {
        final selected = privetActiveMessageSelection;
        if (selected != null && selected.isNotEmpty) {
          AppClipboard.remember(selected);
          text = selected;
        }
      }
      if (text != null && text.isNotEmpty) {
        insertTextIntoController(_controller, text);
        _composerFocus.requestFocus();
        widget.state.notifyTyping();
      }
      _dismissComposerCtxMenu();
    }

    void copy() {
      final sel = _controller.selection;
      if (sel.isValid && !sel.isCollapsed) {
        final text = sel.textInside(_controller.text);
        if (text.isNotEmpty) AppClipboard.setText(text);
      }
      _dismissComposerCtxMenu();
    }

    void cut() {
      final s = _controller.selection;
      if (s.isValid && !s.isCollapsed) {
        final t = s.textInside(_controller.text);
        if (t.isNotEmpty) AppClipboard.setText(t);
        final next = _controller.text.replaceRange(s.start, s.end, '');
        _controller.value = TextEditingValue(
          text: next,
          selection: TextSelection.collapsed(offset: s.start),
        );
        widget.state.notifyTyping();
      }
      _dismissComposerCtxMenu();
    }

    _composerCtxMenu = OverlayEntry(
      builder: (ctx) {
        return Stack(
          children: [
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (_) => _dismissComposerCtxMenu(),
              ),
            ),
            Positioned(
              left: left,
              top: top,
              child: TextFieldTapRegion(
                child: Material(
                  elevation: 8,
                  color: const Color(0xFF2C2C30),
                  borderRadius: BorderRadius.circular(8),
                  clipBehavior: Clip.antiAlias,
                  child: SizedBox(
                    width: menuW,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (hasSelection)
                          _ComposerMenuItem(label: 'Cut', onPressed: cut),
                        if (hasSelection)
                          _ComposerMenuItem(label: 'Copy', onPressed: copy),
                        _ComposerMenuItem(label: 'Paste', onPressed: paste),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
    overlay.insert(_composerCtxMenu!);
  }

  void _openSpellingMenu(Offset globalPos, SpellIssue issue) {
    _dismissComposerCtxMenu();
    _dismissSpellingMenu();
    if (issue.suggestions.isEmpty) return;
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;

    final media = MediaQuery.sizeOf(context);
    const menuW = 200.0;
    final menuH = 36.0 + issue.suggestions.length * 40.0 + 8;
    final left = globalPos.dx.clamp(8.0, media.width - menuW - 8);
    final top = globalPos.dy.clamp(8.0, media.height - menuH - 8);

    void applySpell(String suggestion) {
      // Snapshot before any overlay teardown / web click-through.
      final snapshot = _controller.text;
      SpellIssue? live;
      for (final e in _controller.spellIssues) {
        if (e.start == issue.start && e.word == issue.word) {
          live = e;
          break;
        }
      }
      live ??= (snapshot.contains(issue.word) &&
              issue.start >= 0 &&
              issue.end <= snapshot.length &&
              snapshot.substring(issue.start, issue.end) == issue.word)
          ? issue
          : null;
      if (live == null) {
        _dismissSpellingMenu();
        return;
      }

      if (!_composerFocus.hasFocus) {
        _composerFocus.requestFocus();
      }
      var editable = _composerEditableState();

      // Flutter web: clicking the menu can wipe the DOM input under the
      // overlay. Put the draft back, then replace the typo.
      if (_controller.text != snapshot) {
        final restore = TextEditingValue(
          text: snapshot,
          selection: TextSelection.collapsed(offset: snapshot.length),
        );
        if (editable != null) {
          editable.userUpdateTextEditingValue(
            restore,
            SelectionChangedCause.toolbar,
          );
        } else {
          _controller.value = restore;
        }
        editable = _composerEditableState();
      }

      _controller.applySpellSuggestion(
        live,
        suggestion,
        editable: editable,
      );
      _lastAutocorrectText = _controller.text;
      _controller.setHoveredSpellIssue(null);
      widget.state.notifyTyping();
      // Dismiss after this frame so the pointer event doesn't hit the field.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _dismissSpellingMenu();
      });
    }

    _spellingMenu = OverlayEntry(
      builder: (ctx) {
        return Stack(
          children: [
            Positioned.fill(
              child: Listener(
                // Opaque: on web, translucent lets the click reach the
                // composer under the overlay and wipe the draft.
                behavior: HitTestBehavior.opaque,
                onPointerDown: (_) => _dismissSpellingMenu(),
              ),
            ),
            Positioned(
              left: left,
              top: top,
              child: TextFieldTapRegion(
                child: Material(
                  elevation: 8,
                  color: const Color(0xFF2C2C30),
                  borderRadius: BorderRadius.circular(8),
                  clipBehavior: Clip.antiAlias,
                  child: SizedBox(
                    width: menuW,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 10, 16, 4),
                          child: Text(
                            'Spelling',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF9A9AA0),
                              letterSpacing: 0.3,
                            ),
                          ),
                        ),
                        for (final s in issue.suggestions)
                          _ComposerMenuItem(
                            label: s,
                            onPressed: () => applySpell(s),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
    overlay.insert(_spellingMenu!);
  }

  /// Flutter web needs [EditableTextState.userUpdateTextEditingValue] for
  /// reliable composer edits from overlays.
  EditableTextState? _composerEditableState() {
    final ctx = _composerFieldKey.currentContext;
    if (ctx == null) return null;
    EditableTextState? found;
    void walk(Element el) {
      if (found != null) return;
      if (el is StatefulElement && el.state is EditableTextState) {
        found = el.state as EditableTextState;
        return;
      }
      el.visitChildren(walk);
    }

    ctx.visitChildElements(walk);
    return found;
  }

  void _onComposerHover(PointerHoverEvent event) {
    final issue = spellIssueAtGlobal(
      fieldKey: _composerFieldKey,
      controller: _controller,
      globalPos: event.position,
    );
    _controller.setHoveredSpellIssue(issue);
  }

  SpellIssue? _spellClickArmed;

  void _onComposerPointerDown(PointerDownEvent event) {
    if (event.buttons == kSecondaryMouseButton) {
      _spellClickArmed = null;
      _dismissSpellingMenu();
      _controller.setHoveredSpellIssue(null);
      _openComposerCtxMenu(event.position);
      return;
    }
    if (event.buttons != kPrimaryMouseButton) return;

    _dismissComposerCtxMenu();
    // Arm on down; open on up so the TextField (and web DOM input) finish
    // handling the click first — stacking overlays on the glyphs wiped drafts.
    final issue = spellIssueAtGlobal(
      fieldKey: _composerFieldKey,
      controller: _controller,
      globalPos: event.position,
    );
    if (issue != null && issue.suggestions.isNotEmpty) {
      _spellClickArmed = issue;
      _controller.setHoveredSpellIssue(issue);
    } else {
      _spellClickArmed = null;
      _dismissSpellingMenu();
      _controller.setHoveredSpellIssue(null);
    }
  }

  void _onComposerPointerUp(PointerUpEvent event) {
    _ensureComposerSelectionFocus();
    final armed = _spellClickArmed;
    _spellClickArmed = null;
    if (armed == null || armed.suggestions.isEmpty) return;
    // Still the same typo under the pointer?
    final again = spellIssueAtGlobal(
      fieldKey: _composerFieldKey,
      controller: _controller,
      globalPos: event.position,
    );
    if (again == null ||
        again.start != armed.start ||
        again.word != armed.word) {
      return;
    }
    if (_controller.text.isEmpty) return;
    _openSpellingMenu(event.position, again);
  }

  Widget _wrapComposerPointerLayer({required Widget child}) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        return MouseRegion(
          cursor: _controller.hoveredSpellIssue != null
              ? SystemMouseCursors.click
              : SystemMouseCursors.text,
          onHover: _onComposerHover,
          onExit: (_) {
            _spellClickArmed = null;
            if (_spellingMenu == null) {
              _controller.setHoveredSpellIssue(null);
            }
          },
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _onComposerPointerDown,
            onPointerUp: _onComposerPointerUp,
            onPointerCancel: (_) {
              _spellClickArmed = null;
              _ensureComposerSelectionFocus();
            },
            child: child,
          ),
        );
      },
    );
  }

  void _toggleEmoji() {
    final compact = PrivetTheme.isCompact(context);
    if (!compact) {
      setState(() => _showEmoji = !_showEmoji);
      return;
    }
    if (_showEmoji) {
      Navigator.of(context).maybePop();
      setState(() => _showEmoji = false);
      return;
    }
    setState(() => _showEmoji = true);
    showPrivetSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: PrivetTheme.panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final h = MediaQuery.sizeOf(ctx).height * 0.42;
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
          child: CompactEmojiPicker(
            height: h,
            textEditingController: _controller,
            onSelected: (_) => widget.state.notifyTyping(),
          ),
        );
      },
    ).whenComplete(() {
      if (mounted) setState(() => _showEmoji = false);
    });
  }

  Widget _buildChatTitleColumn(PrivetState state, Conversation? chat) {
    final typing = state.typingUserId != null;
    final typingText = typing
        ? state.typingLabel(conversationId: chat?.id)
        : null;
    if (chat?.isGroup == true) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            chat?.title ?? 'Chat',
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
            style: GoogleFonts.syne(fontWeight: FontWeight.w700, fontSize: 18),
          ),
          Text(
            typingText ?? '${chat!.memberCount} members',
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
            style: TextStyle(
              color: typing ? PrivetTheme.signal : PrivetTheme.mist,
              fontSize: 12,
              fontWeight: typing ? FontWeight.w600 : FontWeight.w400,
              fontStyle: typing ? FontStyle.italic : FontStyle.normal,
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          chat?.peer?.displayName ?? chat?.title ?? 'Chat',
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
          style: GoogleFonts.syne(fontWeight: FontWeight.w700, fontSize: 18),
        ),
        Text(
          typingText ??
              [
                if (chat?.peer?.handle.isNotEmpty == true)
                  '@${chat!.peer!.handle}',
                if (chat?.peer != null) state.presenceLabel(chat!.peer!.id),
              ].whereType<String>().join(' · '),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
          style: TextStyle(
            color: typing
                ? PrivetTheme.signal
                : (chat?.peer?.handle.isNotEmpty == true
                    ? PrivetTheme.signal
                    : PrivetTheme.mist),
            fontSize: 12,
            fontWeight: FontWeight.w600,
            fontStyle: typing ? FontStyle.italic : FontStyle.normal,
          ),
        ),
      ],
    );
  }

  void _toggleSearch() {
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) {
        _searchMatchIds = [];
        _searchMatchIndex = 0;
        _searchController.clear();
      }
    });
  }

  void _toggleMediaFolder() {
    setState(() {
      if (_mediaFolder != null) {
        _mediaFolder = null;
      } else {
        _showTasks = false;
        _mediaFolder = ChatMediaFolderKind.photos;
      }
    });
  }

  void _toggleTasks() {
    setState(() {
      _mediaFolder = null;
      _showTasks = !_showTasks;
    });
  }

  Future<void> _showChatMoreSheet(PrivetState state, Conversation? chat) async {
    await showPrivetSheet<void>(
      context: context,
      backgroundColor: PrivetTheme.panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: PrivetTheme.line,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                ListTile(
                  leading: Icon(
                    Icons.screen_share_rounded,
                    color: _mediaPerms.screenReady
                        ? PrivetTheme.signal
                        : PrivetTheme.mist,
                  ),
                  title: const Text('Share screen'),
                  subtitle: Text(
                    _mediaPerms.canStartScreen
                        ? 'Capture display — no camera needed'
                        : 'Not supported in this browser',
                    style: TextStyle(color: PrivetTheme.mist, fontSize: 12),
                  ),
                  enabled: _mediaPerms.canStartScreen,
                  onTap: () {
                    Navigator.pop(ctx);
                    _startCall('screen');
                  },
                ),
                ListTile(
                  leading: Icon(
                    Icons.mouse_rounded,
                    color: PrivetTheme.signal,
                  ),
                  title: const Text('Remote control'),
                  subtitle: Text(
                    'Ask to control their desktop — they must use the Privet app',
                    style: TextStyle(color: PrivetTheme.mist, fontSize: 12),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _startCall('control');
                  },
                ),
                ListTile(
                  leading: Icon(
                    Icons.folder_outlined,
                    color: PrivetTheme.signal,
                  ),
                  title: const Text('Shared media'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _toggleMediaFolder();
                  },
                ),
                ListTile(
                  leading: Icon(
                    Icons.checklist_rtl_rounded,
                    color: _showTasks ? PrivetTheme.signal : PrivetTheme.mist,
                  ),
                  title: Text(_showTasks ? 'Hide tasks' : 'Tasks'),
                  subtitle: Text(() {
                    final board = state.taskBoardFor(
                      state.activeConversationId,
                    );
                    return board.isComplete
                        ? 'All done'
                        : '${board.doneCount}/${board.total} done';
                  }(), style: TextStyle(color: PrivetTheme.mist, fontSize: 12)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _toggleTasks();
                  },
                ),
                if (chat?.isGroup == true)
                  ListTile(
                    leading: const Icon(Icons.group_rounded),
                    title: const Text('Manage members'),
                    onTap: () {
                      Navigator.pop(ctx);
                      _manageMembers();
                    },
                  ),
                if (chat != null && chat.isOwnedBy(state.user?.id))
                  ListTile(
                    leading: Icon(
                      Icons.delete_outline_rounded,
                      color: PrivetTheme.danger,
                    ),
                    title: Text(
                      'Delete group',
                      style: TextStyle(color: PrivetTheme.danger),
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      _deleteGroup();
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  List<Widget> _buildDesktopChatHeaderActions(
    PrivetState state,
    Conversation? chat,
  ) {
    return [
      IconButton(
        tooltip: 'Search in chat',
        onPressed: _toggleSearch,
        icon: Icon(
          _searchOpen ? Icons.search_off_rounded : Icons.search_rounded,
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(right: 4),
        child: TaskHeaderChip(
          board: state.taskBoardFor(state.activeConversationId),
          active: _showTasks,
          onTap: _toggleTasks,
        ),
      ),
      _CallActionButton(
        tooltip: 'Shared media',
        icon: Icons.folder_outlined,
        active: true,
        enabled: true,
        onPressed: _toggleMediaFolder,
      ),
      _CallActionButton(
        tooltip: _mediaPerms.canStartAudio
            ? (_mediaPerms.audioReady
                  ? 'Audio call'
                  : 'Allow microphone access to start audio calls')
            : 'No microphone detected — connect one to call',
        caution: !_mediaPerms.canStartAudio,
        icon: Icons.call_rounded,
        active: _mediaPerms.audioReady,
        enabled: _mediaPerms.canStartAudio,
        onPressed: () => _startCall('audio'),
      ),
      _CallActionButton(
        tooltip: !_mediaPerms.hasCamera
            ? 'No camera detected — connect one for video calls'
            : !_mediaPerms.hasMicrophone
            ? 'No microphone detected — needed for video calls'
            : _mediaPerms.videoReady
            ? 'Video call'
            : !_mediaPerms.cameraGranted
            ? 'Allow camera access to start video calls'
            : 'Allow microphone access to start video calls',
        caution: !_mediaPerms.hasCamera || !_mediaPerms.hasMicrophone,
        icon: Icons.videocam_rounded,
        active: _mediaPerms.videoReady,
        enabled: _mediaPerms.canStartVideo,
        onPressed: () => _startCall('video'),
      ),
      _CallActionButton(
        tooltip: _mediaPerms.canStartScreen
            ? 'Share screen (captures display — no camera needed)'
            : 'Screen share is not supported in this browser',
        icon: Icons.screen_share_rounded,
        active: _mediaPerms.screenReady,
        enabled: _mediaPerms.canStartScreen,
        onPressed: () => _startCall('screen'),
      ),
      _CallActionButton(
        tooltip:
            'Ask to control their desktop (they must use the Linux/Windows Privet app)',
        icon: Icons.mouse_rounded,
        active: true,
        enabled: true,
        onPressed: () => _startCall('control'),
      ),
      if (chat?.isGroup == true)
        IconButton(
          tooltip: 'Manage members',
          onPressed: _manageMembers,
          icon: const Icon(Icons.group_rounded),
        ),
      if (chat != null && chat.isOwnedBy(state.user?.id))
        IconButton(
          tooltip: 'Delete group',
          onPressed: _deleteGroup,
          icon: Icon(Icons.delete_outline_rounded, color: PrivetTheme.danger),
        ),
    ];
  }

  /// Mobile: every primary action stays visible — no horizontal scroll.
  Widget _buildMobileChatHeader(PrivetState state, Conversation? chat) {
    return Row(
      children: [
        if (widget.showBack)
          IconButton(
            onPressed: state.clearActiveConversation,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
        PrivetAvatar(
          name: chat?.title ?? 'Chat',
          hue: chat?.peer?.avatarHue ?? (chat?.isGroup == true ? 90 : 160),
          avatarUrl: chat?.peer?.avatarUrl == null
              ? null
              : state.api.absoluteMediaUrl(chat!.peer!.avatarUrl),
          online: chat?.peer != null && state.online.contains(chat!.peer!.id),
          size: 36,
        ),
        const SizedBox(width: 10),
        Expanded(child: _buildChatTitleColumn(state, chat)),
        IconButton(
          tooltip: 'Search in chat',
          onPressed: _toggleSearch,
          icon: Icon(
            _searchOpen ? Icons.search_off_rounded : Icons.search_rounded,
          ),
        ),
        _CallActionButton(
          tooltip: _mediaPerms.canStartAudio
              ? (_mediaPerms.audioReady
                    ? 'Audio call'
                    : 'Allow microphone access to start audio calls')
              : 'No microphone detected — connect one to call',
          caution: !_mediaPerms.canStartAudio,
          icon: Icons.call_rounded,
          active: _mediaPerms.audioReady,
          enabled: _mediaPerms.canStartAudio,
          onPressed: () => _startCall('audio'),
        ),
        _CallActionButton(
          tooltip: !_mediaPerms.hasCamera
              ? 'No camera detected — connect one for video calls'
              : !_mediaPerms.hasMicrophone
              ? 'No microphone detected — needed for video calls'
              : _mediaPerms.videoReady
              ? 'Video call'
              : !_mediaPerms.cameraGranted
              ? 'Allow camera access to start video calls'
              : 'Allow microphone access to start video calls',
          caution: !_mediaPerms.hasCamera || !_mediaPerms.hasMicrophone,
          icon: Icons.videocam_rounded,
          active: _mediaPerms.videoReady,
          enabled: _mediaPerms.canStartVideo,
          onPressed: () => _startCall('video'),
        ),
        IconButton(
          tooltip: 'More',
          onPressed: () => _showChatMoreSheet(state, chat),
          icon: const Icon(Icons.more_vert_rounded),
        ),
      ],
    );
  }

  bool get _composerHasContentNow =>
      _controller.text.trim().isNotEmpty ||
      _draftMedia.isNotEmpty ||
      _recording;

  void _onComposerTextChanged() {
    if (_controller.isApplying) return;
    _syncComposerHasContent();
    _draftDebounce(_persistDraft);
    _controller.syncAfterEdit();
    _refreshComposerAutocomplete();
    final text = _controller.text;
    if (text != _lastAutocorrectText) {
      _dismissSpellingMenu();
    }
    if (text == _lastAutocorrectText) return;
    // Apply after this frame so Flutter web has a settled caret/selection.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _controller.isApplying) return;
      if (_controller.text != text) return; // newer edit superseded this
      _maybeApplyEmoticonExpand();
      if (!mounted || _controller.isApplying) return;
      _lastAutocorrectText = _controller.text;
      _maybeApplyAutocorrect();
    });
  }

  void _maybeApplyEmoticonExpand() {
    if (_controller.isApplying) return;
    // Parenthetical typeahead owns `(partial` tokens — don't fight it.
    if (_acSuggestions.isNotEmpty) return;

    final value = _controller.value;
    final text = value.text;
    final sel = value.selection;
    final int cursor;
    if (sel.isValid && sel.isCollapsed) {
      cursor = sel.baseOffset;
    } else if (text.isNotEmpty && _looksLikeWordBoundary(text[text.length - 1])) {
      cursor = text.length;
    } else {
      return;
    }

    final expand = tryExpandEmoticonAtCursor(text, cursor);
    if (expand == null) return;

    _controller.applySilentReplacement(
      start: expand.replaceStart,
      end: expand.replaceEnd,
      replacement: expand.emoji,
      caretAfter: cursor,
    );
    _lastAutocorrectText = _controller.text;
    widget.state.notifyTyping();
  }

  void _maybeApplyAutocorrect() {
    if (_controller.isApplying) return;
    // Curated typos work immediately; frequency list loads in background.
    if (!ComposerAutocorrectDictionary.instance.isReady) {
      unawaited(
        ComposerAutocorrectDictionary.instance.ensureLoaded().then((_) {
          if (mounted) _maybeApplyAutocorrect();
        }),
      );
    }
    final value = _controller.value;
    final text = value.text;
    final sel = value.selection;
    // Flutter web sometimes reports an invalid selection right after a key.
    // If the buffer ends on a word boundary, treat the caret as at the end.
    final int cursor;
    if (sel.isValid && sel.isCollapsed) {
      cursor = sel.baseOffset;
    } else if (text.isNotEmpty && _looksLikeWordBoundary(text[text.length - 1])) {
      cursor = text.length;
    } else {
      return;
    }
    // Emoticon / AI typeahead owns this token — don't fight it.
    if (_acSuggestions.isNotEmpty) return;
    final attempt = ComposerAutocorrectDictionary.instance.tryAutocorrect(
      text,
      cursor,
    );
    if (attempt == null) return;
    _controller.applyCorrection(attempt, caretAfter: cursor);
    _lastAutocorrectText = _controller.text;
    widget.state.notifyTyping();
  }

  bool _looksLikeWordBoundary(String ch) {
    return ch == ' ' ||
        ch == '\n' ||
        ch == '\t' ||
        ch == '.' ||
        ch == ',' ||
        ch == '!' ||
        ch == '?' ||
        ch == ';' ||
        ch == ':';
  }

  void _clearComposerAutocomplete() {
    if (_acSuggestions.isEmpty) return;
    setState(() {
      _acSuggestions = [];
      _acIndex = 0;
    });
  }

  void _refreshComposerAutocomplete() {
    final value = _controller.value;
    final sel = value.selection;
    if (!sel.isValid || !sel.isCollapsed) {
      _clearComposerAutocomplete();
      return;
    }
    final match = matchComposerAutocomplete(
      value.text,
      sel.baseOffset,
      aiEnabled: widget.state.aiActive,
    );
    if (match == null || match.suggestions.isEmpty) {
      _clearComposerAutocomplete();
      return;
    }
    final same =
        _acSuggestions.length == match.suggestions.length &&
        _acReplaceStart == match.replaceStart &&
        _acReplaceEnd == match.replaceEnd &&
        _listEqualsSuggestions(_acSuggestions, match.suggestions);
    if (same) return;
    setState(() {
      _acSuggestions = match.suggestions;
      _acReplaceStart = match.replaceStart;
      _acReplaceEnd = match.replaceEnd;
      _acIndex = 0;
    });
  }

  bool _listEqualsSuggestions(
    List<ComposerSuggestion> a,
    List<ComposerSuggestion> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].label != b[i].label || a[i].insert != b[i].insert) {
        return false;
      }
    }
    return true;
  }

  void _acceptComposerAutocomplete([int? index]) {
    final i = index ?? _acIndex;
    if (i < 0 || i >= _acSuggestions.length) return;
    final suggestion = _acSuggestions[i];
    final text = _controller.text;
    final start = _acReplaceStart.clamp(0, text.length);
    final end = _acReplaceEnd.clamp(start, text.length);
    final next = text.replaceRange(start, end, suggestion.insert);
    final caret = start + suggestion.insert.length;
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: caret),
    );
    _composerFocus.requestFocus();
    widget.state.notifyTyping();
    // Listener refreshes / clears suggestions from the new text.
  }

  /// Composer key handling: autocomplete, Backspace-undo for autocorrect, Enter-to-send.
  KeyEventResult _handleComposerKeyEvent(KeyEvent event) {
    if (_handleComposerAutocompleteKey(event)) {
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      if (_controller.tryUndoWithBackspace()) {
        _lastAutocorrectText = _controller.text;
        widget.state.notifyTyping();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    final isEnter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (!isEnter) return KeyEventResult.ignored;
    if (HardwareKeyboard.instance.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    _send();
    return KeyEventResult.handled;
  }

  /// Handles Tab / arrows / Enter / Escape while the autocomplete popup is open.
  /// Returns true when the key was consumed.
  bool _handleComposerAutocompleteKey(KeyEvent event) {
    if (_acSuggestions.isEmpty) return false;
    if (event is! KeyDownEvent) return false;

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _clearComposerAutocomplete();
      return true;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() {
        _acIndex = (_acIndex + 1) % _acSuggestions.length;
      });
      return true;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      setState(() {
        _acIndex =
            (_acIndex - 1 + _acSuggestions.length) % _acSuggestions.length;
      });
      return true;
    }
    if (key == LogicalKeyboardKey.tab) {
      _acceptComposerAutocomplete();
      return true;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (HardwareKeyboard.instance.isShiftPressed) return false;
      _acceptComposerAutocomplete();
      return true;
    }
    return false;
  }

  void _syncComposerHasContent() {
    final has = _composerHasContentNow;
    if (_composerHasContent.value != has) {
      _composerHasContent.value = has;
    }
  }

  Future<void> _restoreDraft() async {
    final id = widget.state.activeConversationId;
    if (id == null) return;
    final draft = await widget.state.loadDraft(id);
    if (!mounted || widget.state.activeConversationId != id) return;
    if (draft.isEmpty) return;
    _controller.removeListener(_onComposerTextChanged);
    _controller.text = draft;
    _controller.selection = TextSelection.collapsed(offset: draft.length);
    _controller.addListener(_onComposerTextChanged);
    _composerHasContent.value = _composerHasContentNow;
    setState(() {});
  }

  void _persistDraft() {
    final id = _draftConversationId;
    if (id == null) return;
    widget.state.saveDraft(id, _controller.text);
  }

  @override
  void didUpdateWidget(covariant ConversationPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncFolderConversation();
  }

  void _syncFolderConversation() {
    final id = widget.state.activeConversationId;
    if (id != _folderConversationId) {
      _folderConversationId = id;
      _mediaFolder = null;
      _showTasks = false;
      _searchDebounce?.cancel();
      _searchOpen = false;
      _searchBusy = false;
      _searchMatchIds = [];
      _searchMatchIndex = 0;
      _searchController.clear();
      _messageKeys.clear();
    }
  }

  Future<void> _refreshMediaPermissions() async {
    final status = await queryMediaPermissions();
    if (!mounted) return;
    setState(() => _mediaPerms = status);
  }

  @override
  void dispose() {
    cancelMediaDeviceChanges();
    final id = _draftConversationId;
    if (id != null) widget.state.detachChatSurface(id);
    _draftDebounce.flush(_persistDraft);
    HardwareKeyboard.instance.removeHandler(_onGlobalKey);
    _dismissComposerCtxMenu();
    _dismissSpellingMenu();
    _controller.removeListener(_onComposerTextChanged);
    _scroll.removeListener(_onScrollForOlder);
    _searchDebounce?.cancel();
    unbindImagePaste(_pasteBindId);
    registerComposerMediaAttach(null);
    _controller.dispose();
    _composerFocus.dispose();
    _scroll.dispose();
    _searchController.dispose();
    _composerHasContent.dispose();
    _recorder.dispose();
    super.dispose();
  }

  void _onAnnotatedImageFromLightbox(PickedBytes file) {
    if (!mounted || widget.state.activeConversationId == null) return;
    _applyPickedFile(file);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _composerFocus.requestFocus();
    });
  }

  void _onScrollForOlder() {
    if (!_scroll.hasClients) return;
    // reverse: true → pixels ~0 means pinned to the newest message.
    final shouldShowJump = _scroll.position.pixels > 400;
    if (shouldShowJump != _showJumpToBottom) {
      setState(() => _showJumpToBottom = shouldShowJump);
    }
    final id = widget.state.activeConversationId;
    if (id == null) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 120) {
      unawaited(widget.state.loadOlderMessages(id));
    }
  }

  void _closeSearch() {
    _searchDebounce?.cancel();
    setState(() {
      _searchOpen = false;
      _searchBusy = false;
      _searchMatchIds = [];
      _searchMatchIndex = 0;
      _searchController.clear();
    });
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 280), () {
      unawaited(_runChatSearch(value));
    });
  }

  Future<void> _runChatSearch(String raw) async {
    final chatId = widget.state.activeConversationId;
    final query = raw.trim();
    if (chatId == null) return;
    if (query.isEmpty) {
      if (!mounted) return;
      setState(() {
        _searchMatchIds = [];
        _searchMatchIndex = 0;
        _searchBusy = false;
      });
      return;
    }
    setState(() => _searchBusy = true);
    try {
      final hits = await widget.state.searchInConversation(chatId, query);
      if (!mounted || widget.state.activeConversationId != chatId) return;
      if (_searchController.text.trim() != query) return;
      final ids = hits.map((m) => m.id).toList();
      setState(() {
        _searchMatchIds = ids;
        _searchMatchIndex = 0;
        _searchBusy = false;
      });
      if (ids.isNotEmpty) {
        await _jumpToSearchMatch(0);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _searchBusy = false);
    }
  }

  Future<void> _jumpToSearchMatch(int index) async {
    if (_searchMatchIds.isEmpty) return;
    final chatId = widget.state.activeConversationId;
    if (chatId == null) return;
    final safe =
        ((index % _searchMatchIds.length) + _searchMatchIds.length) %
        _searchMatchIds.length;
    final messageId = _searchMatchIds[safe];
    if (_searchMatchIndex != safe) {
      setState(() => _searchMatchIndex = safe);
    } else {
      setState(() {}); // refresh highlight even when staying on same index
    }

    await widget.state.ensureMessageLoaded(chatId, messageId);
    if (!mounted || widget.state.activeConversationId != chatId) return;

    // Reverse ListView only builds visible rows — GlobalKeys for off-screen
    // matches have null context. Jump near the index first, then ensureVisible.
    for (var attempt = 0; attempt < 24; attempt++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !_scroll.hasClients) return;

      final messages =
          widget.state.messagesByChat[chatId] ?? const <ChatMessage>[];
      final dataIndex = messages.indexWhere((m) => m.id == messageId);
      if (dataIndex < 0) return;

      // reverse: true → builder index 0 is newest (messages.last)
      final builderIndex = messages.length - 1 - dataIndex;
      final keyCtx = _messageKeys[messageId]?.currentContext;
      if (keyCtx != null && keyCtx.mounted) {
        final renderObject = keyCtx.findRenderObject();
        if (renderObject != null) {
          await _scroll.position.ensureVisible(
            renderObject,
            alignment: 0.4,
            duration: attempt == 0
                ? Duration.zero
                : privetAnim(const Duration(milliseconds: 220)),
            curve: Curves.easeOutCubic,
          );
        }
        // Variable-height bubbles: one settle pass.
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;
        final settled = _messageKeys[messageId]?.currentContext;
        final settledRo = settled?.findRenderObject();
        if (settledRo != null && settled != null && settled.mounted) {
          await _scroll.position.ensureVisible(
            settledRo,
            alignment: 0.4,
            duration: privetAnim(const Duration(milliseconds: 120)),
            curve: Curves.easeOutCubic,
          );
        }
        if (mounted) setState(() {});
        return;
      }

      final max = _scroll.position.maxScrollExtent;
      final denom = messages.length <= 1
          ? 1.0
          : (messages.length - 1).toDouble();
      // Prefer average extent once the list has laid out some content.
      final avg = max > 0 && messages.isNotEmpty
          ? (max / denom).clamp(48.0, 220.0)
          : 96.0;
      final estimated = (builderIndex * avg).clamp(0.0, max);
      final current = _scroll.position.pixels;
      if ((estimated - current).abs() > 12) {
        _scroll.jumpTo(estimated);
      } else {
        // Near estimate but item still not built — step toward older/newer.
        final direction = builderIndex > (messages.length / 2) ? 1.0 : -1.0;
        final step = 180.0 * (1 + attempt ~/ 3) * direction;
        _scroll.jumpTo((current + step).clamp(0.0, max));
      }
    }
  }

  void _searchStep(int delta) {
    if (_searchMatchIds.isEmpty) return;
    final next = _searchMatchIndex + delta;
    final normalized =
        ((next % _searchMatchIds.length) + _searchMatchIds.length) %
        _searchMatchIds.length;
    unawaited(_jumpToSearchMatch(normalized));
  }

  Conversation? get _chat {
    final id = widget.state.activeConversationId;
    if (id == null) return null;
    for (final c in widget.state.conversations) {
      if (c.id == id) return c;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final compact = PrivetTheme.isCompact(context);
    _syncFolderConversation();
    final chat = _chat;
    final messages = state.messagesByChat[state.activeConversationId] ?? [];
    final mediaBase = state.api.baseUrl;
    final desktopActions = _buildDesktopChatHeaderActions(state, chat);

    return ColoredBox(
      color: PrivetTheme.panel,
      child: Column(
        children: [
          SafeArea(
            bottom: false,
            child: Container(
              padding: EdgeInsets.fromLTRB(
                compact ? 2 : 8,
                compact ? 4 : 8,
                compact ? 2 : 8,
                compact ? 4 : 8,
              ),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: PrivetTheme.line)),
              ),
              child: compact
                  ? _buildMobileChatHeader(state, chat)
                  : Row(
                      children: [
                        if (widget.showBack)
                          IconButton(
                            onPressed: state.clearActiveConversation,
                            icon: const Icon(Icons.arrow_back_rounded),
                          ),
                        PrivetAvatar(
                          name: chat?.title ?? 'Chat',
                          hue:
                              chat?.peer?.avatarHue ??
                              (chat?.isGroup == true ? 90 : 160),
                          avatarUrl: chat?.peer?.avatarUrl == null
                              ? null
                              : state.api.absoluteMediaUrl(
                                  chat!.peer!.avatarUrl,
                                ),
                          online:
                              chat?.peer != null &&
                              state.online.contains(chat!.peer!.id),
                        ),
                        const SizedBox(width: 12),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 200),
                          child: _buildChatTitleColumn(state, chat),
                        ),
                        const Spacer(),
                        ...desktopActions,
                      ],
                    ),
            ),
          ),
          if (_searchOpen)
            Container(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: PrivetTheme.line)),
              ),
              child: compact
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          controller: _searchController,
                          autofocus: true,
                          style: GoogleFonts.ibmPlexSans(fontSize: 14),
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: 'Search messages in this chat…',
                            prefixIcon: const Icon(
                              Icons.search_rounded,
                              size: 20,
                            ),
                            suffixIcon: _searchBusy
                                ? const Padding(
                                    padding: EdgeInsets.all(12),
                                    child: SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  )
                                : (_searchController.text.isEmpty
                                      ? null
                                      : IconButton(
                                          icon: const Icon(Icons.clear_rounded),
                                          onPressed: () {
                                            _searchController.clear();
                                            _onSearchChanged('');
                                            setState(() {});
                                          },
                                        )),
                            filled: true,
                            fillColor: PrivetTheme.panelElevated,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: BorderSide(color: PrivetTheme.line),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 10,
                            ),
                          ),
                          onChanged: (v) {
                            setState(() {});
                            _onSearchChanged(v);
                          },
                        ),
                        if (_searchMatchIds.isNotEmpty)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              Text(
                                '${_searchMatchIndex + 1}/${_searchMatchIds.length}',
                                style: GoogleFonts.ibmPlexSans(
                                  fontSize: 12,
                                  color: PrivetTheme.mist,
                                ),
                              ),
                              IconButton(
                                tooltip: 'Older match',
                                onPressed: () => _searchStep(1),
                                icon: const Icon(
                                  Icons.keyboard_arrow_up_rounded,
                                ),
                              ),
                              IconButton(
                                tooltip: 'Newer match',
                                onPressed: () => _searchStep(-1),
                                icon: const Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                ),
                              ),
                              IconButton(
                                tooltip: 'Close search',
                                onPressed: _closeSearch,
                                icon: const Icon(Icons.close_rounded),
                              ),
                            ],
                          )
                        else
                          Align(
                            alignment: Alignment.centerRight,
                            child: IconButton(
                              tooltip: 'Close search',
                              onPressed: _closeSearch,
                              icon: const Icon(Icons.close_rounded),
                            ),
                          ),
                      ],
                    )
                  : Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _searchController,
                            autofocus: true,
                            style: GoogleFonts.ibmPlexSans(fontSize: 14),
                            decoration: InputDecoration(
                              isDense: true,
                              hintText: 'Search messages in this chat…',
                              prefixIcon: const Icon(
                                Icons.search_rounded,
                                size: 20,
                              ),
                              suffixIcon: _searchBusy
                                  ? const Padding(
                                      padding: EdgeInsets.all(12),
                                      child: SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      ),
                                    )
                                  : (_searchController.text.isEmpty
                                        ? null
                                        : IconButton(
                                            icon: const Icon(
                                              Icons.clear_rounded,
                                            ),
                                            onPressed: () {
                                              _searchController.clear();
                                              _onSearchChanged('');
                                              setState(() {});
                                            },
                                          )),
                              filled: true,
                              fillColor: PrivetTheme.panelElevated,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide(color: PrivetTheme.line),
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 10,
                              ),
                            ),
                            onChanged: (v) {
                              setState(() {});
                              _onSearchChanged(v);
                            },
                          ),
                        ),
                        if (_searchMatchIds.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Text(
                            '${_searchMatchIndex + 1}/${_searchMatchIds.length}',
                            style: GoogleFonts.ibmPlexSans(
                              fontSize: 12,
                              color: PrivetTheme.mist,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Older match',
                            onPressed: () => _searchStep(1),
                            icon: const Icon(Icons.keyboard_arrow_up_rounded),
                          ),
                          IconButton(
                            tooltip: 'Newer match',
                            onPressed: () => _searchStep(-1),
                            icon: const Icon(Icons.keyboard_arrow_down_rounded),
                          ),
                        ],
                        IconButton(
                          tooltip: 'Close search',
                          onPressed: _closeSearch,
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
            ),
          if (_mediaFolder != null)
            Expanded(
              child: ChatMediaFolderPane(
                folder: _mediaFolder!,
                messages: messages,
                mediaBase: mediaBase,
                onClose: () => setState(() => _mediaFolder = null),
                onSelectFolder: (kind) => setState(() {
                  _showTasks = false;
                  _mediaFolder = kind;
                }),
              ),
            )
          else if (_showTasks && state.activeConversationId != null)
            Expanded(
              child: ChatTaskPane(
                state: state,
                conversationId: state.activeConversationId!,
                mediaBase: mediaBase,
                onClose: () => setState(() => _showTasks = false),
              ),
            )
          else ...[
            Expanded(
              child: Stack(
                children: [
                  Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerUp: (_) {
                      // Text body claims the pointer on down (child runs first).
                      // Do not clear selection for those gestures — that was wiping
                      // the Copy/Reply/Forward bar immediately after every drag.
                      if (privetMessageSelectionDragging) return;
                      if (privetMessageBodyClaimedPointer) {
                        privetMessageBodyClaimedPointer = false;
                        return;
                      }
                      privetClearMessageSelection();
                    },
                    onPointerCancel: (_) {
                      privetMessageBodyClaimedPointer = false;
                    },
                    child: ListView.builder(
                      controller: _scroll,
                      reverse: true,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      itemCount:
                          messages.length +
                          ((state.activeConversationId != null &&
                                  state.loadingOlder.contains(
                                    state.activeConversationId,
                                  ))
                              ? 1
                              : 0),
                      itemBuilder: (context, i) {
                        final loadingOlder =
                            state.activeConversationId != null &&
                            state.loadingOlder.contains(
                              state.activeConversationId,
                            );
                        if (loadingOlder && i == messages.length) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Center(
                              child: SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                          );
                        }
                        // reverse: true → index 0 is newest (bottom); open lands on last message
                        final actualIndex = messages.length - 1 - i;
                        final m = messages[actualIndex];
                        final mine = m.sender.id == state.user?.id;
                        final key = _messageKeys.putIfAbsent(
                          m.id,
                          GlobalKey.new,
                        );
                        final highlighted =
                            _searchMatchIds.isNotEmpty &&
                            _searchMatchIds[_searchMatchIndex] == m.id;
                        // Day separator sits above the first message of each day.
                        final showDaySeparator =
                            actualIndex == 0 ||
                            !_sameDay(
                              messages[actualIndex - 1].createdAt,
                              m.createdAt,
                            );
                        final bubble = MessageBubble(
                          message: m,
                          mine: mine,
                          mediaBase: mediaBase,
                          selfId: state.user?.id,
                          showSender: true,
                          highlighted: highlighted,
                          readByPeer:
                              mine &&
                              (chat?.isReadByPeer(m, selfId: state.user?.id) ??
                                  false),
                          seenByLabel: mine && chat?.isGroup == true
                              ? _seenByShort(chat!, m, state)
                              : null,
                          onReply: (msg, {selectedText}) {
                            final snippet =
                                (selectedText != null &&
                                    selectedText.trim().isNotEmpty)
                                ? selectedText.trim()
                                : null;
                            setState(() {
                              _replyingTo = msg;
                              _replySnippet = snippet;
                              _showEmoji = false;
                            });
                            // Selection belongs only in the reply bar, not the draft.
                            if (snippet != null) {
                              _controller.clear();
                            }
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) _composerFocus.requestFocus();
                            });
                          },
                          onForward: (msg, {selectedText}) =>
                              _forwardMessage(context, msg),
                          onSeenBy: chat?.isGroup == true
                              ? (msg) => _showSeenBy(context, chat!, msg)
                              : null,
                          onReact: (msg, emoji) =>
                              state.toggleReaction(msg.id, emoji),
                          onAddToTask: (msg) async {
                            await state.addMessageToTask(msg);
                            if (!mounted) return;
                            setState(() {
                              _mediaFolder = null;
                              _showTasks = true;
                            });
                          },
                          aiActive: state.aiActive,
                          onAskAi: (msg) => _askAiAboutMessage(context, msg),
                          onEdit: mine ? (msg) => _editMessage(msg) : null,
                          onDelete: mine ? (msg) => _deleteMessage(msg) : null,
                        );
                        return KeyedSubtree(
                          key: key,
                          child: RepaintBoundary(
                            child: showDaySeparator
                                ? Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _DaySeparator(
                                        label: _dayLabel(m.createdAt),
                                      ),
                                      bubble,
                                    ],
                                  )
                                : bubble,
                          ),
                        );
                      },
                    ),
                  ),
                  Positioned(
                    right: 16,
                    bottom: 16,
                    child: AnimatedSlide(
                      duration: privetAnim(const Duration(milliseconds: 180)),
                      offset: _showJumpToBottom
                          ? Offset.zero
                          : const Offset(0, 1.5),
                      child: AnimatedOpacity(
                        duration: privetAnim(const Duration(milliseconds: 180)),
                        opacity: _showJumpToBottom ? 1 : 0,
                        child: IgnorePointer(
                          ignoring: !_showJumpToBottom,
                          child: Material(
                            color: PrivetTheme.panelElevated,
                            shape: CircleBorder(
                              side: BorderSide(color: PrivetTheme.line),
                            ),
                            elevation: privetElevation(3),
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: _scrollToEnd,
                              child: SizedBox(
                                width: 44,
                                height: 44,
                                child: Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                  color: PrivetTheme.paper,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (state.uploading)
              LinearProgressIndicator(
                minHeight: 2,
                color: PrivetTheme.signal,
                backgroundColor: PrivetTheme.line,
              ),
            if (state.typingUserId != null)
              TypingIndicatorBubble(
                label: chat?.isGroup == true
                    ? state.typingLabel(conversationId: chat?.id)
                    : null,
              ),
            if (_recording)
              Container(
                width: double.infinity,
                color: PrivetTheme.danger.withValues(alpha: 0.15),
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Recording… tap mic again to send',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: PrivetTheme.danger),
                ),
              ),
            if (_draftMedia.isNotEmpty) _buildDraftPreview(),
            if (_replyingTo != null) _buildReplyBar(),
            if (_acSuggestions.isNotEmpty)
              Padding(
                padding: EdgeInsets.fromLTRB(
                  compact ? 6 : 8,
                  0,
                  compact ? 6 : 8,
                  4,
                ),
                child: TextFieldTapRegion(
                  child: ComposerAutocompletePopup(
                    suggestions: _acSuggestions,
                    selectedIndex: _acIndex,
                    onSelect: _acceptComposerAutocomplete,
                  ),
                ),
              ),
            SafeArea(
              top: false,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  compact ? 6 : 8,
                  compact ? 6 : 8,
                  compact ? 6 : 8,
                  compact ? 10 : 12,
                ),
                child: compact
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                            child: Focus(
                              onKeyEvent: (node, event) =>
                                  _handleComposerKeyEvent(event),
                              child: GestureDetector(
                                onLongPress: () {
                                  final box = context.findRenderObject();
                                  if (box is RenderBox && box.hasSize) {
                                    final center = box.localToGlobal(
                                      Offset(
                                        box.size.width / 2,
                                        box.size.height / 2,
                                      ),
                                    );
                                    _openComposerCtxMenu(center);
                                  }
                                },
                                child: _wrapComposerPointerLayer(
                                  child: TextField(
                                    key: _composerFieldKey,
                                    controller: _controller,
                                    focusNode: _composerFocus,
                                    minLines: 1,
                                    maxLines: 5,
                                    keyboardType: TextInputType.multiline,
                                    textInputAction: TextInputAction.newline,
                                    autocorrect: false,
                                    enableSuggestions: false,
                                    contextMenuBuilder:
                                        (context, editableTextState) =>
                                            const SizedBox.shrink(),
                                    onTapOutside: _onComposerTapOutside,
                                    onChanged: (value) {
                                      state.notifyTypingIfComposing(value);
                                    },
                                    onTap: _onComposerTap,
                                    decoration: InputDecoration(
                                      isDense: true,
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 12,
                                          ),
                                      hintText: _draftMedia.isEmpty
                                          ? state.composerPlaceholder
                                          : 'Add a caption…',
                                      prefixIcon: IconButton(
                                        tooltip: 'Emoji',
                                        onPressed: _toggleEmoji,

                                        icon: Icon(
                                          _showEmoji
                                              ? Icons.keyboard_rounded
                                              : Icons.emoji_emotions_outlined,
                                          color: PrivetTheme.mist,
                                        ),
                                      ),
                                      suffixIcon: WebAttachButton(
                                        tooltip: 'Attach files',
                                        onPicked: _applyPickedFile,
                                        onPressedFallback: _pickFile,
                                        onError: (e) => widget.state.setError(
                                          'Could not attach file: $e',
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ValueListenableBuilder<bool>(
                            valueListenable: _composerHasContent,
                            builder: (context, hasContent, _) {
                              if (hasContent) {
                                return Material(
                                  color: PrivetTheme.signal,
                                  borderRadius: BorderRadius.circular(14),
                                  child: InkWell(
                                    onTap: _recording ? _toggleVoice : _send,
                                    mouseCursor: SystemMouseCursors.click,
                                    borderRadius: BorderRadius.circular(14),
                                    child: SizedBox(
                                      width: 48,
                                      height: 48,
                                      child: Icon(
                                        _recording
                                            ? Icons.stop_circle_rounded
                                            : Icons.arrow_upward_rounded,
                                        color: _recording
                                            ? PrivetTheme.danger
                                            : PrivetTheme.onAccent,
                                      ),
                                    ),
                                  ),
                                );
                              }
                              return IconButton(
                                tooltip: 'Voice message',
                                onPressed: _toggleVoice,
                                icon: const Icon(Icons.mic_rounded),
                              );
                            },
                          ),
                        ],
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          IconButton(
                            tooltip: 'Emoji',
                            onPressed: _toggleEmoji,
                            icon: Icon(
                              _showEmoji
                                  ? Icons.keyboard_rounded
                                  : Icons.emoji_emotions_outlined,
                            ),
                          ),
                          WebAttachButton(
                            tooltip: 'Attach files',
                            onPicked: _applyPickedFile,
                            onPressedFallback: _pickFile,
                            onError: (e) => widget.state.setError(
                              'Could not attach file: $e',
                            ),
                          ),
                          Expanded(
                            child: Focus(
                              onKeyEvent: (node, event) =>
                                  _handleComposerKeyEvent(event),
                              child: GestureDetector(
                                onLongPress: () {
                                  final box = context.findRenderObject();
                                  if (box is RenderBox && box.hasSize) {
                                    final center = box.localToGlobal(
                                      Offset(
                                        box.size.width / 2,
                                        box.size.height / 2,
                                      ),
                                    );
                                    _openComposerCtxMenu(center);
                                  }
                                },
                                child: _wrapComposerPointerLayer(
                                  child: TextField(
                                    key: _composerFieldKey,
                                    controller: _controller,
                                    focusNode: _composerFocus,
                                    minLines: 1,
                                    maxLines: 6,
                                    keyboardType: TextInputType.multiline,
                                    textInputAction: TextInputAction.newline,
                                    autocorrect: false,
                                    enableSuggestions: false,
                                    contextMenuBuilder:
                                        (context, editableTextState) =>
                                            const SizedBox.shrink(),
                                    onTapOutside: _onComposerTapOutside,
                                    onChanged: (value) =>
                                        state.notifyTypingIfComposing(value),
                                    onTap: _onComposerTap,
                                    decoration: InputDecoration(
                                      hintText: _draftMedia.isEmpty
                                          ? state.composerPlaceholder
                                          : 'Add a caption…',
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: _recording
                                ? 'Stop & send'
                                : 'Voice message',
                            onPressed: _toggleVoice,
                            icon: Icon(
                              _recording
                                  ? Icons.stop_circle_rounded
                                  : Icons.mic_rounded,
                              color: _recording ? PrivetTheme.danger : null,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Material(
                            color: PrivetTheme.signal,
                            borderRadius: BorderRadius.circular(14),
                            child: InkWell(
                              onTap: _send,
                              mouseCursor: SystemMouseCursors.click,
                              borderRadius: BorderRadius.circular(14),
                              child: SizedBox(
                                width: 48,
                                height: 48,
                                child: Icon(
                                  Icons.arrow_upward_rounded,
                                  color: PrivetTheme.onAccent,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
            ),
            if (_showEmoji && !compact)
              TextFieldTapRegion(
                child: CompactEmojiPicker(
                  height: 192,
                  textEditingController: _controller,
                  onSelected: (_) => state.notifyTyping(),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildReplyBar() {
    final reply = _replyingTo!;
    final name = reply.sender.handle.isNotEmpty
        ? '@${reply.sender.handle}'
        : reply.sender.displayName;
    final snippet = _replySnippet?.trim();
    final preview = (snippet != null && snippet.isNotEmpty)
        ? snippet
        : reply.body.isNotEmpty
        ? reply.body
        : switch (reply.kind) {
            'image' => '📷 Photo',
            'video' => '🎬 Video',
            'audio' => '🎵 Audio',
            'voice' => '🎤 Voice message',
            'file' => reply.fileName ?? '📎 File',
            'album' => '📎 ${reply.mediaItems.length} attachments',
            _ => reply.body,
          };
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
      decoration: BoxDecoration(
        color: PrivetTheme.panelElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: PrivetTheme.line),
      ),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 36,
            decoration: BoxDecoration(
              color: PrivetTheme.signal,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Replying to $name',
                  style: GoogleFonts.syne(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: PrivetTheme.signal,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: PrivetTheme.mist, fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Cancel reply',
            onPressed: () => setState(() {
              _replyingTo = null;
              _replySnippet = null;
            }),
            icon: const Icon(Icons.close_rounded, size: 18),
          ),
        ],
      ),
    );
  }

  Widget _buildDraftPreview() {
    final drafts = _draftMedia;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 0),
      padding: const EdgeInsets.fromLTRB(10, 10, 4, 10),
      decoration: BoxDecoration(
        color: PrivetTheme.panelElevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PrivetTheme.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 2, right: 8, bottom: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    drafts.length == 1
                        ? '1 attachment ready'
                        : '${drafts.length} attachments ready',
                    style: GoogleFonts.syne(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    setState(() => _draftMedia.clear());
                    _syncComposerHasContent();
                  },
                  child: const Text('Clear all'),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 72,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: drafts.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final draft = drafts[index];
                final isImage = draft.mimeType.startsWith('image/');
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: PrivetTheme.ink,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: PrivetTheme.line),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: isImage
                          ? Image.memory(
                              draft.bytes,
                              width: 72,
                              height: 72,
                              fit: BoxFit.cover,
                            )
                          : Center(
                              child: Icon(
                                draft.mimeType.startsWith('video/')
                                    ? Icons.videocam_rounded
                                    : draft.mimeType.startsWith('audio/')
                                    ? Icons.audiotrack_rounded
                                    : Icons.insert_drive_file_rounded,
                                color: PrivetTheme.signal,
                              ),
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
                          onTap: () {
                            setState(() => _draftMedia.removeAt(index));
                            _syncComposerHasContent();
                          },
                          child: const Padding(
                            padding: EdgeInsets.all(2),
                            child: Icon(Icons.close_rounded, size: 16),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _startCall(String mode) async {
    // #region agent log
    agentDebugLog(
      hypothesisId: 'H8',
      location: 'messenger_shell.dart:_startCall',
      message: 'startCall begin',
      data: {'mode': mode},
    );
    // #endregion
    final needsCamera = mode == 'video';
    final isScreen = mode == 'screen';
    final isControl = mode == 'control';

    // Chrome drops user-activation across getUserMedia awaits — unlock call
    // AudioElements here, while the click gesture is still live.
    unlockNotificationAudio();

    // Firefox (and Chrome): getDisplayMedia requires transient user activation.
    // Show Privet chooser first; capture runs inside that option's click.
    MediaStream? screenStream;
    MediaStream? localStream;
    if (isControl) {
      // Controller starts with no media — host shares on Allow.
    } else if (isScreen) {
      try {
        screenStream = await showScreenSharePicker(context);
        if (screenStream == null) return; // cancelled
      } catch (e) {
        widget.state.setError('$e');
        return;
      }
    } else {
      // Always open mic (+ camera for video) on this click — browser permission
      // must appear HERE, before invite/ring. Keep the stream for the call so
      // we never re-prompt (and hang up) after the peer answers.
      var cameraFailed = false;
      try {
        localStream = await navigator.mediaDevices.getUserMedia({
          'audio': true,
          'video': needsCamera,
        });
      } catch (e) {
        if (needsCamera) {
          // Camera may be exclusively held by another app or browser tab
          // (a single physical webcam can't be opened twice on Linux/V4L2).
          // Join with audio only rather than blocking the call entirely —
          // the camera can be retried from the call screen once it's free.
          try {
            localStream = await navigator.mediaDevices.getUserMedia({
              'audio': true,
              'video': false,
            });
            cameraFailed = true;
          } catch (e2) {
            wakeUiAfterMediaDialog();
            widget.state.setError(
              'Camera and microphone permission required for video calls',
            );
            return;
          }
        } else {
          wakeUiAfterMediaDialog();
          widget.state.setError('Microphone permission required for calls');
          return;
        }
      }
      wakeUiAfterMediaDialog();
      markMediaGranted(mic: true, camera: needsCamera && !cameraFailed);
      final status = await queryMediaPermissions();
      if (!mounted) {
        await _stopStream(localStream);
        return;
      }
      setState(() => _mediaPerms = status);
      wakeUiAfterMediaDialog();
      if (cameraFailed && mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                'Camera is busy (maybe open in another app or browser tab) — starting with audio. Tap the camera button in the call to retry.',
              ),
              backgroundColor: PrivetTheme.panelElevated,
              behavior: SnackBarBehavior.floating,
            ),
          );
      }
    }

    final chat = _chat;
    final state = widget.state;
    if (chat == null) {
      await _stopStream(screenStream);
      await _stopStream(localStream);
      return;
    }

    if (chat.isGroup) {
      final members = await state.api.members(chat.id);
      final others = members.where((m) => m.id != state.user?.id).toList();
      if (!mounted) {
        await _stopStream(screenStream);
        await _stopStream(localStream);
        return;
      }
      final picked = await showPrivetSheet<PrivetUser>(
        context: context,
        backgroundColor: PrivetTheme.panel,
        showDragHandle: true,
        builder: (context) {
          return ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: Text(
                  mode == 'audio'
                      ? 'Audio call'
                      : mode == 'screen'
                      ? 'Screen share'
                      : mode == 'control'
                      ? 'Remote control'
                      : 'Video call',
                  style: GoogleFonts.syne(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              ...others.map(
                (u) => ListTile(
                  leading: PrivetAvatar(
                    name: u.displayName,
                    hue: u.avatarHue,
                    online: state.online.contains(u.id),
                  ),
                  title: UserNameBlock.fromUser(u, titleSize: 15),
                  subtitle: Text(
                    state.online.contains(u.id) ? 'online' : 'offline',
                  ),
                  onTap: () => Navigator.pop(context, u),
                ),
              ),
            ],
          );
        },
      );
      if (picked != null) {
        await state.startCall(
          mode: mode,
          peer: picked,
          displayStream: screenStream,
          localStream: localStream,
        );
      } else {
        await _stopStream(screenStream);
        await _stopStream(localStream);
      }
      return;
    }

    await state.startCall(
      mode: mode,
      peer: chat.peer,
      displayStream: screenStream,
      localStream: localStream,
    );
  }

  Future<void> _stopStream(MediaStream? stream) async {
    if (stream == null) return;
    for (final t in stream.getTracks()) {
      await t.stop();
    }
    await stream.dispose();
  }

  Future<void> _deleteGroup() async {
    final chat = _chat;
    final state = widget.state;
    if (chat == null || !chat.isOwnedBy(state.user?.id)) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: PrivetTheme.panel,
        title: Text(
          'Delete group?',
          style: GoogleFonts.syne(fontWeight: FontWeight.w700),
        ),
        content: Text(
          '“${chat.title}” will be deleted for everyone. This cannot be undone.',
          style: TextStyle(color: PrivetTheme.mist),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: PrivetTheme.danger,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete group'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await state.deleteGroup(chat.id);
    } catch (e) {
      state.setError(e is ApiException ? e.message : e.toString());
    }
  }

  Future<void> _manageMembers() async {
    final chat = _chat;
    final state = widget.state;
    if (chat == null || !chat.isGroup) return;

    var members = await state.api.members(chat.id);
    if (!mounted) return;

    await showPrivetSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: PrivetTheme.panel,
      showDragHandle: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setModal) {
            final memberIds = members.map((m) => m.id).toSet();
            final candidates = state.directory
                .where((u) => !memberIds.contains(u.id))
                .toList();
            final me = state.user?.id;
            final isOwner = chat.isOwnedBy(me);

            return SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.72,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Members · ${members.length}',
                            style: GoogleFonts.syne(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: candidates.isEmpty
                              ? null
                              : () async {
                                  final searchCtrl = TextEditingController();
                                  var peopleQuery = '';
                                  final picked =
                                      await showPrivetSheet<PrivetUser>(
                                        context: context,
                                        backgroundColor:
                                            PrivetTheme.panelElevated,
                                        showDragHandle: true,
                                        isScrollControlled: true,
                                        builder: (ctx) => StatefulBuilder(
                                          builder: (ctx, setPick) {
                                            final filtered = filterPeople(
                                              candidates,
                                              peopleQuery,
                                            );
                                            return SizedBox(
                                              height:
                                                  MediaQuery.sizeOf(ctx)
                                                      .height *
                                                  0.6,
                                              child: Column(
                                                children: [
                                                  Padding(
                                                    padding:
                                                        const EdgeInsets.fromLTRB(
                                                          20,
                                                          8,
                                                          20,
                                                          8,
                                                        ),
                                                    child: Text(
                                                      'Add to group',
                                                      style: GoogleFonts.syne(
                                                        fontSize: 18,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                      ),
                                                    ),
                                                  ),
                                                  Padding(
                                                    padding:
                                                        const EdgeInsets.fromLTRB(
                                                          20,
                                                          0,
                                                          20,
                                                          8,
                                                        ),
                                                    child: TextField(
                                                      controller: searchCtrl,
                                                      autofocus: true,
                                                      decoration:
                                                          InputDecoration(
                                                        hintText:
                                                            'Search people',
                                                        prefixIcon: const Icon(
                                                          Icons.search_rounded,
                                                        ),
                                                        suffixIcon:
                                                            peopleQuery.isEmpty
                                                                ? null
                                                                : IconButton(
                                                                    tooltip:
                                                                        'Clear',
                                                                    onPressed:
                                                                        () {
                                                                      searchCtrl
                                                                          .clear();
                                                                      setPick(
                                                                        () =>
                                                                            peopleQuery =
                                                                                '',
                                                                      );
                                                                    },
                                                                    icon:
                                                                        const Icon(
                                                                      Icons
                                                                          .close_rounded,
                                                                    ),
                                                                  ),
                                                      ),
                                                      onChanged: (v) => setPick(
                                                        () => peopleQuery = v,
                                                      ),
                                                    ),
                                                  ),
                                                  Expanded(
                                                    child: filtered.isEmpty
                                                        ? Center(
                                                            child: Text(
                                                              'No people match “${normalizePeopleQuery(peopleQuery)}”',
                                                              style: GoogleFonts
                                                                  .ibmPlexSans(
                                                                color:
                                                                    PrivetTheme
                                                                        .mist,
                                                              ),
                                                            ),
                                                          )
                                                        : ListView.builder(
                                                            itemCount:
                                                                filtered.length,
                                                            itemBuilder:
                                                                (ctx, i) {
                                                              final u =
                                                                  filtered[i];
                                                              return ListTile(
                                                                leading:
                                                                    PrivetAvatar(
                                                                  name: u
                                                                      .displayName,
                                                                  hue: u
                                                                      .avatarHue,
                                                                  online: state
                                                                      .online
                                                                      .contains(
                                                                    u.id,
                                                                  ),
                                                                ),
                                                                title:
                                                                    UserNameBlock
                                                                        .fromUser(
                                                                  u,
                                                                  titleSize: 15,
                                                                ),
                                                                subtitle: Text(
                                                                  '@${u.handle}',
                                                                ),
                                                                onTap: () =>
                                                                    Navigator.pop(
                                                                  ctx,
                                                                  u,
                                                                ),
                                                              );
                                                            },
                                                          ),
                                                  ),
                                                ],
                                              ),
                                            );
                                          },
                                        ),
                                      );
                                  searchCtrl.dispose();
                                  if (picked == null) return;
                                  try {
                                    members = await state.addGroupMember(
                                      conversationId: chat.id,
                                      userId: picked.id,
                                    );
                                    setModal(() {});
                                  } catch (e) {
                                    state.setError(
                                      e is ApiException
                                          ? e.message
                                          : e.toString(),
                                    );
                                  }
                                },
                          icon: const Icon(Icons.person_add_alt_1_rounded),
                          label: const Text('Add'),
                        ),
                      ],
                    ),
                  ),
                  Divider(height: 1, color: PrivetTheme.line),
                  Expanded(
                    child: ListView.builder(
                      itemCount: members.length,
                      itemBuilder: (context, i) {
                        final u = members[i];
                        final isMe = u.id == me;
                        final memberIsOwner = u.id == chat.ownerId;
                        final canRemove = members.length > 2;
                        return ListTile(
                          leading: PrivetAvatar(
                            name: u.displayName,
                            hue: u.avatarHue,
                            online: state.online.contains(u.id),
                          ),
                          title: UserNameBlock.fromUser(
                            u,
                            isYou: isMe,
                            titleSize: 15,
                          ),
                          subtitle: memberIsOwner
                              ? Text(
                                  'Owner',
                                  style: TextStyle(
                                    color: PrivetTheme.mist,
                                    fontSize: 12,
                                  ),
                                )
                              : null,
                          trailing: IconButton(
                            tooltip: isMe ? 'Leave group' : 'Remove',
                            onPressed: !canRemove
                                ? null
                                : () async {
                                    final ok = await showDialog<bool>(
                                      context: context,
                                      builder: (ctx) => AlertDialog(
                                        backgroundColor: PrivetTheme.panel,
                                        title: Text(
                                          isMe
                                              ? 'Leave group?'
                                              : 'Remove @${u.handle}?',
                                          style: GoogleFonts.syne(
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(ctx, false),
                                            child: const Text('Cancel'),
                                          ),
                                          ElevatedButton(
                                            onPressed: () =>
                                                Navigator.pop(ctx, true),
                                            child: Text(
                                              isMe ? 'Leave' : 'Remove',
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (ok != true) return;
                                    try {
                                      members = await state.removeGroupMember(
                                        conversationId: chat.id,
                                        userId: u.id,
                                      );
                                      if (isMe && context.mounted) {
                                        Navigator.pop(sheetContext);
                                        return;
                                      }
                                      setModal(() {});
                                    } catch (e) {
                                      state.setError(
                                        e is ApiException
                                            ? e.message
                                            : e.toString(),
                                      );
                                    }
                                  },
                            icon: Icon(
                              isMe
                                  ? Icons.logout_rounded
                                  : Icons.person_remove_rounded,
                              color: canRemove ? PrivetTheme.danger : null,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  if (isOwner) ...[
                    Divider(height: 1, color: PrivetTheme.line),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: PrivetTheme.danger,
                            side: BorderSide(color: PrivetTheme.danger),
                          ),
                          onPressed: () async {
                            final ok = await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                backgroundColor: PrivetTheme.panel,
                                title: Text(
                                  'Remove group?',
                                  style: GoogleFonts.syne(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                content: Text(
                                  '“${chat.title}” will be deleted for everyone. This cannot be undone.',
                                  style: TextStyle(color: PrivetTheme.mist),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx, false),
                                    child: const Text('Cancel'),
                                  ),
                                  ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: PrivetTheme.danger,
                                    ),
                                    onPressed: () => Navigator.pop(ctx, true),
                                    child: const Text('Remove group'),
                                  ),
                                ],
                              ),
                            );
                            if (ok != true) return;
                            try {
                              await state.deleteGroup(chat.id);
                              if (sheetContext.mounted) {
                                Navigator.pop(sheetContext);
                              }
                            } catch (e) {
                              state.setError(
                                e is ApiException ? e.message : e.toString(),
                              );
                            }
                          },
                          icon: const Icon(Icons.delete_forever_rounded),
                          label: const Text('Remove group'),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }

  String? _seenByShort(Conversation chat, ChatMessage m, PrivetState state) {
    final ids = chat.seenByUserIds(m, selfId: state.user?.id);
    if (ids.isEmpty) return null;
    if (ids.length == 1) {
      final id = ids.first;
      for (final u in state.directory) {
        if (u.id == id) return 'Seen by ${u.displayName}';
      }
      return 'Seen by 1';
    }
    return 'Seen by ${ids.length}';
  }

  Future<void> _showSeenBy(
    BuildContext context,
    Conversation chat,
    ChatMessage message,
  ) async {
    final state = widget.state;
    final ids = chat.seenByUserIds(message, selfId: state.user?.id);
    final names = <String>[];
    for (final id in ids) {
      PrivetUser? found;
      for (final u in state.directory) {
        if (u.id == id) found = u;
      }
      for (final r in chat.memberReads) {
        if (r.userId == id && found == null) {
          found = PrivetUser(
            id: id,
            handle: '',
            displayName: 'Member',
            avatarHue: 160,
          );
        }
      }
      names.add(found?.displayName ?? id);
    }
    if (!context.mounted) return;
    await showPrivetSheet<void>(
      context: context,
      backgroundColor: PrivetTheme.panel,
      showDragHandle: true,
      builder: (ctx) => ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Text(
              'Seen by',
              style: GoogleFonts.syne(
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (names.isEmpty)
            const ListTile(title: Text('No one yet'))
          else
            ...names.map((n) => ListTile(title: Text(n))),
        ],
      ),
    );
  }

  Future<void> _askAiAboutMessage(
    BuildContext context,
    ChatMessage message,
  ) async {
    final state = widget.state;
    if (!state.aiActive) return;

    final who = message.sender.displayName.trim().isNotEmpty
        ? message.sender.displayName.trim()
        : (message.sender.handle.isNotEmpty
              ? '@${message.sender.handle}'
              : 'someone');
    final snippet = _messageAiSnippet(message);
    final ctrl = TextEditingController();
    final question = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: PrivetTheme.panelElevated,
          title: Text(
            'Ask AI',
            style: GoogleFonts.syne(fontWeight: FontWeight.w700),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'About message from $who',
                style: TextStyle(color: PrivetTheme.mist, fontSize: 13),
              ),
              if (snippet.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: PrivetTheme.panel,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: PrivetTheme.line),
                  ),
                  child: Text(
                    snippet.length > 160
                        ? '${snippet.substring(0, 160)}…'
                        : snippet,
                    style: GoogleFonts.ibmPlexSans(
                      fontSize: 13,
                      height: 1.35,
                      color: PrivetTheme.paper.withValues(alpha: 0.9),
                    ),
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                autofocus: true,
                maxLines: 3,
                minLines: 1,
                textInputAction: TextInputAction.send,
                onSubmitted: (v) {
                  final t = v.trim();
                  if (t.isNotEmpty) Navigator.pop(ctx, t);
                },
                decoration: const InputDecoration(
                  labelText: 'Your question',
                  hintText: 'What should I know about this?',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final t = ctrl.text.trim();
                if (t.isEmpty) return;
                Navigator.pop(ctx, t);
              },
              child: const Text('Ask'),
            ),
          ],
        );
      },
    );
    ctrl.dispose();
    if (question == null || question.trim().isEmpty) return;

    final cmd = StringBuffer('# ${question.trim()}');
    cmd.writeln();
    cmd.writeln();
    cmd.write('About this message from $who:\n$snippet');
    await state.sendAiCommand(cmd.toString());
  }

  static String _messageAiSnippet(ChatMessage message) {
    if (message.isDeleted) return '(deleted message)';
    if (message.kind == 'ai' || message.aiLocal) {
      final payload = AiTurnPayload.tryParse(message.body);
      if (payload != null) {
        final parts = <String>[];
        final q = payload.question.trim();
        final a = payload.answer.trim();
        if (q.isNotEmpty) parts.add('Q: $q');
        if (a.isNotEmpty) parts.add('A: $a');
        if (parts.isNotEmpty) return parts.join('\n');
      }
    }
    final body = message.body.trim();
    if (body.isNotEmpty) {
      return body.length > 800 ? '${body.substring(0, 800)}…' : body;
    }
    switch (message.kind) {
      case 'image':
        return '(image${message.fileName != null ? ': ${message.fileName}' : ''})';
      case 'video':
        return '(video)';
      case 'voice':
        return '(voice message)';
      case 'audio':
        return '(audio)';
      case 'file':
        return message.fileName != null
            ? '(file: ${message.fileName})'
            : '(file)';
      case 'album':
        return '(album)';
      default:
        return '(message)';
    }
  }

  Future<void> _forwardMessage(
    BuildContext context,
    ChatMessage message,
  ) async {
    final state = widget.state;
    final target = await showPrivetSheet<Conversation>(
      context: context,
      backgroundColor: PrivetTheme.panel,
      showDragHandle: true,
      builder: (ctx) => ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Text(
              'Forward to…',
              style: GoogleFonts.syne(
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          ...state.conversations.map(
            (c) => ListTile(
              leading: PrivetAvatar(
                name: c.title,
                hue: c.peer?.avatarHue ?? (c.isGroup ? 90 : 160),
                avatarUrl: c.peer?.avatarUrl == null
                    ? null
                    : state.api.absoluteMediaUrl(c.peer!.avatarUrl),
              ),
              title: Text(c.title),
              onTap: () => Navigator.pop(ctx, c),
            ),
          ),
        ],
      ),
    );
    if (target == null || !mounted) return;
    try {
      await state.forwardMessage(
        messageId: message.id,
        toConversationId: target.id,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Forwarded to ${target.title}'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e is ApiException ? e.message : e.toString()),
            backgroundColor: PrivetTheme.danger,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  void _applyPickedFile(PickedBytes picked) {
    final mime = picked.mimeType.isEmpty
        ? _mimeFor(picked.filename)
        : picked.mimeType;
    setState(() {
      _draftMedia.add(
        PickedBytes(
          bytes: picked.bytes,
          filename: picked.filename,
          mimeType: mime,
        ),
      );
      _showEmoji = false;
    });
    _syncComposerHasContent();
  }

  Future<void> _pickFile() async {
    // Non-web only — web uses HtmlElementView overlay (WebAttachButton).
    try {
      final result = await FilePicker.platform.pickFiles(
        withData: true,
        type: FileType.any,
        allowMultiple: true,
      );
      if (result == null || result.files.isEmpty) return;
      for (final file in result.files) {
        final bytes = file.bytes;
        if (bytes == null || bytes.isEmpty) continue;
        _applyPickedFile(
          PickedBytes(
            bytes: bytes,
            filename: file.name,
            mimeType: _mimeFor(file.name),
          ),
        );
      }
    } catch (e) {
      widget.state.setError('Could not attach file: $e');
    }
  }

  String _mimeFor(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.mp4')) return 'video/mp4';
    if (lower.endsWith('.webm')) return 'video/webm';
    if (lower.endsWith('.mov')) return 'video/quicktime';
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.wav')) return 'audio/wav';
    if (lower.endsWith('.m4a')) return 'audio/mp4';
    if (lower.endsWith('.ogg')) return 'audio/ogg';
    if (lower.endsWith('.pdf')) return 'application/pdf';
    return 'application/octet-stream';
  }

  void _voiceToast(String message) {
    widget.state.setError(message);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: PrivetTheme.danger,
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Future<void> _toggleVoice() async {
    if (_recording) {
      final path = await _recorder.stop();
      setState(() => _recording = false);
      _syncComposerHasContent();
      if (path == null || path.isEmpty) {
        _voiceToast('Recording produced no file');
        return;
      }

      try {
        final bytes = await readRecordingBytes(path);
        await deleteRecordingFile(path);
        if (bytes.isEmpty) {
          _voiceToast('Empty recording — try again');
          return;
        }
        final stamp = DateTime.now().millisecondsSinceEpoch;
        // Web MediaRecorder → webm/opus; native (Linux) → wav (opus-in-.m4a fails).
        final filename = kIsWeb ? 'voice-$stamp.webm' : 'voice-$stamp.wav';
        final mimeType = kIsWeb ? 'audio/webm' : 'audio/wav';
        await widget.state.sendMediaBytes(
          bytes: bytes,
          filename: filename,
          mimeType: mimeType,
          asVoice: true,
        );
        final err = widget.state.error;
        if (err != null && err.isNotEmpty) {
          _voiceToast(err);
          return;
        }
        _scrollToEnd();
      } catch (e) {
        _voiceToast('Voice send failed: $e');
      }
      return;
    }

    if (!await _recorder.hasPermission()) {
      _voiceToast('Microphone permission required');
      return;
    }
    try {
      if (kIsWeb) {
        await _recorder.start(
          const RecordConfig(
            encoder: AudioEncoder.opus,
            numChannels: 1,
            bitRate: 64000,
          ),
          path: 'privet-voice.webm',
        );
      } else {
        // Linux ffmpeg cannot mux Opus into .m4a — that left a 0-byte file.
        final dir = await getTemporaryDirectory();
        final out = p.join(
          dir.path,
          'privet-voice-${DateTime.now().millisecondsSinceEpoch}.wav',
        );
        await _recorder.start(
          const RecordConfig(encoder: AudioEncoder.wav, numChannels: 1),
          path: out,
        );
      }
      setState(() => _recording = true);
      _syncComposerHasContent();
    } catch (e) {
      _voiceToast('Could not start recording: $e');
    }
  }

  void _dismissComposerKeyboard() {
    _composerFocus.unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
    SystemChannels.textInput.invokeMethod('TextInput.hide');
    dismissSoftKeyboard();
  }

  Future<void> _send() async {
    final drafts = List<PickedBytes>.from(_draftMedia);
    final text = _controller.text;
    final reply = _replyingTo;
    final replyToId = reply?.id;
    final snippet = _replySnippet?.trim();
    final replyQuote = (snippet != null && snippet.isNotEmpty) ? snippet : null;
    final replyPreview = reply == null
        ? null
        : ReplyPreview.fromMessage(reply, bodyOverride: replyQuote);
    // Stop typing first — clear() would otherwise re-emit via onChanged, and a
    // trailing throttle pulse must not outrun the message on the wire.
    widget.state.stopOutgoingTyping();
    // PWA / compact: always dismiss IME after send so the OS keyboard does
    // not stick open or leave a white viewport gap.
    final dismissKeyboard = mounted && PrivetTheme.isCompact(context);
    _clearComposerAutocomplete();
    _controller.clearMarks();
    if (drafts.isNotEmpty) {
      final caption = text.trim();
      _controller.clear();
      setState(() {
        _draftMedia.clear();
        _replyingTo = null;
        _replySnippet = null;
      });
      _syncComposerHasContent();
      final chatId = widget.state.activeConversationId;
      if (chatId != null) await widget.state.clearDraft(chatId);
      await widget.state.sendMediaAlbum(
        files: drafts
            .map(
              (d) =>
                  (bytes: d.bytes, filename: d.filename, mimeType: d.mimeType),
            )
            .toList(),
        caption: caption,
        replyToId: replyToId,
        replyTo: replyPreview,
        replyQuote: replyQuote,
      );
      if (dismissKeyboard) _dismissComposerKeyboard();
      _scrollToEnd();
      return;
    }
    if (text.trim().isEmpty) return;
    widget.state.sendText(
      text,
      replyToId: replyToId,
      replyTo: replyPreview,
      replyQuote: replyQuote,
    );
    _controller.clear();
    setState(() {
      _replyingTo = null;
      _replySnippet = null;
    });
    if (dismissKeyboard) _dismissComposerKeyboard();
    _scrollToEnd();
  }

  Future<void> _editMessage(ChatMessage message) async {
    final ctrl = TextEditingController(text: message.body);
    final next = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: PrivetTheme.panel,
        title: Text(
          'Edit message',
          style: GoogleFonts.syne(fontWeight: FontWeight.w700),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 5,
          minLines: 2,
          decoration: const InputDecoration(hintText: 'Message'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (next == null || next.isEmpty || !mounted) return;
    await widget.state.editMessage(message.id, next);
  }

  Future<void> _deleteMessage(ChatMessage message) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: PrivetTheme.panel,
        title: Text(
          'Delete message?',
          style: GoogleFonts.syne(fontWeight: FontWeight.w700),
        ),
        content: Text(
          'This removes the message for everyone in the chat.',
          style: TextStyle(color: PrivetTheme.mist),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: PrivetTheme.danger,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await widget.state.deleteMessage(message.id);
  }

  bool _sameDay(DateTime a, DateTime b) {
    final la = a.toLocal();
    final lb = b.toLocal();
    return la.year == lb.year && la.month == lb.month && la.day == lb.day;
  }

  String _dayLabel(DateTime dt) {
    final local = dt.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(local.year, local.month, local.day);
    final diff = today.difference(that).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    if (diff < 7) return DateFormat('EEEE').format(local); // weekday
    if (local.year == now.year) return DateFormat('MMMM d').format(local);
    return DateFormat('MMMM d, yyyy').format(local);
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        // reverse: true ListView — offset 0 is the newest message
        _scroll.animateTo(
          0,
          duration: privetAnim(const Duration(milliseconds: 220)),
          curve: Curves.easeOut,
        );
      }
    });
  }
}

class _DaySeparator extends StatelessWidget {
  const _DaySeparator({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: PrivetTheme.panelElevated,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: PrivetTheme.line),
          ),
          child: Text(
            label,
            style: GoogleFonts.ibmPlexSans(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: PrivetTheme.mist,
              letterSpacing: 0.3,
            ),
          ),
        ),
      ),
    );
  }
}

class _CallActionButton extends StatelessWidget {
  const _CallActionButton({
    required this.tooltip,
    required this.icon,
    required this.active,
    required this.enabled,
    required this.onPressed,
    this.caution = false,
  });

  final String tooltip;
  final IconData icon;
  final bool active;
  final bool enabled;
  final VoidCallback onPressed;

  /// Missing-device / blocked state — tooltip in caution red.
  final bool caution;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 280),
      textStyle: caution
          ? TextStyle(
              color: PrivetTheme.danger,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            )
          : null,
      decoration: caution
          ? BoxDecoration(
              color: const Color(0xFF2A1816),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: PrivetTheme.danger.withValues(alpha: 0.55),
              ),
            )
          : null,
      child: IconButton(
        onPressed: enabled ? onPressed : null,
        style: ButtonStyle(
          mouseCursor: WidgetStatePropertyAll(
            enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          ),
        ),
        icon: Icon(
          icon,
          color: !enabled
              ? PrivetTheme.mist.withValues(alpha: 0.28)
              : active
              ? PrivetTheme.signal
              : PrivetTheme.mist.withValues(alpha: 0.55),
        ),
      ),
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: PrivetTheme.panel,
      child: Center(
        child: Text(
          'Pick a conversation',
          style: GoogleFonts.syne(
            color: PrivetTheme.mist,
            fontSize: 22,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// Menu row that fires on pointer-down so overlay teardown can't cancel it.
class _ComposerMenuItem extends StatefulWidget {
  const _ComposerMenuItem({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  State<_ComposerMenuItem> createState() => _ComposerMenuItemState();
}

class _ComposerMenuItemState extends State<_ComposerMenuItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Listener(
        onPointerDown: (_) => widget.onPressed(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 80),
          curve: Curves.easeOut,
          width: double.infinity,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          color: _hovered
              ? const Color(0xFF3F3F46)
              : Colors.transparent,
          child: Text(
            widget.label,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: Color(0xFFF2F2F2),
            ),
          ),
        ),
      ),
    );
  }
}

/// Segmented System / Light / Dark selector for the Appearance settings.
class _ThemeModeSelector extends StatelessWidget {
  const _ThemeModeSelector({required this.mode, required this.onChanged});

  final ThemeMode mode;
  final ValueChanged<ThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    const items = <(ThemeMode, IconData, String)>[
      (ThemeMode.system, Icons.brightness_auto_rounded, 'System'),
      (ThemeMode.light, Icons.light_mode_rounded, 'Light'),
      (ThemeMode.dark, Icons.dark_mode_rounded, 'Dark'),
    ];
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: PrivetTheme.panelElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: PrivetTheme.line),
      ),
      child: Row(
        children: [
          for (final item in items)
            Expanded(
              child: _segment(
                selected: mode == item.$1,
                icon: item.$2,
                label: item.$3,
                onTap: () => onChanged(item.$1),
              ),
            ),
        ],
      ),
    );
  }

  Widget _segment({
    required bool selected,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: privetAnim(const Duration(milliseconds: 160)),
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: selected ? PrivetTheme.signal : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 16,
                color: selected ? PrivetTheme.onAccent : PrivetTheme.mist,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: selected ? PrivetTheme.onAccent : PrivetTheme.mist,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Row of accent swatches acting as a color picker for the app accent.
class _AccentPicker extends StatelessWidget {
  const _AccentPicker({required this.selected, required this.onPick});

  final Color selected;
  final ValueChanged<Color> onPick;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final option in PrivetTheme.accentOptions)
          _swatch(option.seed, option.label),
      ],
    );
  }

  Widget _swatch(Color seed, String label) {
    final isSelected = seed.toARGB32() == selected.toARGB32();
    return Tooltip(
      message: label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => onPick(seed),
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: seed,
              shape: BoxShape.circle,
              border: Border.all(
                color: isSelected ? PrivetTheme.paper : PrivetTheme.line,
                width: isSelected ? 2.5 : 1,
              ),
            ),
            child: isSelected
                ? Icon(
                    Icons.check_rounded,
                    size: 18,
                    color: PrivetTheme.onAccent,
                  )
                : null,
          ),
        ),
      ),
    );
  }
}
