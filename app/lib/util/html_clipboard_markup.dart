import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'rich_text_markup.dart';

/// Converts clipboard HTML (webpages, Cursor, Word, etc.) into Privet
/// [ParsedMarkup]: plain text plus bold / italic / color / font runs.
///
/// Structure approximations:
/// - `<ul>` / `<ol>` → indented bullet / numbered lines (2 spaces per level)
/// - `<table>` → tab-separated cells, one row per line (TSV)
/// - `<br>` / block tags → newlines
/// - Literal `\t`, `&nbsp;`, and `white-space: pre*` are preserved
/// - CSS `margin-left` / `padding-left` / `text-indent` → leading tabs
ParsedMarkup htmlToMarkup(String html) {
  final trimmed = html.trim();
  if (trimmed.isEmpty) {
    return const ParsedMarkup('', []);
  }
  final fragment = _extractHtmlFragment(trimmed);
  final doc = html_parser.parse(fragment);
  final body = doc.body ?? doc.documentElement;
  if (body == null) {
    return const ParsedMarkup('', []);
  }
  final out = _HtmlWalk();
  out.visitChildren(body);
  out.trimTrailingNewlines();
  return ParsedMarkup(out.plain.toString(), _normalizeRuns(out.runs));
}

/// True when [html] carries more than bare unstyled text (worth preferring
/// over `text/plain`).
bool htmlClipboardLooksRich(String html) {
  final lower = html.toLowerCase();
  if (lower.contains('<b') ||
      lower.contains('<strong') ||
      lower.contains('<i') ||
      lower.contains('<em') ||
      lower.contains('<ul') ||
      lower.contains('<ol') ||
      lower.contains('<li') ||
      lower.contains('<font') ||
      lower.contains('<h1') ||
      lower.contains('<h2') ||
      lower.contains('<h3') ||
      lower.contains('<pre') ||
      lower.contains('<code') ||
      lower.contains('<table') ||
      lower.contains('<td') ||
      lower.contains('<th')) {
    return true;
  }
  if (RegExp(r'color\s*[:=]', caseSensitive: false).hasMatch(html)) {
    return true;
  }
  if (RegExp(r'font-weight\s*:\s*(bold|[6-9]00)', caseSensitive: false)
      .hasMatch(html)) {
    return true;
  }
  if (RegExp(r'font-style\s*:\s*italic', caseSensitive: false).hasMatch(html)) {
    return true;
  }
  if (RegExp(r'(margin|padding)-left\s*:', caseSensitive: false)
      .hasMatch(html)) {
    return true;
  }
  return false;
}

/// Chrome (notably Google pages) sometimes puts the same selection in
/// `text/html` twice. [plain] is the single `text/plain` copy.
bool htmlSelectionWasDoubled(String plain, String fromHtml) {
  final p = _normalizeClipboardNewlines(plain).trim();
  final h = _normalizeClipboardNewlines(fromHtml).trim();
  if (p.isEmpty || h.length < p.length * 2) return false;
  return h == '$p$p' || h == '$p\n$p' || h == '$p $p';
}

String _normalizeClipboardNewlines(String value) =>
    value.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

/// Whether [plain] from the OS looks structurally richer than [fromHtml]
/// (e.g. browser TSV for a table). Used to fall back when HTML conversion
/// mangled tabs / columns.
bool plainTextLooksMoreStructured(String plain, String fromHtml) {
  final p = _normalizeClipboardNewlines(plain);
  final h = _normalizeClipboardNewlines(fromHtml);
  if (p.trim().isEmpty) return false;
  final plainTabs = '\t'.allMatches(p).length;
  final htmlTabs = '\t'.allMatches(h).length;
  if (plainTabs >= 2 && plainTabs > htmlTabs) return true;
  // Same visible words but plain keeps more line structure.
  final plainLines =
      p.split('\n').where((l) => l.trim().isNotEmpty).length;
  final htmlLines =
      h.split('\n').where((l) => l.trim().isNotEmpty).length;
  if (plainTabs > 0 && plainLines > htmlLines + 1) return true;
  return false;
}

