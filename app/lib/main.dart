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

class _PrivetAppState extends State<PrivetApp> {
  final PrivetState _state = PrivetState();

  @override
  void initState() {
    super.initState();
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
  void dispose() {
    _state.removeListener(_onChange);
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Privet',
      debugShowCheckedModeBanner: false,
      theme: PrivetTheme.dark(),
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
