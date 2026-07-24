import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import 'screens/login_screen.dart';
import 'screens/messenger_shell.dart';
import 'state.dart';
import 'theme.dart';
import 'util/web_bootstrap.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Web: expose semantics so assistive tech (and attach overlays) work reliably.
  SemanticsBinding.instance.ensureSemantics();
  bootstrapWebPlatform();
  // Flutter web enables the browser menu by default (Inspect / Copy / etc.).
  // Must stay disabled or SelectableText right-click opens Chrome's menu.
  if (kIsWeb) {
    await BrowserContextMenu.disableContextMenu();
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _state.addListener(_onChange);
    _state.bootstrap();
    if (kIsWeb) {
      // Re-assert after first frame — some plugins re-enable the browser menu.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        BrowserContextMenu.disableContextMenu();
      });
    }
  }

  void _onChange() => setState(() {});

  @override
  void didChangePlatformBrightness() {
    // Re-derive palette when the OS switches light/dark (themeMode == system).
    if (_state.themeMode == ThemeMode.system) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _state.removeListener(_onChange);
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
          ? const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            )
          : _state.user == null
              ? LoginScreen(state: _state)
              : MessengerShell(state: _state),
    );
  }
}