String _extractHtmlFragment(String raw) {
  final startFrag = RegExp(r'StartFragment:(\d+)', caseSensitive: false)
      .firstMatch(raw);
  final endFrag =
      RegExp(r'EndFragment:(\d+)', caseSensitive: false).firstMatch(raw);
  if (startFrag != null && endFrag != null) {
    final start = int.tryParse(startFrag.group(1)!);
    final end = int.tryParse(endFrag.group(1)!);
    if (start != null &&
        end != null &&
        start < end &&
        end <= raw.length &&
        start >= 0) {
      final frag = raw.substring(start, end);
      if (frag.contains('<') || frag.trim().isNotEmpty) return frag;
    }
  }
  final bodyMatch = RegExp(
    r'<body[^>]*>([\s\S]*)</body>',
    caseSensitive: false,
  ).firstMatch(raw);
  if (bodyMatch != null) return bodyMatch.group(1)!;
  return raw;
}

class _HtmlWalk {
  final StringBuffer plain = StringBuffer();
  final List<FormatRun> runs = [];

  bool bold = false;
  bool italic = false;
  Color? color;
  String? fontFamily;
  var listDepth = 0;
  final List<_ListCtx> listStack = [];
  var pre = false;
  /// Flatten block breaks (used inside table cells).
  var flattenBlocks = false;
  var suppressLeadingSpace = true;

  void visitChildren(dom.Node node) {
    for (final child in node.nodes) {
      visit(child);
    }
  }

  void visit(dom.Node node) {
    if (node is dom.Text) {
      writeText(node.text);
      return;
    }
    if (node is! dom.Element) return;
    if (_elementIsHidden(node)) return;
    final tag = node.localName?.toLowerCase() ?? '';
    if (tag == 'script' ||
        tag == 'style' ||
        tag == 'head' ||
        tag == 'meta' ||
        tag == 'link' ||
        tag == 'noscript') {
      return;
    }

    if (tag == 'br') {
      if (flattenBlocks) {
        writeRaw(' ');
      } else {
        writeRaw('\n');
      }
      return;
    }

    if (tag == 'table') {
      _writeTable(node);
      return;
    }

    // Skip structural table pieces if somehow visited outside _writeTable.
    if (tag == 'thead' ||
        tag == 'tbody' ||
        tag == 'tfoot' ||
        tag == 'tr' ||
        tag == 'td' ||
        tag == 'th' ||
        tag == 'colgroup' ||
        tag == 'col' ||
        tag == 'caption') {
      visitChildren(node);
      return;
    }

    if (tag == 'ul' || tag == 'ol') {
      if (!flattenBlocks) ensureBlockBreak();
      listStack.add(tag == 'ol' ? _ListCtx.ol() : _ListCtx.ul());
      listDepth++;
      visitChildren(node);
      listDepth = (listDepth - 1).clamp(0, 64);
      listStack.removeLast();
      if (!flattenBlocks) ensureBlockBreak();
      return;
    }

    if (tag == 'li') {
      if (!flattenBlocks) ensureBlockBreak();
      final indent = '  ' * (listDepth > 0 ? listDepth - 1 : 0);
      final marker =
          listStack.isEmpty ? '• ' : listStack.last.nextMarker();
      writeRaw('$indent$marker');
      visitChildren(node);
      if (!flattenBlocks) ensureBlockBreak();
      return;
    }

    final prevBold = bold;
    final prevItalic = italic;
    final prevColor = color;
    final prevFont = fontFamily;
    final prevPre = pre;

    if (tag == 'b' || tag == 'strong') bold = true;
    if (tag == 'i' || tag == 'em') italic = true;
    if (tag == 'code' || tag == 'tt' || tag == 'kbd' || tag == 'samp') {
      fontFamily ??= 'monospace';
    }

    final stylePre = _styleRequestsPre(node.attributes['style']);
    if (tag == 'pre' || stylePre) {
      pre = true;
      fontFamily ??= 'monospace';
    }

    final isBlock = tag == 'p' ||
        tag == 'div' ||
        tag == 'section' ||
        tag == 'article' ||
        tag == 'blockquote' ||
        tag == 'pre' ||
        tag.startsWith('h');

    if (isBlock) {
      if (flattenBlocks) {
        final s = plain.toString();
        if (s.isNotEmpty &&
            !s.endsWith(' ') &&
            !s.endsWith('\t') &&
            !s.endsWith('\n')) {
          writeRaw(' ');
        }
      } else {
        ensureBlockBreak();
      }
    }
    if (tag.startsWith('h')) bold = true;

    // CSS indent → leading tabs at the start of a block line.
    final indentTabs = _cssIndentTabs(node.attributes['style']);
    if (indentTabs > 0 && isBlock) {
      ensureBlockBreak();
      writeRaw('\t' * indentTabs);
    }

    _applyInlineStyles(node);
    if (tag == 'font') {
      final face = node.attributes['face']?.trim();
      if (face != null && face.isNotEmpty) {
        fontFamily = _mapFontFamily(face) ?? fontFamily;
      }
      final colorAttr = node.attributes['color']?.trim();
      if (colorAttr != null && colorAttr.isNotEmpty) {
        color = _parseCssColor(colorAttr) ?? color;
      }
    }

    visitChildren(node);

    if ((isBlock && !flattenBlocks) || (tag == 'pre' && !flattenBlocks)) {
      ensureBlockBreak();
    }

    bold = prevBold;
    italic = prevItalic;
    color = prevColor;
    fontFamily = prevFont;
    pre = prevPre;
  }

