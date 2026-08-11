import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Lightweight inline-text formatting used by Privet messages.
///
/// Messages store formatting as small tags inside the plain body string, so it
/// survives the server unchanged and old clients still display the raw text.
/// Tag set (lower-case):
///
///   [b]bold[/b]                [i]italic[/i]
///   [bg]highlight[/bg]         [bg=#RRGGBB]highlight[/bg]
///   [font=monospace]…[/font]   font family (see [kMessageFonts])
///
/// The composer keeps formatting as [FormatRun]s over the raw text and
/// serializes to this markup on send; message bubbles parse it back into styled
/// [TextSpan]s. Escapes: `\[` renders a literal `[`, `\\` renders `\`.

/// Default highlight color (yellow), used by the plain `[bg]` tag.
const Color kDefaultHighlight = Color(0xFFFFEB3B);

/// Palette offered by the Highlight/Redact pickers.
const List<Color> kHighlightColors = [
  Color(0xFFFFEB3B), // yellow
  Color(0xFF7BD86E), // green
  Color(0xFF4FC3F7), // blue
  Color(0xFFFFB74D), // orange
  Color(0xFFF48FB1), // pink
  Color(0xFFBA68C8), // purple
];

/// Font families offered by the message font picker, in display order.
///
/// The first three are generic CSS families that resolve on every platform
/// without bundling fonts. The rest are bundled Google Fonts (Comic Neue,
/// Tinos, Arimo, Cousine, Ubuntu, Old Standard TT, EB Garamond and the
/// exotic/decorative faces) that ship as
/// `assets/google_fonts/<Family>-<Variant>.ttf`.
const List<String> kMessageFonts = [
  // Generic families — resolve without bundled font files.
  'monospace',
  'serif',
  'cursive',
  // Popular lookalikes of classic system fonts.
  'comic', // Comic Sans MS → Comic Neue
  'times', // Times New Roman → Tinos
  'arial', // Arial → Arimo
  'courier', // Courier New → Cousine
  'ubuntu', // Ubuntu desktop/terminal font
  // Classic book / scientific typography.
  'oldstandard', // Old Standard TT — late-19th-century scientific books
  'garamond', // EB Garamond — Claude Garamont's type for old scholarly books
  // Exotic / decorative faces.
  'cinzel', // ancient Roman inscriptional caps
  'gothic', // Gothic blackletter → UnifrakturMaguntia
  'uncial', // early medieval uncial → Uncial Antiqua
  'pirata', // pirate / renaissance → Pirata One
  'metal', // heavy-metal gothic → Metal Mania
  'medieval', // middle ages → MedievalSharp
];

/// Human labels for [kMessageFonts].
const Map<String, String> kMessageFontLabels = {
  'monospace': 'Monospace',
  'serif': 'Serif',
  'cursive': 'Cursive',
  'comic': 'Comic Sans MS',
  'times': 'Times New Roman',
  'arial': 'Arial',
  'courier': 'Courier New',
  'ubuntu': 'Ubuntu',
  'oldstandard': 'Old Standard TT',
  'garamond': 'Scientific Book',
  'cinzel': 'Ancient Rome',
  'gothic': 'Gothic',
  'uncial': 'Uncial',
  'pirata': 'Pirate',
  'metal': 'Metal',
  'medieval': 'Medieval',
};

