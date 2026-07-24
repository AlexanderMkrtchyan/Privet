import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Privet visual language: ink graphite + signal green. No purple gradients.
class PrivetTheme {
  static const ink = Color(0xFF0E1114);
  static const panel = Color(0xFF161B20);
  static const panelElevated = Color(0xFF1C2329);
  static const line = Color(0xFF2A333C);
  static const mist = Color(0xFF9AA7B2);
  static const paper = Color(0xFFE8EEF2);
  static const signal = Color(0xFFB6F24A);
  static const signalDim = Color(0xFF7FA832);
  /// Own-message fill: clear blue-slate (Teams/Telegram-style), distinct from
  /// others' graphite. Signal green stays for replies/links only.
  static const mine = Color(0xFF254355);
  static const danger = Color(0xFFFF6B5E);

  /// Desktop split-pane layout (inbox + chat side by side).
  static const wideBreakpoint = 900.0;

  static bool isWide(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= wideBreakpoint;

  static bool isCompact(BuildContext context) => !isWide(context);

  static EdgeInsets screenPadding(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    if (w < 400) return const EdgeInsets.all(16);
    if (w < wideBreakpoint) return const EdgeInsets.all(20);
    return const EdgeInsets.all(28);
  }

  static ThemeData dark() {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: ink,
      colorScheme: const ColorScheme.dark(
        surface: panel,
        primary: signal,
        onPrimary: ink,
        secondary: signalDim,
        onSurface: paper,
        error: danger,
      ),
    );

    final display = GoogleFonts.syneTextTheme(base.textTheme).apply(
      bodyColor: paper,
      displayColor: paper,
    );
    final body = GoogleFonts.ibmPlexSansTextTheme(base.textTheme).apply(
      bodyColor: paper,
      displayColor: paper,
    );

    return base.copyWith(
      textTheme: body.copyWith(
        displayLarge: display.displayLarge?.copyWith(fontWeight: FontWeight.w700),
        displayMedium: display.displayMedium?.copyWith(fontWeight: FontWeight.w700),
        headlineLarge: display.headlineLarge?.copyWith(fontWeight: FontWeight.w700),
        headlineMedium: display.headlineMedium?.copyWith(fontWeight: FontWeight.w600),
        headlineSmall: display.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
        titleLarge: display.titleLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: ink,
        foregroundColor: paper,
        elevation: 0,
        titleTextStyle: GoogleFonts.syne(
          color: paper,
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: panelElevated,
        hintStyle: const TextStyle(color: mist),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: signal, width: 1.4),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: signal,
          foregroundColor: ink,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: GoogleFonts.syne(fontWeight: FontWeight.w700, fontSize: 15),
        ).copyWith(
          mouseCursor: _buttonMouseCursor,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(mouseCursor: _buttonMouseCursor),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(mouseCursor: _buttonMouseCursor),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(mouseCursor: _buttonMouseCursor),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          mouseCursor: _buttonMouseCursor,
          minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
      dividerColor: line,
    );
  }

  /// Pointer on enabled buttons; default arrow when disabled.
  static final WidgetStateProperty<MouseCursor?> _buttonMouseCursor =
      WidgetStateProperty.resolveWith((states) {
    if (states.contains(WidgetState.disabled)) {
      return SystemMouseCursors.basic;
    }
    return SystemMouseCursors.click;
  });
}