  /// Emit a table as TSV: cells separated by `\t`, rows by `\n`.
  /// Cell internals are flattened (no newlines) so columns stay aligned.
  void _writeTable(dom.Element table) {
    ensureBlockBreak();
    final rows = <dom.Element>[];
    void collectRows(dom.Element el) {
      for (final child in el.children) {
        final t = child.localName?.toLowerCase() ?? '';
        if (t == 'tr') {
          rows.add(child);
        } else if (t == 'thead' || t == 'tbody' || t == 'tfoot') {
          collectRows(child);
        }
      }
    }

    collectRows(table);
    // Some clipboard HTML puts cells directly under table (rare).
    if (rows.isEmpty) {
      for (final child in table.children) {
        final t = child.localName?.toLowerCase() ?? '';
        if (t == 'td' || t == 'th') {
          rows.add(table);
          break;
        }
      }
    }

    for (var r = 0; r < rows.length; r++) {
      if (r > 0) writeRaw('\n');
      final row = rows[r];
      final cells = row.children
          .where((c) {
            final t = c.localName?.toLowerCase() ?? '';
            return t == 'td' || t == 'th';
          })
          .toList();
      for (var c = 0; c < cells.length; c++) {
        if (c > 0) writeRaw('\t');
        final cell = cells[c];
        final prevFlat = flattenBlocks;
        final prevPre = pre;
        flattenBlocks = true;
        // Keep pre only if the cell itself asks for it.
        pre = _styleRequestsPre(cell.attributes['style']);
        final prevBold = bold;
        final prevItalic = italic;
        final prevColor = color;
        final prevFont = fontFamily;
        if (cell.localName?.toLowerCase() == 'th') bold = true;
        _applyInlineStyles(cell);
        visitChildren(cell);
        bold = prevBold;
        italic = prevItalic;
        color = prevColor;
        fontFamily = prevFont;
        flattenBlocks = prevFlat;
        pre = prevPre;
      }
    }
    ensureBlockBreak();
  }

