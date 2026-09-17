import 'dart:async' show scheduleMicrotask;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'util/low_resource.dart';
import 'util/web_select_cursor.dart';
import 'widgets/accent_borders.dart';
import 'widgets/privet_splash.dart';

/// How an accent paints chrome (borders / type), beyond its seed hue.
enum AccentStyle {
  /// Normal Privet: graphite UI + colored signal.
  solid,

  /// Solid yellow frames + yellow type.
  yellow,

  /// Diagonal black/yellow caution-tape frames + yellow type.
  tape,

  /// Soft larva-gold frames with short fluff + larva type.
  larva,

  /// Terminal green hacker look.
  hacker,
}

/// A named accent the user can pick from the Appearance settings. [seed] is a
/// hue reference; the actual accent used per theme mode is derived from it so
/// it stays bright on dark surfaces and deep enough to read on light ones.
class AccentOption {
  const AccentOption(this.id, this.label, this.seed, {this.style = AccentStyle.solid});
  final String id;
  final String label;
  final Color seed;
  final AccentStyle style;
}

/// Immutable set of resolved colors for one brightness + accent combination.
/// Every color the app draws comes from here so themes are fully swappable.
@immutable
class PrivetPalette {
  const PrivetPalette({
    required this.brightness,
    required this.ink,
    required this.panel,
    required this.panelElevated,
    required this.line,
    required this.mist,
    required this.paper,
    required this.signal,
    required this.signalDim,
    required this.mine,
    required this.danger,
    required this.onAccent,
  });

  final Brightness brightness;

  /// App background / darkest (or in light mode, lightest) surface.
  final Color ink;

  /// Primary surface (cards, sheets, bars).
  final Color panel;

  /// Elevated surface (inputs, chips, incoming bubbles).
  final Color panelElevated;

  /// Hairline borders / dividers.
  final Color line;

  /// Secondary / muted text.
  final Color mist;

  /// Primary text.
  final Color paper;

  /// Accent fill (buttons, active icons, links). Bright on dark, deep on light.
  final Color signal;

  /// Dimmed accent.
  final Color signalDim;

  /// Own-message bubble fill.
  final Color mine;

  /// Error / destructive.
  final Color danger;

  /// Text / icon color that sits on top of [signal] fills.
  final Color onAccent;
}

/// Privet visual language: ink graphite + a user-chosen signal accent.
/// Colors are runtime getters backed by [_active] so the whole app re-themes
/// when [apply] runs (driven by the root [MaterialApp] each rebuild).
class PrivetTheme {
  PrivetTheme._();

  /// Default accent seed — the original signal lime.
  static const Color defaultAccent = Color(0xFFB6F24A);

  /// Accent choices surfaced in the color picker.
  static const List<AccentOption> accentOptions = [
    AccentOption('lime', 'Signal', Color(0xFFB6F24A)),
    AccentOption('emerald', 'Emerald', Color(0xFF10B981)),
    AccentOption('cyan', 'Cyan', Color(0xFF06B6D4)),
    AccentOption('azure', 'Azure', Color(0xFF3B82F6)),
    AccentOption('violet', 'Violet', Color(0xFF8B5CF6)),
    AccentOption('magenta', 'Magenta', Color(0xFFD946A6)),
    AccentOption('rose', 'Rose', Color(0xFFF43F5E)),
    AccentOption('amber', 'Amber', Color(0xFFF59E0B)),
    AccentOption('yellow', 'Yellow', Color(0xFFF0D000), style: AccentStyle.yellow),
    AccentOption('tape', 'Tape', Color(0xFFF0D001), style: AccentStyle.tape),
    AccentOption('larva', 'Larva', Color(0xFFE6D392), style: AccentStyle.larva),
    AccentOption('hacker', 'Hacker', Color(0xFF39FF14), style: AccentStyle.hacker),
  ];

  static AccentOption optionFor({String? id, Color? seed}) {
    if (id != null) {
      for (final o in accentOptions) {
        if (o.id == id) return o;
      }
    }
    if (seed != null) {
      final argb = seed.toARGB32();
      for (final o in accentOptions) {
        if (o.seed.toARGB32() == argb) return o;
      }
    }
    return accentOptions.first;
  }

  /// The palette the app is currently drawing with.
  static PrivetPalette _active = _buildDark(defaultAccent);
  static PrivetPalette get palette => _active;

  static AccentStyle _style = AccentStyle.solid;
  static AccentStyle get accentStyle => _style;
  static bool get isSpecialAccent => _style != AccentStyle.solid;