/// Builds the [TextStyle] that renders message text in the given [key] font
/// from [kMessageFonts]. Generic keys map straight to `fontFamily`; the
/// popular/exotic keys resolve to the bundled Google Fonts face (loading the
/// bundled `.ttf` asset, never the network).
TextStyle messageFontStyle(String key, TextStyle base) {
  switch (key) {
    case 'comic':
      return GoogleFonts.comicNeue(textStyle: base);
    case 'times':
      return GoogleFonts.tinos(textStyle: base);
    case 'arial':
      return GoogleFonts.arimo(textStyle: base);
    case 'courier':
      return GoogleFonts.cousine(textStyle: base);
    case 'ubuntu':
      return GoogleFonts.ubuntu(textStyle: base);
    case 'oldstandard':
      return GoogleFonts.oldStandardTt(textStyle: base);
    case 'garamond':
      return GoogleFonts.ebGaramond(textStyle: base);
    case 'cinzel':
      return GoogleFonts.cinzel(textStyle: base);
    case 'gothic':
      return GoogleFonts.unifrakturMaguntia(textStyle: base);
    case 'uncial':
      return GoogleFonts.uncialAntiqua(textStyle: base);
    case 'pirata':
      return GoogleFonts.pirataOne(textStyle: base);
    case 'metal':
      return GoogleFonts.metalMania(textStyle: base);
    case 'medieval':
      return GoogleFonts.medievalSharp(textStyle: base);
    default:
      return base.copyWith(fontFamily: key);
  }
}

/// A single formatting attribute bundle (a run's style).
@immutable
class TextFormat {
  const TextFormat({
    this.bold = false,
    this.italic = false,
    this.background,
    this.fontFamily,
  });

  final bool bold;
  final bool italic;
  final Color? background;
  final String? fontFamily;

  static const TextFormat empty = TextFormat();

  bool get isEmpty =>
      !bold && !italic && background == null && fontFamily == null;

  TextFormat merge(TextFormat other) => TextFormat(
        bold: bold || other.bold,
        italic: italic || other.italic,
        background: other.background ?? background,
        fontFamily: other.fontFamily ?? fontFamily,
      );

  /// Applies this format on top of [base].
  TextStyle toTextStyle(TextStyle base) {
    var s = base;
    if (bold) s = s.copyWith(fontWeight: FontWeight.w700);
    if (italic) s = s.copyWith(fontStyle: FontStyle.italic);
    if (background != null) {
      // Light highlighter fills need dark text to stay readable on dark chat.
      s = s.copyWith(
        backgroundColor: background,
        color: const Color(0xFF16181B),
      );
    }
    final family = fontFamily;
    if (family != null && family.isNotEmpty) {
      s = messageFontStyle(family, s);
    }
    return s;
  }

  @override
  bool operator ==(Object other) =>
      other is TextFormat &&
      other.bold == bold &&
      other.italic == italic &&
      other.background == background &&
      other.fontFamily == fontFamily;

  @override
  int get hashCode => Object.hash(bold, italic, background, fontFamily);
}

/// A styled range over plain text (start/end are plain-text offsets).
class FormatRun {
  FormatRun(this.start, this.end, this.format);

  int start;
  int end;
  TextFormat format;

  @override
  String toString() => 'FormatRun($start,$end,$format)';
}

/// A contiguous slice of plain text plus the format to draw it with.
class StyledSegment {
  const StyledSegment(this.text, this.format);

  final String text;
  final TextFormat format;
}

/// Result of parsing a message body: the visible text plus its format runs.
class ParsedMarkup {
  const ParsedMarkup(this.plainText, this.runs);

