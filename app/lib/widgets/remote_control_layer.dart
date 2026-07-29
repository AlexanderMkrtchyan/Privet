import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../remote_control/protocol.dart';
import '../state.dart';
import '../theme.dart';
import '../util/app_clipboard.dart';
import '../util/fullscreen.dart';

/// Host consent dialog + banner; controller input capture over the stage.
class RemoteControlLayer extends StatefulWidget {
  const RemoteControlLayer({
    super.key,
    required this.session,
    required this.child,
    this.state,
    this.immersive = false,
  });

  final CallSession session;
  final Widget child;

  /// Needed for auto-allow preference storage.
  final PrivetState? state;

  /// When true, hide the floating banner (immersive chrome owns status).
  final bool immersive;

  @override
  State<RemoteControlLayer> createState() => _RemoteControlLayerState();
}

class _RemoteControlLayerState extends State<RemoteControlLayer> {
  final _focus = FocusNode();
  bool _dialogShown = false;
  int _buttons = 0;
  bool _controlling = false;
  bool _hosting = false;
  bool _requested = false;
  String? _error;

  CallSession get session => widget.session;

  @override
  void initState() {
    super.initState();
    session.addListener(_onSession);
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
    _syncFlags();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybePrompt());
  }

  @override
  void didUpdateWidget(covariant RemoteControlLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      oldWidget.session.removeListener(_onSession);
      widget.session.addListener(_onSession);
      _dialogShown = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybePrompt());
    }
  }

  @override
  void dispose() {
    session.removeListener(_onSession);
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _focus.dispose();
    super.dispose();
  }

  void _syncFlags() {
    _controlling = session.isRemoteController;
    _hosting = session.isRemoteHost;
    _requested =
        session.remoteControl?.state.auth == RemoteControlAuth.requested;
    _error = session.remoteControlError;
  }

  void _onSession() {
    if (!mounted) return;
    _maybePrompt();
    final nextControlling = session.isRemoteController;
    final nextHosting = session.isRemoteHost;
    final nextRequested =
        session.remoteControl?.state.auth == RemoteControlAuth.requested;
    final nextError = session.remoteControlError;
    final changed = nextControlling != _controlling ||
        nextHosting != _hosting ||
        nextRequested != _requested ||
        nextError != _error;
    // Hosting paints into the shared desktop — collapse the big call UI.
    if (nextHosting && !_hosting) {
      widget.state?.setCallMinimized(true);
    }
    if (changed) {
      setState(() {
        _controlling = nextControlling;
        _hosting = nextHosting;
        _requested = nextRequested;
        _error = nextError;
      });
    }
    if (session.isRemoteController && !_focus.hasFocus) {
      _focus.requestFocus();
    }
  }

  Future<void> _maybePrompt() async {
    if (!mounted || _dialogShown) return;
    if (!session.remoteControlIncomingRequest) return;

    final rc = session.remoteControl;
    if (rc?.consentDialogOpen == true) return;

    // Claim immediately so concurrent session notifications cannot open
    // multiple consent dialogs.
    _dialogShown = true;
    rc?.setConsentDialogOpen(true);

    try {
      // Dedicated control invite already had Allow at ring time — grant silently.
      if (session.isControlCall) {
        await session.grantRemoteControl();
        return;
      }

      final state = widget.state;
      if (state != null && state.shouldAutoAllowControl(session.peer.id)) {
        await session.grantRemoteControl();
        return;
      }

      final peer = session.peer.displayName;
      await session.remoteControl?.refreshCapability();
      if (!mounted) return;
      final cap = session.remoteInputCapability;
      final canInject = cap?.canInject == true;
      var alwaysAllow = false;
      final accepted = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (ctx, setLocal) => AlertDialog(
              backgroundColor: PrivetTheme.panel,
              title: Text(
                canInject
                    ? 'Allow remote control?'
                    : 'Cannot grant remote control',
                style: GoogleFonts.syne(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    canInject
                        ? '$peer is asking to control your shared screen — mouse and keyboard. '
                            'You can revoke access at any time.'
                        : remoteControlHostCannotInjectMessage(
                            platform: cap?.platform ?? '',
                            detail: cap?.detail ?? '',
                          ),
                    style: GoogleFonts.dmSans(
                      color: PrivetTheme.mist,
                      height: 1.35,
                    ),
                  ),
                  if (canInject) ...[
                    const SizedBox(height: 14),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: alwaysAllow,
                      onChanged: (v) => setLocal(() => alwaysAllow = v == true),
                      title: Text(
                        'Always allow from $peer while Privet is open',
                        style: GoogleFonts.dmSans(
                          color: PrivetTheme.paper,
                          fontSize: 13,
                        ),
                      ),
                      controlAffinity: ListTileControlAffinity.leading,
                      activeColor: PrivetTheme.signal,
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(
                    canInject ? 'Deny' : 'OK',
                    style: GoogleFonts.dmSans(color: PrivetTheme.mist),
                  ),
                ),
                if (canInject)
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: PrivetTheme.signal,
                    ),
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(
                      'Allow',
                      style: GoogleFonts.dmSans(fontWeight: FontWeight.w600),
                    ),
                  ),
              ],
            ),
          );
        },
      );
      if (!mounted) return;
      if (accepted == true) {
        if (alwaysAllow) {
          widget.state?.rememberAutoAllowControl(session.peer.id);
        }
        await session.grantRemoteControl();
      } else if (canInject) {
        session.denyRemoteControl();
      } else {
        session.denyRemoteControl(
          reason: remoteControlHostCannotInjectMessage(
            platform: cap?.platform ?? '',
            detail: cap?.detail ?? '',
          ),
        );
      }
    } finally {
      session.remoteControl?.setConsentDialogOpen(false);
      if (mounted) {
        _dialogShown = false;
      }
    }
  }

  ({double x, double y})? _map(Offset local, Size size) {
    final rc = session.remoteControl?.state;
    final aspect = (rc != null && rc.hasGeometry)
        ? rc.displayWidth / rc.displayHeight
        : 16 / 9;
    return RemoteControlProtocol.mapLetterboxedPoint(
      localX: local.dx,
      localY: local.dy,
      viewportWidth: size.width,
      viewportHeight: size.height,
      contentAspect: aspect,
    );
  }

  bool _onHardwareKey(KeyEvent event) {
    if (!session.isRemoteHost) return false;
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.escape) return false;
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    final ctrl = keys.contains(LogicalKeyboardKey.controlLeft) ||
        keys.contains(LogicalKeyboardKey.controlRight);
    final shift = keys.contains(LogicalKeyboardKey.shiftLeft) ||
        keys.contains(LogicalKeyboardKey.shiftRight);
    if (!ctrl || !shift) return false;
    session.revokeRemoteControl();
    return true;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!session.isRemoteController) return KeyEventResult.ignored;
    // OS auto-repeat floods the channel; dropped KeyUps leave stuck keys
    // (endless "p"). Host sees a held key from the initial KeyDown alone.
    if (event is KeyRepeatEvent) return KeyEventResult.handled;

    // Always normalize: Flutter web often yields "Alt Left" (space) which
    // native KeyvalFromCode only knows as "AltLeft" — Alt/Super were no-ops.
    final code = _webCode(event);
    if (code.isEmpty) return KeyEventResult.ignored;
    final mods = _mods();
    final down = event is KeyDownEvent;

    // Esc exits fullscreen / does not revoke control.
    if (down &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        mods == 0) {
      if (PrivetFullscreen.isFullscreen) {
        PrivetFullscreen.exit();
        return KeyEventResult.handled;
      }
      // Still forward Escape to the remote desktop.
    }

    // Alt / Super: only when the controller tab is fullscreen — otherwise
    // leave them for the laptop (browser chrome, local dash, etc.).
    final isAltOrSuper = code == 'AltLeft' ||
        code == 'AltRight' ||
        code == 'MetaLeft' ||
        code == 'MetaRight' ||
        code == 'OSLeft' ||
        code == 'OSRight' ||
        code == 'SuperLeft' ||
        code == 'SuperRight';
    if (isAltOrSuper && !PrivetFullscreen.isFullscreen) {
      return KeyEventResult.ignored;
    }

    // Push local clipboard to the host before Ctrl/Cmd+V so paste works
    // from the controller browser (never call clipboard.read — that popup).
    if (down && _isPasteChord(code: code, mods: mods)) {
      final text = AppClipboard.peek();
      if (text != null && text.isNotEmpty) {
        unawaited(_pasteRemote(code: code, mods: mods, key: event.character));
        return KeyEventResult.handled;
      }
    }

    session.remoteControl?.sendKey(
      code: code,
      down: down,
      mods: mods,
      key: event.character,
    );
    return KeyEventResult.handled;
  }

  Future<void> _pasteRemote({
    required String code,
    required int mods,
    String? key,
  }) async {
    final rc = session.remoteControl;
    if (rc == null) return;
    final text = AppClipboard.peek();
    if (text != null && text.isNotEmpty) {
      await rc.sendClipboardText(text);
      // Give the host a beat to apply OS clipboard before Ctrl+V lands.
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await rc.sendKey(code: code, down: true, mods: mods, key: key);
    await rc.sendKey(code: code, down: false, mods: mods, key: key);
  }

  bool _isPasteChord({required String code, required int mods}) {
    final ctrl = (mods & RemoteKeyMods.ctrl) != 0;
    final meta = (mods & RemoteKeyMods.meta) != 0;
    if (!ctrl && !meta) return false;
    return code == 'KeyV' || code == 'Key V' || code.toLowerCase() == 'v';
  }

  String _webCode(KeyEvent event) {
    // Prefer stable PhysicalKeyboardKey debug names (e.g. "Key A" / "Digit 1").
    final phys = event.physicalKey.debugName;
    if (phys != null && phys.isNotEmpty) {
      return phys.replaceAll(' ', '');
    }
    final logical = event.logicalKey.debugName;
    if (logical != null && logical.isNotEmpty) {
      return logical.replaceAll(' ', '');
    }
    return event.logicalKey.keyLabel.replaceAll(' ', '');
  }

  int _mods() {
    var m = 0;
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    if (keys.contains(LogicalKeyboardKey.shiftLeft) ||
        keys.contains(LogicalKeyboardKey.shiftRight)) {
      m |= RemoteKeyMods.shift;
    }
    if (keys.contains(LogicalKeyboardKey.controlLeft) ||
        keys.contains(LogicalKeyboardKey.controlRight)) {
      m |= RemoteKeyMods.ctrl;
    }
    if (keys.contains(LogicalKeyboardKey.altLeft) ||
        keys.contains(LogicalKeyboardKey.altRight)) {
      m |= RemoteKeyMods.alt;
    }
    if (keys.contains(LogicalKeyboardKey.metaLeft) ||
        keys.contains(LogicalKeyboardKey.metaRight)) {
      m |= RemoteKeyMods.meta;
    }
    return m;
  }

  int _btnMask(int buttons) {
    var m = 0;
    if ((buttons & kPrimaryButton) != 0) m |= RemotePointerButton.primary;
    if ((buttons & kSecondaryButton) != 0) m |= RemotePointerButton.secondary;
    if ((buttons & kMiddleMouseButton) != 0) m |= RemotePointerButton.middle;
    return m;
  }

  @override
  Widget build(BuildContext context) {
    final controlling = _controlling;
    final hosting = _hosting;
    final requested = _requested;
    // Host banners paint into the shared desktop — never show them.
    final showBanner = !widget.immersive &&
        !hosting &&
        (controlling || requested);

    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (controlling)
          Positioned.fill(
            child: Focus(
              focusNode: _focus,
              autofocus: true,
              onKeyEvent: _onKey,
              onFocusChange: (hasFocus) {
                if (!hasFocus) {
                  session.remoteControl?.sendFocusLost();
                  _buttons = 0;
                }
              },
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerHover: (e) {
                  final box = context.findRenderObject() as RenderBox?;
                  if (box == null) return;
                  final local = box.globalToLocal(e.position);
                  final mapped = _map(local, box.size);
                  if (mapped == null) return;
                  session.remoteControl?.sendPointerMove(
                    mapped.x,
                    mapped.y,
                    buttons: _buttons,
                  );
                },
                onPointerMove: (e) {
                  final box = context.findRenderObject() as RenderBox?;
                  if (box == null) return;
                  final local = box.globalToLocal(e.position);
                  final mapped = _map(local, box.size);
                  if (mapped == null) return;
                  session.remoteControl?.sendPointerMove(
                    mapped.x,
                    mapped.y,
                    buttons: _buttons,
                  );
                },
                onPointerDown: (e) {
                  _focus.requestFocus();
                  final box = context.findRenderObject() as RenderBox?;
                  if (box == null) return;
                  final local = box.globalToLocal(e.position);
                  final mapped = _map(local, box.size);
                  final btn = _btnMask(e.buttons);
                  if (mapped == null) return;
                  _buttons = btn;
                  session.remoteControl?.sendPointerButton(
                    x: mapped.x,
                    y: mapped.y,
                    button: btn == 0 ? RemotePointerButton.primary : btn,
                    down: true,
                    buttons: _buttons,
                  );
                },
                onPointerUp: (e) {
                  final box = context.findRenderObject() as RenderBox?;
                  if (box == null) return;
                  final local = box.globalToLocal(e.position);
                  final mapped = _map(local, box.size);
                  if (mapped == null) return;
                  final prev = _buttons;
                  _buttons = _btnMask(e.buttons);
                  session.remoteControl?.sendPointerButton(
                    x: mapped.x,
                    y: mapped.y,
                    button: prev == 0 ? RemotePointerButton.primary : prev,
                    down: false,
                    buttons: _buttons,
                  );
                },
                onPointerSignal: (e) {
                  if (e is! PointerScrollEvent) return;
                  final box = context.findRenderObject() as RenderBox?;
                  if (box == null) return;
                  final local = box.globalToLocal(e.position);
                  final mapped = _map(local, box.size);
                  if (mapped == null) return;
                  session.remoteControl?.sendWheel(
                    x: mapped.x,
                    y: mapped.y,
                    dx: e.scrollDelta.dx,
                    dy: e.scrollDelta.dy,
                  );
                },
                child: MouseRegion(
                  cursor: SystemMouseCursors.basic,
                  onExit: (_) {
                    session.remoteControl?.sendFocusLost();
                    _buttons = 0;
                  },
                  child: const ColoredBox(color: Color(0x01000000)),
                ),
              ),
            ),
          ),
        if (showBanner)
          Positioned(
            left: 16,
            right: 16,
            bottom: 110,
            child: _RemoteControlBanner(
              session: session,
              controlling: controlling,
              hosting: false,
              requested: requested && !controlling,
            ),
          ),
      ],
    );
  }
}

class _RemoteControlBanner extends StatelessWidget {
  const _RemoteControlBanner({
    required this.session,
    required this.controlling,
    required this.hosting,
    required this.requested,
  });

  final CallSession session;
  final bool controlling;
  final bool hosting;
  final bool requested;

  @override
  Widget build(BuildContext context) {
    late final String text;
    late final Color color;
    if (hosting) {
      text =
          '${session.peer.displayName} is controlling your screen — Ctrl+Shift+Esc to stop';
      color = const Color(0xFFFFA726);
    } else if (controlling) {
      text = 'Controlling ${session.peer.displayName}';
      color = PrivetTheme.signal;
    } else {
      text = 'Waiting for ${session.peer.displayName} to allow control…';
      color = PrivetTheme.mist;
    }

    return Center(
      child: Material(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.mouse_rounded, size: 16, color: color),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  text,
                  style: GoogleFonts.dmSans(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (hosting || controlling) ...[
                const SizedBox(width: 10),
                TextButton(
                  onPressed: () => session.revokeRemoteControl(),
                  style: TextButton.styleFrom(
                    foregroundColor: PrivetTheme.danger,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    hosting ? 'Stop' : 'Release',
                    style: GoogleFonts.dmSans(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