  /// Bumped on every successful [apply]. Accent chrome listens so splitters /
  /// frames never stay painted in the previous accent until a mouse move.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Display / username face for the active accent (Syne → Cousine for hacker).
  static TextStyle titleStyle({
    double? fontSize,
    FontWeight? fontWeight,
    Color? color,
    double? height,
    TextOverflow? overflow,
  }) {
    final base = TextStyle(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
      height: height,
      overflow: overflow,
    );
    return switch (_style) {
      AccentStyle.hacker => GoogleFonts.cousine(textStyle: base),
      AccentStyle.tape => GoogleFonts.ebGaramond(textStyle: base),
      _ => GoogleFonts.syne(textStyle: base),
    };
  }

  /// Default message-font key forced by accent, or null to keep the user pick.
  static String? get accentMessageFontFamily => switch (_style) {
        AccentStyle.hacker => 'courier',
        AccentStyle.tape => 'garamond',
        _ => null,
      };

  /// Cached [ThemeData] keyed by brightness + accent + style + low-resource.
  static ThemeData? _cachedTheme;
  static Brightness? _cachedBrightness;
  static int? _cachedAccent;
  static AccentStyle? _cachedStyle;
  static bool? _cachedLowResource;

  // Runtime color getters (kept as the historical names used across the app).
  static Color get ink => _active.ink;
  static Color get panel => _active.panel;
  static Color get panelElevated => _active.panelElevated;
  static Color get line => _active.line;
  static Color get mist => _active.mist;
  static Color get paper => _active.paper;
  static Color get signal => _active.signal;
  static Color get signalDim => _active.signalDim;
  static Color get mine => _active.mine;
  static Color get danger => _active.danger;
  static Color get onAccent => _active.onAccent;

  static bool get isLight => _active.brightness == Brightness.light;

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

  /// Recompute the active palette. Call this before building [MaterialApp].
  static void apply({
    required Brightness brightness,
    required Color accent,
    AccentStyle style = AccentStyle.solid,
  }) {
    final accentKey = accent.toARGB32();
    // Called on every root rebuild — bail before allocating a fresh
    // PrivetPalette / mutating cursors when nothing actually changed.
    if (_cachedBrightness == brightness &&
        _cachedAccent == accentKey &&
        _cachedStyle == style) {
      return;
    }
    _style = style;
    _active = switch (style) {
      AccentStyle.hacker => _buildHacker(brightness),
      AccentStyle.yellow || AccentStyle.tape => brightness == Brightness.light
          ? _buildTintedLight(accent, paperAsSignal: true)
          : _buildTintedDark(accent, paperAsSignal: true),
      AccentStyle.larva => brightness == Brightness.light
          ? _buildTintedLight(accent, paperAsSignal: true)
          : _buildTintedDark(accent, paperAsSignal: true),
      AccentStyle.solid => brightness == Brightness.light
          ? _buildLight(accent)
          : _buildDark(accent),
    };
    _cachedTheme = null;
    _cachedBrightness = brightness;
    _cachedAccent = accentKey;
    _cachedStyle = style;
    _cachedLowResource = null;
    // Keep web painted I-beam / move cursors on the live accent.
    syncPrivetAccentCursors(_active.signal);
    // Never notify [revision] synchronously — [apply] runs from MaterialApp
    // build, and a sync ValueNotifier bump would setState during build.
    _scheduleRevisionBump();
  }

  static bool _revisionScheduled = false;
  static void _scheduleRevisionBump() {
    if (_revisionScheduled) return;
    _revisionScheduled = true;
    scheduleMicrotask(() {
      _revisionScheduled = false;
      revision.value++;
    });
  }

  /// Immediate chrome/font refresh (accent picker). Safe outside build.
  static void bumpRevision() {
    _revisionScheduled = false;
    revision.value++;
  }

  static Color _tone(Color seed, double lightness, {double satScale = 1.0}) {
    final hsl = HSLColor.fromColor(seed);
    return hsl
        .withLightness(lightness.clamp(0.0, 1.0))
        .withSaturation((hsl.saturation * satScale).clamp(0.0, 1.0))
        .toColor();
  }

  static PrivetPalette _buildDark(Color accent) {
    return PrivetPalette(
      brightness: Brightness.dark,
      ink: const Color(0xFF0E1114),
      panel: const Color(0xFF161B20),
      panelElevated: const Color(0xFF1C2329),
      line: const Color(0xFF2A333C),
      mist: const Color(0xFF9AA7B2),
      paper: const Color(0xFFE8EEF2),
      // Bright accent that reads on dark surfaces (fill and text).
      signal: _tone(accent, 0.62),
      signalDim: _tone(accent, 0.42, satScale: 0.9),
      mine: const Color(0xFF254355),
      danger: const Color(0xFFFF6B5E),
      onAccent: const Color(0xFF0E1114),
    );
  }