  final String plainText;
  final List<FormatRun> runs;
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

final RegExp _openTag = RegExp(
  r'\[(b|i|bg|font)(?:=([^\]\[]*))?\]',
  caseSensitive: false,
);
final RegExp _closeTag = RegExp(
  r'\[/(b|i|bg|font)\]',
  caseSensitive: false,
);

class _OpenTag {
  _OpenTag(this.name, this.attr);
  final String name;
  final String? attr;
}

/// Whether a `[/name]` for the tag opening at [start] appears later in [text]
/// (nesting-aware). Unclosed tags render as literal text. [start] must point
/// past the opening tag itself.
bool _hasMatchingClose(String text, int start, String name) {
  var depth = 0;
  var i = start;
  while (i < text.length) {
    final c = text[i];
    if (c == '\\') {
      i += 2;
      continue;
    }
    if (c != '[') {
      i++;
      continue;
    }
    final open = _openTag.matchAsPrefix(text, i);
    final close = _closeTag.matchAsPrefix(text, i);
    if (open != null && open.group(1)!.toLowerCase() == name) {
      depth++;
      i += open.end - open.start;
    } else if (close != null && close.group(1)!.toLowerCase() == name) {
      if (depth == 0) return true;
      depth--;
      i += close.end - close.start;
    } else {
      i++;
    }
  }
  return false;
}

/// Parses [text] (a message body, possibly with markup) into plain text + runs.
ParsedMarkup parseMarkup(String text) {
  final plain = StringBuffer();
  final runs = <FormatRun>[];
  final stack = <_OpenTag>[];

  TextFormat current = TextFormat.empty;
  var runStart = 0;

  void flush() {
    final end = plain.length;
    if (!current.isEmpty && end > runStart) {
      runs.add(FormatRun(runStart, end, current));
    }
    runStart = end;
  }

  TextFormat merged() {
    var f = TextFormat.empty;
    for (final t in stack) {
      f = f.merge(_formatFor(t));
    }
    return f;
  }

  var i = 0;
  while (i < text.length) {
    final c = text[i];
    if (c == '\\') {
      if (i + 1 < text.length) {
        final next = text[i + 1];
        if (next == '[' || next == ']' || next == '\\') {
          plain.write(next);
          i += 2;
          continue;
        }
      }
    } else if (c == '[') {
      final open = _openTag.matchAsPrefix(text, i);
      final close = _closeTag.matchAsPrefix(text, i);
      if (open != null) {
        final name = open.group(1)!.toLowerCase();
        if (_hasMatchingClose(text, i + open.end - open.start, name)) {
          stack.add(_OpenTag(name, open.group(2)));
          flush();
          current = merged();
          i += open.end - open.start;
          continue;
        }
      } else if (close != null) {
        final name = close.group(1)!.toLowerCase();
        if (stack.isNotEmpty && stack.last.name == name) {
          stack.removeLast();
          flush();
          current = merged();
          i += close.end - close.start;
          continue;
        }
      }
    }
    plain.write(c);
    i++;
  }
  flush();
  return ParsedMarkup(plain.toString(), _normalize(runs));
}

TextFormat _formatFor(_OpenTag tag) {
  switch (tag.name) {
    case 'b':
      return const TextFormat(bold: true);
    case 'i':
      return const TextFormat(italic: true);
    case 'bg':
      final attr = tag.attr?.trim().toLowerCase();
      final color = attr != null && attr.isNotEmpty
          ? _parseHexColor(attr)
          : kDefaultHighlight;
      return TextFormat(background: color);
    case 'font':
      return TextFormat(fontFamily: tag.attr?.trim().toLowerCase());
  }
  return TextFormat.empty;
}

Color? _parseHexColor(String hex) {
  var h = hex.replaceFirst('#', '');
  if (h.length == 3) {
    h = h.split('').map((e) => '$e$e').join();
  }
  if (h.length != 6) return null;
  final v = int.tryParse(h, radix: 16);
  if (v == null) return null;
  return Color(0xFF000000 | v);
}

/// Splits plain text into styled segments (run boundaries as cut points).
List<StyledSegment> styledSegments(ParsedMarkup parsed) {
  if (parsed.runs.isEmpty) {
    return [StyledSegment(parsed.plainText, TextFormat.empty)];
  }
  final points = <int>{0, parsed.plainText.length};
  for (final r in parsed.runs) {
    points.add(r.start.clamp(0, parsed.plainText.length));
    points.add(r.end.clamp(0, parsed.plainText.length));
  }
  final pts = points.toList()..sort();
  final out = <StyledSegment>[];
  for (var i = 0; i < pts.length - 1; i++) {
    final a = pts[i];
    final b = pts[i + 1];
    if (b <= a) continue;
    out.add(
      StyledSegment(
        parsed.plainText.substring(a, b),
        _formatCovering(parsed.runs, a, b),
      ),
    );
  }
  return out;
}

TextFormat _formatCovering(List<FormatRun> runs, int a, int b) {
  for (final r in runs) {
    if (r.start <= a && r.end >= b) return r.format;
  }
  return TextFormat.empty;
}

// ---------------------------------------------------------------------------
// Serialization
// ---------------------------------------------------------------------------

final RegExp _tagStart = RegExp(
  r'^\[(?:b|i|bg|font)(?:=[^\]\[]*)?\]',
  caseSensitive: false,
);

/// Escapes text so literal `[tag]` / backslashes survive a parse round-trip.
/// Only exact tag starts are escaped, so ordinary brackets stay untouched.
String escapeMarkupText(String s) {
  final out = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final c = s[i];
    if (c == '\\') {
      final next = i + 1 < s.length ? s[i + 1] : '';
      if (next == '[' || next == '\\') {
        out.write(r'\\');
        i += 2;
        continue;
      }
      out.write(c);
      i++;
    } else if (c == '[') {
      if (_tagStart.hasMatch(s.substring(i))) {
        out.write(r'\[');
      } else {
        out.write(c);
      }
      i++;
    } else {
      out.write(c);
      i++;
    }
  }
  return out.toString();
}