  void _applyInlineStyles(dom.Element el) {
    final style = el.attributes['style'];
    if (style == null || style.isEmpty) return;
    final colorMatch = RegExp(
      r'(?:^|;)\s*color\s*:\s*([^;]+)',
      caseSensitive: false,
    ).firstMatch(style);
    if (colorMatch != null) {
      color = _parseCssColor(colorMatch.group(1)!.trim()) ?? color;
    }
    final weight = RegExp(
      r'(?:^|;)\s*font-weight\s*:\s*([^;]+)',
      caseSensitive: false,
    ).firstMatch(style);
    if (weight != null) {
      final w = weight.group(1)!.trim().toLowerCase();
      final n = int.tryParse(w);
      if (w == 'bold' || w == 'bolder' || (n != null && n >= 600)) {
        bold = true;
      }
    }
    final fontStyle = RegExp(
      r'(?:^|;)\s*font-style\s*:\s*([^;]+)',
      caseSensitive: false,
    ).firstMatch(style);
    if (fontStyle != null &&
        fontStyle.group(1)!.trim().toLowerCase().startsWith('italic')) {
      italic = true;
    }
    final family = RegExp(
      r'(?:^|;)\s*font-family\s*:\s*([^;]+)',
      caseSensitive: false,
    ).firstMatch(style);
    if (family != null) {
      fontFamily = _mapFontFamily(family.group(1)!) ?? fontFamily;
    }
  }

  void ensureBlockBreak() {
    if (flattenBlocks) return;
    if (plain.isEmpty) return;
    final s = plain.toString();
    if (s.endsWith('\n')) return;
    writeRaw('\n');
  }

  void writeText(String raw) {
    if (raw.isEmpty) return;
    // Decode common whitespace entities already turned into chars by the
    // parser; normalize exotic spaces to regular space (keep tabs).
    var text = raw
        .replaceAll('\u00A0', ' ') // nbsp
        .replaceAll('\u202F', ' ') // narrow nbsp
        .replaceAll('\u2007', ' ') // figure space
        .replaceAll('\u2003', ' ') // em space
        .replaceAll('\u2002', ' ') // en space
        .replaceAll('\u2009', ' ') // thin space
        .replaceAll('\u200B', '') // zero-width space
        .replaceAll('\uFEFF', ''); // BOM
    if (text.isEmpty) return;

    final hasVisible = RegExp(r'[^\s]').hasMatch(text);

    if (flattenBlocks) {
      // Table cells: one line, keep tabs, collapse breaks to spaces.
      text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
      text = text.replaceAll('\n', ' ');
      if (!hasVisible) {
        // Pure whitespace between cell tags — skip.
        return;
      }
      text = text.replaceAll(RegExp(r' +'), ' ');
      // Keep a separating space if the cell already has content; strip only
      // when starting the cell / after a tab.
      if (plain.isEmpty ||
          plain.toString().endsWith('\n') ||
          plain.toString().endsWith('\t')) {
        text = text.replaceFirst(RegExp(r'^ +'), '');
      }
      text = text.replaceFirst(RegExp(r' +$'), '');
      if (text.isEmpty) return;
      writeRaw(text);
      return;
    }

    if (pre) {
      text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
      writeRaw(text);
      return;
    }

    // Whitespace-only text nodes are almost always HTML pretty-print between
    // tags. Turn any newlines into a single block break; drop pure indent.
    if (!hasVisible) {
      if (text.contains('\n') || text.contains('\r')) {
        ensureBlockBreak();
      }
      // Pure spaces/tabs between tags — ignore (do not eat real indent that
      // lives inside the next text node with visible characters).
      return;
    }

    // Visible text: keep leading spaces/tabs (code indent, alignment).
    // Collapse only mid-run spaces from wrapping; keep `\t` and leading indent.
    text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (text.contains('\n')) {
      final parts = text.split('\n');
      for (var i = 0; i < parts.length; i++) {
        if (i > 0) writeRaw('\n');
        final part = _collapseInternalSpaces(parts[i]);
        if (part.isEmpty) continue;
        writeRaw(part);
      }
      return;
    }

    writeRaw(_collapseInternalSpaces(text));
  }

