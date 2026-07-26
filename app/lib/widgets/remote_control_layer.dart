import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../remote_control/protocol.dart';
import '../state.dart';
import '../theme.dart';

/// Host consent dialog + banner; controller input capture over the stage.
class RemoteControlLayer extends StatefulWidget {
  const RemoteControlLayer({
    super.key,
    required this.session,
    required this.child,
  });

  final CallSession session;
  final Widget child;

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
    _dialogShown = true;
    final peer = session.peer.displayName;
    await session.remoteControl?.refreshCapability();
    if (!mounted) {
      _dialogShown = false;
      return;
    }
    final cap = session.remoteInputCapability;
    final canInject = cap?.canInject == true;
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: PrivetTheme.panel,
        title: Text(
          canInject ? 'Allow remote control?' : 'Cannot grant remote control',
          style: GoogleFonts.syne(color: Colors.white, fontWeight: FontWeight.w700),
        ),
        content: Text(
          canInject
              ? '$peer is asking to control your shared screen — mouse and keyboard. '
                  'You can revoke access at any time.'
              : remoteControlHostCannotInjectMessage(
                  platform: cap?.platform ?? '',
                  detail: cap?.detail ?? '',
                ),
          style: GoogleFonts.dmSans(color: PrivetTheme.mist, height: 1.35),
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
              style: FilledButton.styleFrom(backgroundColor: PrivetTheme.signal),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Allow', style: GoogleFonts.dmSans(fontWeight: FontWeight.w600)),
            ),
        ],
      ),
    );
    _dialogShown = false;
    if (!mounted) return;
    if (accepted == true) {
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

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!session.isRemoteController) return KeyEventResult.ignored;
    final code = event.logicalKey.keyLabel.isEmpty
        ? event.physicalKey.debugName ?? event.logicalKey.debugName ?? ''
        : _webCode(event);
    if (code.isEmpty) return KeyEventResult.ignored;
    final mods = _mods();
    final down = event is KeyDownEvent || event is KeyRepeatEvent;
    // Escape stops control when not combined with modifiers.
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        mods == 0) {
      session.revokeRemoteControl();
      return KeyEventResult.handled;
    }
    session.remoteControl?.sendKey(
      code: code,
      down: down,
      mods: mods,
      key: event.character,
    );
    return KeyEventResult.handled;
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
    return event.logicalKey.keyLabel;
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
                  if (mapped == null) return;
                  final btn = _btnMask(e.buttons);
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
                  cursor: SystemMouseCursors.precise,
                  onExit: (_) {
                    session.remoteControl?.sendFocusLost();
                    _buttons = 0;
                  },
                  child: const ColoredBox(color: Color(0x01000000)),
                ),
              ),
            ),
          ),
        if (controlling || hosting || requested)
          Positioned(
            left: 16,
            right: 16,
            bottom: 110,
            child: _RemoteControlBanner(
              session: session,
              controlling: controlling,
              hosting: hosting,
              requested: requested && !hosting && !controlling,
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
      text = '${session.peer.displayName} is controlling your screen';
      color = const Color(0xFFFFA726);
    } else if (controlling) {
      text = 'Controlling ${session.peer.displayName} — Esc to stop';
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
