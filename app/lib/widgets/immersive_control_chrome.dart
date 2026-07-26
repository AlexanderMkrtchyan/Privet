import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../remote_control/protocol.dart';
import '../state.dart';
import '../theme.dart';
import '../util/fullscreen.dart';
import '../util/low_resource.dart';

/// Auto-hide AnyDesk-style chrome for immersive remote control.
class ImmersiveControlChrome extends StatefulWidget {
  const ImmersiveControlChrome({
    super.key,
    required this.state,
    required this.session,
    required this.elapsed,
    this.onToolbarVisibility,
  });

  final PrivetState state;
  final CallSession session;
  final String elapsed;
  final ValueChanged<bool>? onToolbarVisibility;

  @override
  State<ImmersiveControlChrome> createState() => _ImmersiveControlChromeState();
}

class _ImmersiveControlChromeState extends State<ImmersiveControlChrome> {
  bool _pinned = false;
  bool _hoverTop = false;
  Timer? _hideTimer;
  bool _visible = true;

  CallSession get session => widget.session;

  @override
  void initState() {
    super.initState();
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  void _setVisible(bool v) {
    if (_visible == v) return;
    setState(() => _visible = v);
    widget.onToolbarVisibility?.call(v);
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (_pinned || _hoverTop) return;
    _hideTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted || _pinned || _hoverTop) return;
      _setVisible(false);
    });
  }

  void _reveal() {
    _setVisible(true);
    _scheduleHide();
  }

  Future<void> _toggleFullscreen() async {
    await PrivetFullscreen.toggle();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final peer = session.peer.displayName;
    final quality = session.remoteControl?.quality ?? RemoteControlQuality.balanced;
    final displays = session.remoteControl?.peerDisplays ?? const [];
    final activeId = session.remoteControl?.activeDisplayId;
    final controlling = session.isRemoteController;
    final hosting = session.isRemoteHost;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Reveal strip must NOT steal hits — top bar / panel clicks go through
        // to RemoteControlLayer (HitTestBehavior.translucent).
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: 28,
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerHover: (_) {
              _hoverTop = true;
              _reveal();
            },
            onPointerMove: (_) {
              _hoverTop = true;
              _reveal();
            },
            child: const SizedBox.expand(),
          ),
        ),
        // When hidden (off-screen + ignore), remote top edge stays clickable.
        AnimatedPositioned(
          duration: privetAnim(const Duration(milliseconds: 180)),
          curve: Curves.easeOutCubic,
          left: 12,
          right: 12,
          top: _visible ? 12 : -72,
          child: IgnorePointer(
            ignoring: !_visible,
            child: MouseRegion(
            onEnter: (_) {
              _hoverTop = true;
              _reveal();
            },
            onExit: (_) {
              _hoverTop = false;
              _scheduleHide();
            },
            child: Material(
              color: Colors.black.withValues(alpha: 0.78),
              borderRadius: BorderRadius.circular(14),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.mouse_rounded,
                      size: 18,
                      color: hosting ? const Color(0xFFFFA726) : PrivetTheme.signal,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        hosting
                            ? '$peer controlling • ${widget.elapsed}'
                            : 'Controlling $peer • ${widget.elapsed}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.dmSans(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    if (controlling) ...[
                      _ToolbarMenuButton(
                        icon: Icons.high_quality_rounded,
                        tooltip: 'Quality',
                        child: PopupMenuButton<RemoteControlQuality>(
                          tooltip: 'Quality',
                          initialValue: quality,
                          onSelected: (m) => session.setRemoteControlQuality(m),
                          itemBuilder: (ctx) => [
                            const PopupMenuItem(
                              value: RemoteControlQuality.quality,
                              child: Text('Quality (1080p)'),
                            ),
                            const PopupMenuItem(
                              value: RemoteControlQuality.balanced,
                              child: Text('Balanced'),
                            ),
                            const PopupMenuItem(
                              value: RemoteControlQuality.speed,
                              child: Text('Speed'),
                            ),
                          ],
                          child: _chipLabel(_qualityLabel(quality)),
                        ),
                      ),
                      if (displays.length > 1)
                        _ToolbarMenuButton(
                          icon: Icons.desktop_windows_rounded,
                          tooltip: 'Display',
                          child: PopupMenuButton<String>(
                            tooltip: 'Switch display',
                            initialValue: activeId,
                            onSelected: (id) =>
                                session.remoteControl?.requestSwitchDisplay(id),
                            itemBuilder: (ctx) => [
                              for (final d in displays)
                                PopupMenuItem(
                                  value: d.id,
                                  child: Text(
                                    d.id == activeId ? '✓ ${d.name}' : d.name,
                                  ),
                                ),
                            ],
                            child: _chipLabel('Display'),
                          ),
                        ),
                    ],
                    IconButton(
                      tooltip: PrivetFullscreen.isFullscreen
                          ? 'Exit fullscreen'
                          : 'Fullscreen',
                      onPressed: _toggleFullscreen,
                      icon: Icon(
                        PrivetFullscreen.isFullscreen
                            ? Icons.fullscreen_exit_rounded
                            : Icons.fullscreen_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                    IconButton(
                      tooltip: _pinned ? 'Auto-hide toolbar' : 'Pin toolbar',
                      onPressed: () {
                        setState(() => _pinned = !_pinned);
                        if (_pinned) {
                          _setVisible(true);
                        } else {
                          _scheduleHide();
                        }
                      },
                      icon: Icon(
                        _pinned ? Icons.push_pin : Icons.push_pin_outlined,
                        color: Colors.white70,
                        size: 18,
                      ),
                    ),
                    if (controlling || hosting)
                      TextButton(
                        onPressed: () => session.revokeRemoteControl(),
                        child: Text(
                          hosting ? 'Stop' : 'Stop control',
                          style: GoogleFonts.dmSans(
                            color: const Color(0xFFFFA726),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    TextButton(
                      onPressed: () => widget.state.endCall(),
                      child: Text(
                        'End',
                        style: GoogleFonts.dmSans(
                          color: PrivetTheme.danger,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Minimize',
                      onPressed: () => widget.state.setCallMinimized(true),
                      icon: const Icon(
                        Icons.close_fullscreen_rounded,
                        color: Colors.white70,
                        size: 18,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        ),
        // No host banners — they paint into the shared desktop capture.
      ],
    );
  }

  String _qualityLabel(RemoteControlQuality q) {
    switch (q) {
      case RemoteControlQuality.quality:
        return 'Quality';
      case RemoteControlQuality.balanced:
        return 'Balanced';
      case RemoteControlQuality.speed:
        return 'Speed';
    }
  }

  Widget _chipLabel(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Text(
        text,
        style: GoogleFonts.dmSans(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ToolbarMenuButton extends StatelessWidget {
  const _ToolbarMenuButton({
    required this.icon,
    required this.tooltip,
    required this.child,
  });

  final IconData icon;
  final String tooltip;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Colors.white70),
          child,
        ],
      ),
    );
  }
}