  /// Collapse runs of spaces to one, but keep leading spaces/tabs intact.
  String _collapseInternalSpaces(String s) {
    final m = RegExp(r'^([ \t]*)(.*)$', dotAll: true).firstMatch(s);
    if (m == null) return s;
    final leading = m.group(1)!;
    final rest = m.group(2)!.replaceAll(RegExp(r' +'), ' ');
    return '$leading$rest';
  }

  void writeRaw(String text) {
    if (text.isEmpty) return;
    suppressLeadingSpace = false;
    final start = plain.length;
    plain.write(text);
    final end = plain.length;
    final format = TextFormat(
      bold: bold,
      italic: italic,
      background: color,
      fontFamily: fontFamily,
    );
    if (!format.isEmpty && end > start) {
      runs.add(FormatRun(start, end, format));
    }
    // After a newline, next pretty-print spaces between tags can be stripped.
    if (text.endsWith('\n')) {
      suppressLeadingSpace = true;
    }
  }

  void trimTrailingNewlines() {
    final s = plain.toString();
    final trimmed = s.replaceFirst(RegExp(r'\n+$'), '');
    if (trimmed.length == s.length) return;
    plain
      ..clear()
      ..write(trimmed);
    for (final r in runs) {
      if (r.end > plain.length) r.end = plain.length;
      if (r.start > plain.length) r.start = plain.length;
    }
    runs.removeWhere((r) => r.end <= r.start);
  }
}

class _ListCtx {
  _ListCtx.ul() : ordered = false, index = 0;
  _ListCtx.ol() : ordered = true, index = 0;

  final bool ordered;
  int index;

  String nextMarker() {
    if (!ordered) return '• ';
    index++;
    return '$index. ';
  }
}

/// Clipboard HTML often includes a screen-reader or off-screen copy of the
/// same selection. Those nodes are not part of what the user copied.
bool _elementIsHidden(dom.Element node) {
  if (node.attributes.containsKey('hidden')) return true;
  final style = node.attributes['style'];
  if (style == null || style.isEmpty) return false;
  if (RegExp(r'display\s*:\s*none', caseSensitive: false).hasMatch(style)) {
    return true;
  }
  if (RegExp(r'visibility\s*:\s*hidden', caseSensitive: false).hasMatch(style)) {
    return true;
  }
  return false;
}

bool _styleRequestsPre(String? style) {
  if (style == null || style.isEmpty) return false;
  final m = RegExp(
    r'(?:^|;)\s*white-space\s*:\s*([^;]+)',
    caseSensitive: false,
  ).firstMatch(style);
  if (m == null) return false;
  final v = m.group(1)!.trim().toLowerCase();
  return v == 'pre' ||
      v == 'pre-wrap' ||
      v == 'pre-line' ||
      v == 'break-spaces';
}

/// Map CSS left indent to a number of tabs (≈ 40px / 2em / 4ch per tab).
int _cssIndentTabs(String? style) {
  if (style == null || style.isEmpty) return 0;
  double? px;
  for (final prop in ['text-indent', 'margin-left', 'padding-left']) {
    final m = RegExp(
      '(?:^|;)\\s*$prop\\s*:\\s*([^;]+)',
      caseSensitive: false,
    ).firstMatch(style);
    if (m == null) continue;
    final v = m.group(1)!.trim().toLowerCase();
    if (v == '0' || v == '0px' || v == '0pt' || v == '0em') continue;
    final numMatch = RegExp(r'^(-?[\d.]+)\s*(px|pt|em|rem|ch)?$').firstMatch(v);
    if (numMatch == null) continue;
    final n = double.tryParse(numMatch.group(1)!);
    if (n == null || n <= 0) continue;
    final unit = numMatch.group(2) ?? 'px';
    final asPx = switch (unit) {
      'pt' => n * 96 / 72,
      'em' || 'rem' || 'ch' => n * 16,
      _ => n,
    };
    px = (px ?? 0) + asPx;
  }
  if (px == null || px < 8) return 0;
  return (px / 40).round().clamp(1, 16);
}