  static PrivetPalette _buildLight(Color accent) {
    return PrivetPalette(
      brightness: Brightness.light,
      ink: const Color(0xFFEDF1F5),
      panel: const Color(0xFFFFFFFF),
      panelElevated: const Color(0xFFF1F5F8),
      line: const Color(0xFFDCE3E9),
      mist: const Color(0xFF5C6A75),
      paper: const Color(0xFF141B21),
      // Deep accent that reads on light surfaces (fill and text).
      signal: _tone(accent, 0.36, satScale: 1.0),
      signalDim: _tone(accent, 0.48, satScale: 0.85),
      mine: const Color(0xFFD8E7F1),
      danger: const Color(0xFFC7392F),
      onAccent: const Color(0xFFF7FAFC),
    );
  }

  /// Yellow / tape / larva: keep graphite surfaces, paint type with the accent.
  static PrivetPalette _buildTintedDark(
    Color accent, {
    required bool paperAsSignal,
  }) {
    final signal = _tone(accent, 0.62);
    return PrivetPalette(
      brightness: Brightness.dark,
      ink: const Color(0xFF0E1114),
      panel: const Color(0xFF161B20),
      panelElevated: const Color(0xFF1C2329),
      line: signal.withValues(alpha: 0.35),
      mist: signal.withValues(alpha: 0.72),
      paper: paperAsSignal ? signal : const Color(0xFFE8EEF2),
      signal: signal,
      signalDim: _tone(accent, 0.42, satScale: 0.9),
      mine: const Color(0xFF254355),
      danger: const Color(0xFFFF6B5E),
      onAccent: const Color(0xFF0E1114),
    );
  }

  static PrivetPalette _buildTintedLight(
    Color accent, {
    required bool paperAsSignal,
  }) {
    final signal = _tone(accent, 0.36, satScale: 1.0);
    return PrivetPalette(
      brightness: Brightness.light,
      ink: const Color(0xFFEDF1F5),
      panel: const Color(0xFFFFFFFF),
      panelElevated: const Color(0xFFF1F5F8),
      line: signal.withValues(alpha: 0.35),
      mist: signal.withValues(alpha: 0.75),
      paper: paperAsSignal ? signal : const Color(0xFF141B21),
      signal: signal,
      signalDim: _tone(accent, 0.48, satScale: 0.85),
      mine: const Color(0xFFD8E7F1),
      danger: const Color(0xFFC7392F),
      onAccent: const Color(0xFFF7FAFC),
    );
  }

  static PrivetPalette _buildHacker(Brightness brightness) {
    const neon = Color(0xFF39FF14);
    final dark = brightness == Brightness.dark;
    return PrivetPalette(
      brightness: brightness,
      ink: dark ? const Color(0xFF020804) : const Color(0xFF07140A),
      panel: dark ? const Color(0xFF06140A) : const Color(0xFF0C1F12),
      panelElevated: dark ? const Color(0xFF0A1C10) : const Color(0xFF122818),
      line: neon.withValues(alpha: 0.35),
      mist: neon.withValues(alpha: 0.7),
      paper: neon,
      signal: neon,
      signalDim: const Color(0xFF2BC410),
      mine: const Color(0xFF0D2414),
      danger: const Color(0xFFFF5555),
      onAccent: const Color(0xFF020804),
    );
  }

