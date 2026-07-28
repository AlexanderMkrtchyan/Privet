import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'screens/login_screen.dart';
import 'screens/messenger_shell.dart';
import 'state.dart';
import 'theme.dart';
import 'util/desktop_single_instance.dart';
import 'util/desktop_tray.dart';
import 'util/low_resource.dart';
import 'util/perf.dart';
import 'util/web_bootstrap.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Web only: expose semantics so assistive tech (and attach overlays) work.
  // On Linux/GTK a forced app-wide semantics tree adds per-frame overhead for
  // no desktop benefit (accessibility still works via the platform embedder).
  if (kIsWeb) {
    SemanticsBinding.instance.ensureSemantics();
  }
  // Linux / Windows: close → system tray (process stays for WS / calls).
  // Windows is ready in Dart; rebuild the Windows installer when that tree
  // is updated to this revision.
  if (DesktopTray.isSupported) {
    final primary = await DesktopSingleInstance.ensurePrimary(
      onRaise: () => unawaited(DesktopTray.show()),
    );
    if (!primary) return;
    await DesktopTray.init();
  }
  // Prefer bundled assets/google_fonts/<Family>-<Variant>.ttf (no network).
  // Stale .deb installs still ship hashed cache filenames — fall back to
  // runtime fetch there so Text paint does not throw unhandled exceptions.
  GoogleFonts.config.allowRuntimeFetching = !await _hasApiNamedFontAssets();
  bootstrapWebPlatform();
  // Flutter web enables the browser menu by default (Inspect / Copy / etc.).
  // Must stay disabled or SelectableText right-click opens Chrome's menu.
  if (kIsWeb) {
    await BrowserContextMenu.disableContextMenu();
  }
  if (kDebugMode || bool.fromEnvironment('PRIVET_PERF')) {
    PerfDiagnostics.enable();
  }
  runApp(const PrivetApp());
  // Warm faces after the first frame so the boot spinner stays fluid.
  unawaited(_warmBundledFonts());
}

Future<bool> _hasApiNamedFontAssets() async {
  try {
    await rootBundle.load('assets/google_fonts/DMSans-Regular.ttf');
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> _warmBundledFonts() async {
  // Load each face independently so one missing file cannot take down the
  // whole warm pass on a partial / stale install.
  final styles = <TextStyle>[
    GoogleFonts.syne(),
    GoogleFonts.syne(fontWeight: FontWeight.w600),
    GoogleFonts.syne(fontWeight: FontWeight.w700),
    GoogleFonts.syne(fontWeight: FontWeight.w800),
    GoogleFonts.ibmPlexSans(),
    GoogleFonts.ibmPlexSans(fontWeight: FontWeight.w600),
    GoogleFonts.ibmPlexSans(fontWeight: FontWeight.w700),
    GoogleFonts.ibmPlexSans(fontStyle: FontStyle.italic),
    GoogleFonts.dmSans(),
    GoogleFonts.dmSans(fontWeight: FontWeight.w600),
    GoogleFonts.dmSans(fontWeight: FontWeight.w700),
  ];
  try {
    await Future.wait(
      styles.map(
        (s) => GoogleFonts.pendingFonts([s]).catchError((Object _) {}),
      ),
    ).timeout(const Duration(milliseconds: 2500));
  } catch (_) {
    // Families still resolve on first Text paint when assets (or fetch) work.
  }
}

class PrivetApp extends StatefulWidget {
  const PrivetApp({super.key});

  @override
  State<PrivetApp> createState() => _PrivetAppState();
}

class _PrivetAppState extends State<PrivetApp> with WidgetsBindingObserver {
  final PrivetState _state = PrivetState();
  /// Only session-level fields should rebuild MaterialApp.
  (bool, String?, ThemeMode, int, bool)? _sessionKey;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _state.sessionTick.addListener(_onSession);
    // Also catch first bootstrap via broad notify before sessionTick existed
    // in older call sites — sessionTick is bumped by notifySession/notifyListeners.
    _state.addListener(_onLegacy);
    _state.bootstrap();
    if (kIsWeb) {
      // Re-assert after first frame — some plugins re-enable the browser menu.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        BrowserContextMenu.disableContextMenu();
      });
    }
  }

  void _onSession() {
    final next = (
      _state.booting,
      _state.user?.id,
      _state.themeMode,
      _state.accent.toARGB32(),
      _state.lowResourceMode,
    );
    if (next == _sessionKey) return;
    _sessionKey = next;
    PerfDiagnostics.markBuild('PrivetApp.session');
    setState(() {});
  }

  void _onLegacy() {
    // Ensure first paint after bootstrap even if only notifyListeners ran.
    _onSession();
  }

  @override
  void didChangePlatformBrightness() {
    // Re-derive palette when the OS switches light/dark (themeMode == system).
    if (_state.themeMode == ThemeMode.system) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _state.sessionTick.removeListener(_onSession);
    _state.removeListener(_onLegacy);
    _state.dispose();
    super.dispose();
  }

  Brightness _effectiveBrightness() {
    switch (_state.themeMode) {
      case ThemeMode.light:
        return Brightness.light;
      case ThemeMode.dark:
        return Brightness.dark;
      case ThemeMode.system:
        return WidgetsBinding.instance.platformDispatcher.platformBrightness;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Resolve the active palette before building so every PrivetTheme.* getter
    // returns the right color for this frame.
    PrivetTheme.apply(
      brightness: _effectiveBrightness(),
      accent: _state.accent,
    );
    final low = _state.lowResourceMode;
    return MaterialApp(
      title: 'Privet',
      debugShowCheckedModeBanner: false,
      theme: PrivetTheme.themeData(lowResource: low),
      // Keep Material ink / theme animations from fighting software rasterizers.
      themeAnimationDuration: privetAnim(kThemeAnimationDuration),
      // Collapse *all* Material/implicit motion when Low RAM & CPU is on (and
      // honor OS reduce-motion). Partial privetAnim() coverage was flaky.
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        final disable = low || mq.disableAnimations;
        Widget body = child ?? const SizedBox.shrink();
        if (disable != mq.disableAnimations) {
          body = MediaQuery(
            data: mq.copyWith(disableAnimations: disable),
            child: body,
          );
        }
        return body;
      },
      home: _state.booting
          ? const Scaffold(
              body: Center(
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              ),
            )
          : _state.user == null
          ? LoginScreen(state: _state)
          : MessengerShell(state: _state),
    );
  }
}
