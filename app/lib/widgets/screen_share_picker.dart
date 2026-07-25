import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme.dart';
import '../util/browser_kind.dart';
import '../util/display_capture.dart';

/// Privet-styled chooser before capture.
///
/// **Web (Chrome/Edge):** options hint the native picker (screen / window /
/// tab). [getDisplayMedia] still runs on the option click.
///
/// **Web (Firefox):** cannot list/preview tabs — the tab row explains and
/// offers window share instead.
///
/// **Native desktop:** lists real screens/windows via [desktopCapturer]
/// (required — bare getDisplayMedia fails with "source not found!").
Future<MediaStream?> showScreenSharePicker(BuildContext context) {
  if (WebRTC.platformIsDesktop) {
    return showDialog<MediaStream>(
      context: context,
      barrierColor: PrivetTheme.ink.withValues(alpha: 0.72),
      builder: (ctx) => const _DesktopScreenShareDialog(),
    );
  }

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

/// Native Linux/Windows/macOS: pick a concrete DesktopCapturer source.
class _DesktopScreenShareDialog extends StatefulWidget {
  const _DesktopScreenShareDialog();

  @override
  State<_DesktopScreenShareDialog> createState() =>
      _DesktopScreenShareDialogState();
}

class _DesktopScreenShareDialogState extends State<_DesktopScreenShareDialog> {
  SourceType _type = SourceType.Screen;
  final Map<String, DesktopCapturerSource> _sources = {};
  final List<StreamSubscription> _subs = [];
  Timer? _refresh;
  String? _busyId;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _subs.add(desktopCapturer.onAdded.stream.listen((s) {
      if (!mounted) return;
      setState(() => _sources[s.id] = s);
    }));
    _subs.add(desktopCapturer.onRemoved.stream.listen((s) {
      if (!mounted) return;
      setState(() => _sources.remove(s.id));
    }));
    _subs.add(desktopCapturer.onThumbnailChanged.stream.listen((_) {
      if (mounted) setState(() {});
    }));
    _subs.add(desktopCapturer.onNameChanged.stream.listen((_) {
      if (mounted) setState(() {});
    }));
    unawaited(_loadSources());
  }

  @override
  void dispose() {
    _refresh?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  Future<void> _loadSources() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await desktopCapturer.getSources(
        types: [_type],
        thumbnailSize: ThumbnailSize(320, 180),
      );
      if (!mounted) return;
      _refresh?.cancel();
      _refresh = Timer.periodic(const Duration(seconds: 3), (_) {
        unawaited(desktopCapturer.updateSources(types: [_type]));
      });
      setState(() {
        _sources
          ..clear()
          ..addEntries(list.map((s) => MapEntry(s.id, s)));
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not list displays: $e';
      });
    }
  }

  Future<void> _pick(DesktopCapturerSource source) async {
    if (_busyId != null) return;
    setState(() {
      _busyId = source.id;
      _error = null;
    });
    try {
      final prefer = source.type == SourceType.Window
          ? DisplayShareSurface.window
          : DisplayShareSurface.monitor;
      final stream = await captureDisplayMedia(
        prefer: prefer,
        sourceId: source.id,
      );
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
        _busyId = null;
        _error = msg.replaceFirst('Bad state: ', '');
      });
    }
  }

  List<DesktopCapturerSource> get _filtered {
    return _sources.values.where((s) => s.type == _type).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  @override
  Widget build(BuildContext context) {
    final items = _filtered;
    return Dialog(
      backgroundColor: PrivetTheme.panelElevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 520),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
          child: Column(
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
                          'Pick a display or window to share with this call.',
                          style: GoogleFonts.ibmPlexSans(
                            fontSize: 13,
                            color: PrivetTheme.mist,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: Icon(Icons.close_rounded, color: PrivetTheme.mist),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  _TypeChip(
                    label: 'Entire screen',
                    selected: _type == SourceType.Screen,
                    onTap: _busyId != null
                        ? null
                        : () {
                            setState(() => _type = SourceType.Screen);
                            unawaited(_loadSources());
                          },
                  ),
                  const SizedBox(width: 8),
                  _TypeChip(
                    label: 'Window',
                    selected: _type == SourceType.Window,
                    onTap: _busyId != null
                        ? null
                        : () {
                            setState(() => _type = SourceType.Window);
                            unawaited(_loadSources());
                          },
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Expanded(
                child: _loading
                    ? Center(
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: PrivetTheme.signal,
                        ),
                      )
                    : items.isEmpty
                        ? Center(
                            child: Text(
                              _type == SourceType.Screen
                                  ? 'No displays found.'
                                  : 'No windows found.',
                              style: GoogleFonts.ibmPlexSans(
                                color: PrivetTheme.mist,
                              ),
                            ),
                          )
                        : GridView.builder(
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: _type == SourceType.Screen ? 2 : 3,
                              crossAxisSpacing: 10,
                              mainAxisSpacing: 10,
                              childAspectRatio:
                                  _type == SourceType.Screen ? 1.35 : 1.1,
                            ),
                            itemCount: items.length,
                            itemBuilder: (context, i) {
                              final src = items[i];
                              return _DesktopSourceTile(
                                source: src,
                                busy: _busyId == src.id,
                                enabled: _busyId == null,
                                onTap: () => _pick(src),
                              );
                            },
                          ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: GoogleFonts.ibmPlexSans(
                    fontSize: 12,
                    color: PrivetTheme.danger,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed:
                      _busyId != null ? null : () => Navigator.pop(context),
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
  }
}

class _TypeChip extends StatelessWidget {
  const _TypeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? PrivetTheme.signal.withValues(alpha: 0.18) : PrivetTheme.ink,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? PrivetTheme.signal : PrivetTheme.line,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Text(
            label,
            style: GoogleFonts.ibmPlexSans(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: selected ? PrivetTheme.signal : PrivetTheme.mist,
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopSourceTile extends StatefulWidget {
  const _DesktopSourceTile({
    required this.source,
    required this.busy,
    required this.enabled,
    required this.onTap,
  });

  final DesktopCapturerSource source;
  final bool busy;
  final bool enabled;
  final VoidCallback onTap;

  @override
  State<_DesktopSourceTile> createState() => _DesktopSourceTileState();
}

class _DesktopSourceTileState extends State<_DesktopSourceTile> {
  bool _hover = false;
  Uint8List? _thumb;
  StreamSubscription? _thumbSub;
  StreamSubscription? _nameSub;

  @override
  void initState() {
    super.initState();
    _thumb = widget.source.thumbnail;
    _thumbSub = widget.source.onThumbnailChanged.stream.listen((bytes) {
      if (mounted) setState(() => _thumb = bytes);
    });
    _nameSub = widget.source.onNameChanged.stream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant _DesktopSourceTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source.id != widget.source.id) {
      _thumbSub?.cancel();
      _nameSub?.cancel();
      _thumb = widget.source.thumbnail;
      _thumbSub = widget.source.onThumbnailChanged.stream.listen((bytes) {
        if (mounted) setState(() => _thumb = bytes);
      });
      _nameSub = widget.source.onNameChanged.stream.listen((_) {
        if (mounted) setState(() {});
      });
    } else if (widget.source.thumbnail != null) {
      _thumb = widget.source.thumbnail;
    }
  }

  @override
  void dispose() {
    _thumbSub?.cancel();
    _nameSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = _hover || widget.busy;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Material(
        color: PrivetTheme.ink,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: widget.enabled ? widget.onTap : null,
          borderRadius: BorderRadius.circular(12),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: active ? PrivetTheme.signal : PrivetTheme.line,
                width: active ? 1.5 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: ColoredBox(
                      color: PrivetTheme.panel,
                      child: widget.busy
                          ? Center(
                              child: SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: PrivetTheme.signal,
                                ),
                              ),
                            )
                          : _thumb != null
                              ? Image.memory(
                                  _thumb!,
                                  fit: BoxFit.contain,
                                  gaplessPlayback: true,
                                )
                              : Icon(
                                  widget.source.type == SourceType.Window
                                      ? Icons.web_asset_rounded
                                      : Icons.desktop_windows_rounded,
                                  color: PrivetTheme.mist,
                                  size: 28,
                                ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  widget.source.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.ibmPlexSans(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: PrivetTheme.paper,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
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
