import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state.dart';
import '../theme.dart';
import '../util/app_update.dart';

/// Floating "Update available" card (bottom-right) for **Windows only**.
///
/// Linux/macOS/web never mount this widget — desktop Linux updates are manual
/// (.deb / .tar.gz), so a popup there would be noise. The file still lives in
/// the shared GitHub tree so every Windows `.exe` build picks it up on pull.
class UpdateAvailableBanner extends StatefulWidget {
  const UpdateAvailableBanner({super.key, required this.state});

  final PrivetState state;

  /// Safe to call from the shell on every platform; returns a no-op off Windows.
  static Widget maybe({required PrivetState state}) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
      return const SizedBox.shrink();
    }
    return UpdateAvailableBanner(state: state);
  }

  @override
  State<UpdateAvailableBanner> createState() => _UpdateAvailableBannerState();
}

class _UpdateAvailableBannerState extends State<UpdateAvailableBanner>
    with WidgetsBindingObserver {
  /// Version the user dismissed with "Later" — hidden until a newer release.
  static const _dismissedKey = 'privet_update_dismissed_version';
  static const _firstCheckDelay = Duration(seconds: 4);
  static const _recheckInterval = Duration(hours: 4);

  Timer? _timer;
  AppUpdateStatus? _status;
  String? _dismissedVersion;
  bool _updating = false;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _dismissedVersion = prefs.getString(_dismissedKey);
    } catch (_) {
      // Storage unavailable — still check, just without dismissal memory.
    }
    _timer = Timer.periodic(_recheckInterval, (_) => unawaited(_check()));
    await Future<void>.delayed(_firstCheckDelay);
    await _check();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_check());
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _check() async {
    if (!mounted || _updating) return;
    AppUpdateStatus status;
    try {
      status = await AppUpdate.check(baseUrl: widget.state.api.baseUrl);
    } catch (_) {
      return; // Offline / server hiccup — retry on the next tick.
    }
    if (!mounted) return;
    final version = status.latest?.version ?? '';
    if (status.updateAvailable && version.isEmpty) return;
    if (status.updateAvailable && version == _dismissedVersion) return;
    setState(() => _status = status.updateAvailable ? status : null);
  }

  Future<void> _dismiss() async {
    final version = _status?.latest?.version;
    setState(() => _status = null);
    if (version == null || version.isEmpty) return;
    _dismissedVersion = version;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_dismissedKey, version);
    } catch (_) {}
  }

  String _setupUrl(AppUpdateStatus status) {
    final latest = status.latest;
    if (latest == null) return '';
    final rel = latest.windowsSetupUrl;
    if (rel == null || rel.isEmpty) return '';
    if (rel.startsWith('http://') || rel.startsWith('https://')) return rel;
    final origin = widget.state.api.baseUrl.replaceAll(RegExp(r'/+$'), '');
    return '$origin${rel.startsWith('/') ? rel : '/$rel'}';
  }

  Future<void> _install() async {
    final status = _status;
    if (status == null || _updating) return;
    final url = _setupUrl(status);
    if (url.isEmpty) return;
    setState(() {
      _updating = true;
      _progress = 0;
    });
    try {
      await AppUpdate.applyWindowsUpdate(
        setupUrl: url,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _updating = false);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text('Update failed: $e'),
          backgroundColor: PrivetTheme.danger,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    if (status == null) return const SizedBox.shrink();
    final version = status.latest?.version ?? '';
    final busy = _updating;
    final label = _updating
        ? (_progress > 0 && _progress < 1
              ? 'Downloading ${(_progress * 100).round()}%'
              : 'Installing…')
        : 'Update now';

    return Positioned(
      right: 16,
      bottom: 16,
      child: Material(
        color: PrivetTheme.panelElevated,
        elevation: 10,
        shadowColor: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: 330,
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: PrivetTheme.line),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.system_update_alt_rounded,
                    size: 20,
                    color: PrivetTheme.signal,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Update available',
                      style: GoogleFonts.syne(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: PrivetTheme.paper,
                      ),
                    ),
                  ),
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: busy ? null : _dismiss,
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(
                        Icons.close_rounded,
                        size: 18,
                        color: PrivetTheme.mist,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Text(
                  version.isEmpty
                      ? 'A newer version of Privet is ready to install.'
                      : 'Privet $version is ready — it will install and restart the app.',
                  style: TextStyle(
                    color: PrivetTheme.mist,
                    fontSize: 12.5,
                    height: 1.3,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: busy ? null : _install,
                    icon: busy
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: PrivetTheme.onAccent,
                            ),
                          )
                        : const Icon(Icons.download_rounded, size: 18),
                    label: Text(label),
                  ),
                  const SizedBox(width: 6),
                  TextButton(
                    onPressed: busy ? null : _dismiss,
                    child: const Text('Later'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