  /// Builds the [ThemeData] for the currently active palette.
  static ThemeData themeData({bool? lowResource}) {
    final low = lowResource ?? privetLowResource;
    final cached = _cachedTheme;
    if (cached != null && _cachedLowResource == low) return cached;
    final p = _active;
    final style = _style;
    final radius = style == AccentStyle.hacker ? 4.0 : 14.0;
    final base = ThemeData(
      useMaterial3: true,
      brightness: p.brightness,
      scaffoldBackgroundColor: p.ink,
      // Privet's wave splash: a soft accent ring + glow that expands with an
      // ease-out curve instead of the stock ~225 ms solid-disk pop. Low-RAM /
      // software-rasterized boxes keep the no-splash mode.
      splashFactory: low ? NoSplash.splashFactory : PrivetSplash.splashFactory,
      splashColor: p.signal.withValues(alpha: 0.42),
      highlightColor: p.signal.withValues(alpha: 0.10),
      hoverColor: p.signal.withValues(alpha: 0.08),
      focusColor: p.signal.withValues(alpha: 0.10),
      colorScheme: ColorScheme(
        brightness: p.brightness,
        primary: p.signal,
        onPrimary: p.onAccent,
        secondary: p.signalDim,
        onSecondary: p.onAccent,
        surface: p.panel,
        onSurface: p.paper,
        error: p.danger,
        onError: p.onAccent,
      ),
    );

    final TextTheme display;
    final TextTheme body;
    if (style == AccentStyle.hacker) {
      display = GoogleFonts.cousineTextTheme(base.textTheme).apply(
        bodyColor: p.paper,
        displayColor: p.paper,
      );
      body = GoogleFonts.cousineTextTheme(base.textTheme).apply(
        bodyColor: p.paper,
        displayColor: p.paper,
      );
    } else if (style == AccentStyle.tape) {
      // Nature / bee book face (bundled EB Garamond).
      display = GoogleFonts.ebGaramondTextTheme(base.textTheme).apply(
        bodyColor: p.paper,
        displayColor: p.paper,
      );
      body = GoogleFonts.ebGaramondTextTheme(base.textTheme).apply(
        bodyColor: p.paper,
        displayColor: p.paper,
      );
    } else {
      display = GoogleFonts.syneTextTheme(base.textTheme).apply(
        bodyColor: p.paper,
        displayColor: p.paper,
      );
      body = GoogleFonts.ibmPlexSansTextTheme(base.textTheme).apply(
        bodyColor: p.paper,
        displayColor: p.paper,
      );
    }

    final OutlineInputBorder idleBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(radius),
      borderSide: BorderSide(color: p.line),
    );
    final OutlineInputBorder focusedBorder = switch (style) {
      AccentStyle.tape => TapeOutlineBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
      // Plain gold ring — long fluff + wind is painted by AccentChromeFrame.
      AccentStyle.larva => OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: const BorderSide(color: Color(0xFFE8D89A), width: 1.4),
        ),
      AccentStyle.yellow => OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: p.signal, width: 2),
        ),
      AccentStyle.hacker => OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: p.signal, width: 1.5),
        ),
      AccentStyle.solid => OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: p.signal, width: 1.4),
        ),
    };

    final theme = base.copyWith(
      textTheme: body.copyWith(
        displayLarge: display.displayLarge?.copyWith(fontWeight: FontWeight.w700),
        displayMedium: display.displayMedium?.copyWith(fontWeight: FontWeight.w700),
        headlineLarge: display.headlineLarge?.copyWith(fontWeight: FontWeight.w700),
        headlineMedium: display.headlineMedium?.copyWith(fontWeight: FontWeight.w600),
        headlineSmall: display.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
        titleLarge: display.titleLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: p.ink,
        foregroundColor: p.paper,
        elevation: 0,
        titleTextStyle: (style == AccentStyle.hacker
                ? GoogleFonts.cousine
                : style == AccentStyle.tape
                    ? GoogleFonts.ebGaramond
                    : GoogleFonts.syne)(
          color: p.paper,
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.panelElevated,
        hintStyle: TextStyle(color: p.mist),
        border: idleBorder,
        enabledBorder: idleBorder,
        focusedBorder: focusedBorder,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: p.signal,
          foregroundColor: p.onAccent,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
          textStyle: (style == AccentStyle.hacker
                  ? GoogleFonts.cousine
                  : style == AccentStyle.tape
                      ? GoogleFonts.ebGaramond
                      : GoogleFonts.syne)(fontWeight: FontWeight.w700, fontSize: 15),
        ).copyWith(
          mouseCursor: _buttonMouseCursor,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(mouseCursor: _buttonMouseCursor),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          mouseCursor: _buttonMouseCursor,
          foregroundColor: WidgetStatePropertyAll(p.paper),
          side: style == AccentStyle.solid
              ? WidgetStatePropertyAll(BorderSide(color: p.line))
              : const WidgetStatePropertyAll(BorderSide.none),
          shape: WidgetStatePropertyAll(
            style == AccentStyle.solid
                ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius))
                : AccentOutlinedBorder(style: style, radius: radius),
          ),
        ),
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
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: p.signal,
        selectionColor: p.signal.withValues(alpha: 0.45),
        selectionHandleColor: p.signal,
      ),
      listTileTheme: ListTileThemeData(
        mouseCursor: WidgetStateMouseCursor.clickable,
      ),
      dividerColor: p.line,
      pageTransitionsTheme: privetPageTransitionsTheme(lowResource: low),
      dialogTheme: DialogThemeData(
        elevation: privetElevation(6),
        shadowColor: Colors.black54,
      ),
    );
    _cachedTheme = theme;
    _cachedLowResource = low;
    return theme;
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
