import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import 'screens/login_screen.dart';
import 'screens/messenger_shell.dart';
import 'state.dart';
import 'theme.dart';
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
    return MaterialApp(
      title: 'Privet',
      debugShowCheckedModeBanner: false,
      theme: PrivetTheme.themeData(),
      home: _state.booting
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : _state.user == null
          ? LoginScreen(state: _state)
          : MessengerShell(state: _state),
    );
  }
}