List<FormatRun> _normalizeRuns(List<FormatRun> runs) {
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
    if (r.start <= last.end && r.format == last.format) {
      if (r.end > last.end) last.end = r.end;
    } else if (r.start < last.end && r.format != last.format) {
      if (r.start > last.start) {
        last.end = r.start;
        out.add(r);
      } else {
        out
          ..removeLast()
          ..add(r);
      }
    } else {
      out.add(r);
    }
  }
  return out.where((r) => r.end > r.start).toList();
}

Color? _parseCssColor(String raw) {
  var s = raw.trim().toLowerCase();
  if (s.isEmpty) return null;

  final rgb = RegExp(
    r'rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)',
  ).firstMatch(s);
  if (rgb != null) {
    final r = int.parse(rgb.group(1)!).clamp(0, 255);
    final g = int.parse(rgb.group(2)!).clamp(0, 255);
    final b = int.parse(rgb.group(3)!).clamp(0, 255);
    return Color(0xFF000000 | (r << 16) | (g << 8) | b);
  }

  if (s.startsWith('#')) {
    var h = s.substring(1);
    if (h.length == 3) {
      h = h.split('').map((c) => '$c$c').join();
    }
    if (h.length == 8) h = h.substring(0, 6);
    if (h.length == 6) {
      final v = int.tryParse(h, radix: 16);
      if (v != null) return Color(0xFF000000 | v);
    }
  }

  const named = <String, int>{
    'black': 0xFF000000,
    'white': 0xFFFFFFFF,
    'red': 0xFFFF0000,
    'green': 0xFF008000,
    'blue': 0xFF0000FF,
    'yellow': 0xFFFFFF00,
    'cyan': 0xFF00FFFF,
    'magenta': 0xFFFF00FF,
    'gray': 0xFF808080,
    'grey': 0xFF808080,
    'orange': 0xFFFFA500,
    'purple': 0xFF800080,
    'navy': 0xFF000080,
    'teal': 0xFF008080,
    'maroon': 0xFF800000,
    'olive': 0xFF808000,
    'silver': 0xFFC0C0C0,
    'lime': 0xFF00FF00,
    'aqua': 0xFF00FFFF,
    'fuchsia': 0xFFFF00FF,
  };
  final n = named[s];
  if (n != null) return Color(n);
  return null;
}

String? _mapFontFamily(String css) {
  final first = css
      .split(',')
      .map((s) => s.trim().replaceAll('"', '').replaceAll("'", '').toLowerCase())
      .firstWhere((s) => s.isNotEmpty, orElse: () => '');
  if (first.isEmpty) return null;
  if (first.contains('mono') ||
      first.contains('consolas') ||
      first.contains('courier') ||
      first == 'ui-monospace' ||
      first.contains('menlo') ||
      first.contains('fira code') ||
      first.contains('source code')) {
    return 'monospace';
  }
  if (first.contains('comic')) return 'comic';
  if (first.contains('times') || first.contains('georgia')) return 'times';
  if (first.contains('arial') ||
      first.contains('helvetica') ||
      first == 'sans-serif') {
    return 'arial';
  }
  if (first.contains('ubuntu')) return 'ubuntu';
  if (first.contains('garamond')) return 'garamond';
  if (first == 'serif' || first.contains('palatino')) return 'serif';
  if (first.contains('cursive') || first.contains('brush')) return 'cursive';
  if (kMessageFonts.contains(first)) return first;
  return null;
}