String _openFor(String name, TextFormat f) {
  switch (name) {
    case 'bg':
      final hex = f.background == null
          ? null
          : '#${(f.background!.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
      return hex == null || f.background == kDefaultHighlight
          ? '[bg]'
          : '[bg=$hex]';
    case 'font':
      return '[font=${f.fontFamily}]';
    default:
      return '[$name]';
  }
}

const List<String> _tagOrder = ['b', 'i', 'bg', 'font'];

/// Serializes [plain] + [runs] into the stored markup form.
String serializeMarkup(String plain, List<FormatRun> runs) {
  final normalized = _normalize(runs);
  if (normalized.isEmpty) return escapeMarkupText(plain);

  final points = <int>{0, plain.length};
  for (final r in normalized) {
    points.add(r.start.clamp(0, plain.length));
    points.add(r.end.clamp(0, plain.length));
  }
  final pts = points.toList()..sort();

  final out = StringBuffer();
  TextFormat prev = TextFormat.empty;
  for (var i = 0; i < pts.length - 1; i++) {
    final a = pts[i];
    final b = pts[i + 1];
    if (b <= a) continue;
    final cur = _formatCovering(normalized, a, b);

    if (cur != prev) {
      // Close attributes that are going away, then open new ones.
      for (final name in _tagOrder.reversed) {
        if (_hasAttr(prev, name) && !_hasAttr(cur, name)) {
          out.write('[/$name]');
        }
      }
      for (final name in _tagOrder) {
        if (!_hasAttr(prev, name) && _hasAttr(cur, name)) {
          out.write(_openFor(name, cur));
        }
      }
    }
    out.write(escapeMarkupText(plain.substring(a, b)));
    prev = cur;
  }
  // Close any remaining open tags.
  for (final name in _tagOrder.reversed) {
    if (_hasAttr(prev, name)) out.write('[/$name]');
  }
  return out.toString();
}

bool _hasAttr(TextFormat f, String name) {
  switch (name) {
    case 'b':
      return f.bold;
    case 'i':
      return f.italic;
    case 'bg':
      return f.background != null;
    case 'font':
      return f.fontFamily != null;
  }
  return false;
}

/// Strips markup, returning only the visible text (for reply/edit previews).
String markupToPlain(String text) => parseMarkup(text).plainText;

// ---------------------------------------------------------------------------
// Selection operations (shared by composer + sent-message redaction)
// ---------------------------------------------------------------------------

