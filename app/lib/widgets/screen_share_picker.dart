import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme.dart';
import '../util/browser_kind.dart';
import '../util/display_capture.dart';
import '../util/display_share_surface.dart';

/// Privet-styled chooser shown before the browser's native share dialog.
///
/// Chrome/Edge: options hint the native picker (screen / window / tab with
/// previews). [getDisplayMedia] still runs on the option click.
///
/// Firefox: cannot list or preview other tabs from a website — that UI is
/// Chromium-only. The "browser tab" row stays visible so the sheet matches
/// Chrome, but tapping it never opens Firefox's title-only portal dropdown;
/// it explains the limit and offers window share instead.
Future<MediaStream?> showScreenSharePicker(BuildContext context) {
  return showDialog<MediaStream>(
    context: context,
    barrierColor: PrivetTheme.ink.withValues(alpha: 0.72),
    builder: (ctx) {
      return Dialog(
        backgroundColor: PrivetTheme.panelElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: PrivetTheme.signal.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.screen_share_rounded,
                        size: 22,
                        color: PrivetTheme.signal,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Share your screen',
                            style: GoogleFonts.syne(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              color: PrivetTheme.paper,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            isFirefoxBrowser
                                ? 'Same options as Chrome. Tab previews aren’t available in Firefox — use a window for other sites.'
                                : 'Pick a type — Chrome will then show previews so you can choose the exact screen, window, or tab.',
                            style: GoogleFonts.ibmPlexSans(
                              fontSize: 13,
                              color: PrivetTheme.mist,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                _ShareOption(
                  icon: Icons.desktop_windows_rounded,
                  title: 'Entire screen',
                  subtitle: 'Share everything on a display',
                  surface: DisplayShareSurface.monitor,
                ),
                const SizedBox(height: 10),
                _ShareOption(
                  icon: Icons.web_asset_rounded,
                  title: 'A window',
                  subtitle: 'Share one application window',
                  surface: DisplayShareSurface.window,
                ),
                const SizedBox(height: 10),
                if (isFirefoxBrowser)
                  const _FirefoxTabOption()
                else
                  _ShareOption(
                    icon: Icons.tab_rounded,
                    title: 'A browser tab',
                    subtitle: 'Pick any open tab (with previews)',
                    surface: DisplayShareSurface.browser,
                  ),
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(
                      'Cancel',
                      style: GoogleFonts.ibmPlexSans(
                        color: PrivetTheme.mist,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// Firefox cannot open a Chrome-style tab picker from a website. Stay inside
/// Privet — never call getDisplayMedia from this row (that only shows the
/// title-only OS dropdown).
class _FirefoxTabOption extends StatefulWidget {
  const _FirefoxTabOption();

  @override
  State<_FirefoxTabOption> createState() => _FirefoxTabOptionState();
}

class _FirefoxTabOptionState extends State<_FirefoxTabOption> {
  bool _hover = false;
  bool _expanded = false;
  bool _busy = false;
  String? _error;

  Future<void> _shareWindow() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final stream =
          await captureDisplayMedia(prefer: DisplayShareSurface.window);
      if (!mounted) {
        for (final t in stream.getTracks()) {
          await t.stop();
        }
        await stream.dispose();
        return;
      }
      Navigator.pop(context, stream);
    } catch (e) {
      if (!mounted) return;
      final msg = '$e';
      if (msg.toLowerCase().contains('cancel')) {
        Navigator.pop(context);
        return;
      }
      setState(() {
        _busy = false;
        _error = msg.replaceFirst('Bad state: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: Material(
            color: _hover || _expanded ? PrivetTheme.panel : PrivetTheme.ink,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              onTap: _busy
                  ? null
                  : () => setState(() => _expanded = !_expanded),
              borderRadius: BorderRadius.circular(14),
              mouseCursor: SystemMouseCursors.basic,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: _hover || _expanded
                        ? PrivetTheme.signal
                        : PrivetTheme.line,
                    width: _hover || _expanded ? 1.5 : 1,
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: PrivetTheme.panelElevated,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.tab_rounded,
                        size: 24,
                        color: PrivetTheme.paper,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'A browser tab',
                            style: GoogleFonts.syne(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: PrivetTheme.paper,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Not available in Firefox — tap for how to share another site',
                            style: GoogleFonts.ibmPlexSans(
                              fontSize: 13,
                              color: PrivetTheme.mist,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      _expanded
                          ? Icons.expand_less_rounded
                          : Icons.chevron_right_rounded,
                      size: 24,
                      color: _hover || _expanded
                          ? PrivetTheme.signal
                          : PrivetTheme.mist,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_expanded) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
            decoration: BoxDecoration(
              color: PrivetTheme.ink,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: PrivetTheme.line),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Firefox blocks websites from listing your other tabs or showing Chrome-style previews. Opening its share menu here only gives a title list — so Privet won’t do that.',
                  style: GoogleFonts.ibmPlexSans(
                    fontSize: 13,
                    color: PrivetTheme.mist,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'To share another site in Firefox: share a window and pick that Firefox window (switch the tab you want first). For real tab picking with previews, use Chrome or Edge.',
                  style: GoogleFonts.ibmPlexSans(
                    fontSize: 13,
                    color: PrivetTheme.paper,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: _busy ? null : _shareWindow,
                  style: FilledButton.styleFrom(
                    backgroundColor: PrivetTheme.signal,
                    foregroundColor: PrivetTheme.onAccent,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                  ),
                  icon: _busy
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: PrivetTheme.onAccent,
                          ),
                        )
                      : const Icon(Icons.web_asset_rounded, size: 20),
                  label: Text(
                    _busy ? 'Waiting for browser…' : 'Share a window instead',
                    style: GoogleFonts.ibmPlexSans(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 6),
          Text(
            _error!,
            style: GoogleFonts.ibmPlexSans(
              fontSize: 12,
              color: PrivetTheme.danger,
            ),
          ),
        ],
      ],
    );
  }
}

class _ShareOption extends StatefulWidget {
  const _ShareOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.surface,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final DisplayShareSurface surface;

  @override
  State<_ShareOption> createState() => _ShareOptionState();
}

class _ShareOptionState extends State<_ShareOption> {
  bool _hover = false;
  bool _busy = false;
  String? _error;

  Future<void> _pick() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Must run in this click handler — browsers drop user activation otherwise.
      final stream = await captureDisplayMedia(prefer: widget.surface);
      if (!mounted) {
        for (final t in stream.getTracks()) {
          await t.stop();
        }
        await stream.dispose();
        return;
      }
      Navigator.pop(context, stream);
    } catch (e) {
      if (!mounted) return;
      final msg = '$e';
      if (msg.toLowerCase().contains('cancel')) {
        // Native picker dismissed — close Privet dialog too (one cancel = done).
        Navigator.pop(context);
        return;
      }
      setState(() {
        _busy = false;
        _error = msg.replaceFirst('Bad state: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: Material(
            color: _hover ? PrivetTheme.panel : PrivetTheme.ink,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              onTap: _busy ? null : _pick,
              borderRadius: BorderRadius.circular(14),
              mouseCursor: SystemMouseCursors.basic,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: _hover ? PrivetTheme.signal : PrivetTheme.line,
                    width: _hover ? 1.5 : 1,
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: PrivetTheme.panelElevated,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: _busy
                          ? Padding(
                              padding: EdgeInsets.all(12),
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: PrivetTheme.signal,
                              ),
                            )
                          : Icon(
                              widget.icon,
                              size: 24,
                              color: PrivetTheme.paper,
                            ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.title,
                            style: GoogleFonts.syne(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: PrivetTheme.paper,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _busy
                                ? 'Waiting for browser confirmation…'
                                : widget.subtitle,
                            style: GoogleFonts.ibmPlexSans(
                              fontSize: 13,
                              color: PrivetTheme.mist,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 24,
                      color: _hover ? PrivetTheme.signal : PrivetTheme.mist,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 6),
          Text(
            _error!,
            style: GoogleFonts.ibmPlexSans(
              fontSize: 12,
              color: PrivetTheme.danger,
            ),
          ),
        ],
      ],
    );
  }
}