/// Merged format covering [start,end). Runs are in [plain]-coordinates.
TextFormat selectionFormat(List<FormatRun> runs, int start, int end) {
  var f = TextFormat.empty;
  for (final r in runs) {
    if (r.start < end && r.end > start) f = f.merge(r.format);
  }
  return f;
}

/// True when every character of [start,end) is covered by a run satisfying
/// [has] (uncovered gaps count as "no").
bool selectionWhollyHasAttribute(
  List<FormatRun> runs,
  int start,
  int end,
  bool Function(TextFormat) has,
) {
  if (start >= end) return false;
  var pos = start;
  for (final r in runs) {
    if (r.end <= pos) continue;
    if (r.start > pos) return false; // uncovered gap
    if (!has(r.format)) return false;
    pos = r.end;
    if (pos >= end) break;
  }
  return pos >= end;
}

/// Builds the format to apply over [start,end) when toggling the requested
/// attributes. Attributes already present across the *whole* selection are
/// removed; otherwise they are added. A `background` of [Colors.transparent]
/// and an empty [fontFamily] explicitly remove those attributes.
TextFormat toggledFormatOverSelection(
  List<FormatRun> runs,
  int start,
  int end, {
  bool? bold,
  bool? italic,
  Color? background,
  String? fontFamily,
}) {
  final cur = selectionFormat(runs, start, end);
  return TextFormat(
    bold: bold == null
        ? cur.bold
        : selectionWhollyHasAttribute(runs, start, end, (f) => f.bold)
            ? false
            : true,
    italic: italic == null
        ? cur.italic
        : selectionWhollyHasAttribute(runs, start, end, (f) => f.italic)
            ? false
            : true,
    background: background == null
        ? cur.background
        : background == Colors.transparent
            ? null
            : selectionWhollyHasAttribute(
                runs,
                start,
                end,
                (f) => f.background == background,
              )
                ? null
                : background,
    fontFamily: fontFamily == null
        ? cur.fontFamily
        : fontFamily.isEmpty
            ? null
            : selectionWhollyHasAttribute(
                runs,
                start,
                end,
                (f) => f.fontFamily == fontFamily,
              )
                ? null
                : fontFamily,
  );
}

/// Overwrites the format of everything inside [start,end) with [desired],
/// keeping runs outside the selection untouched. Non-empty runs only.
List<FormatRun> applyFormatToSelection(
  List<FormatRun> runs,
  int start,
  int end,
  TextFormat desired,
) {
  final out = <FormatRun>[];
  for (final r in runs) {
    if (r.end <= start || r.start >= end) {
      out.add(r);
      continue;
    }
    if (r.start < start) out.add(FormatRun(r.start, start, r.format));
    if (r.end > end) out.add(FormatRun(end, r.end, r.format));
  }
  if (!desired.isEmpty) {
    final points = <int>{start, end};
    for (final r in runs) {
      if (r.start < end && r.end > start) {
        points.add(r.start.clamp(start, end));
        points.add(r.end.clamp(start, end));
      }
    }
    final pts = points.toList()..sort();
    for (var i = 0; i < pts.length - 1; i++) {
      final a = pts[i];
      final b = pts[i + 1];
      if (b > a) out.add(FormatRun(a, b, desired));
    }
  }
  return _normalize(out);
}

/// Sorts runs and merges adjacent runs with identical formats.
List<FormatRun> _normalize(List<FormatRun> runs) {
  if (runs.length < 2) return runs;
  final sorted = [...runs]
    ..sort((a, b) {
      final byStart = a.start.compareTo(b.start);
      if (byStart != 0) return byStart;
      return a.end.compareTo(b.end);
    });
  final out = <FormatRun>[sorted.first];
  for (final r in sorted.skip(1)) {
    final last = out.last;
    if (r.start == last.end && r.format == last.format) {
      last.end = r.end;
    } else {
      out.add(r);
    }
  }
  return out;
}
