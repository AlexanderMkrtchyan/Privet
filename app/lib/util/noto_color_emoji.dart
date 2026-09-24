import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show
        ChangeNotifier,
        TargetPlatform,
        ValueNotifier,
        defaultTargetPlatform,
        kIsWeb;
import 'package:flutter/services.dart' show rootBundle;

import 'emoji_style.dart';

/// Asset packed by `scripts/extract-noto-color-emoji.py` — the same 109px
/// CBDT strikes Linux paints from `Noto Color Emoji`.
const kNotoColorEmojiAsset = 'assets/emoji/noto_color_emoji.bin';

/// Painted inline Noto size, as a multiple of the surrounding [fontSize].
const double notoInlineEm = 1.15;

/// Square dest for a Noto strike inside the placeholder [slot].
ui.Rect notoInlineDestRect(ui.Rect slot, double fontSize) {
  final side = math.min(
    math.min(slot.width, slot.height),
    fontSize * notoInlineEm,
  );
  return ui.Rect.fromCenter(center: slot.center, width: side, height: side);
}

/// Tests can force the bundled atlas on Linux so widget tests exercise the
/// Windows path without a Windows embedder.
bool privetForceBundledNotoEmoji = false;

/// Windows cannot paint the CBDT Noto font (DirectWrite), so Google emoji
/// would otherwise fall through to Segoe UI Emoji. Linux already has Noto.
bool get useBundledNotoColorEmoji {
  if (privetForceBundledNotoEmoji) return true;
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.windows;
}

bool isNotoAtlasGrapheme(String grapheme) {
  if (grapheme.isEmpty || grapheme == kGoogleEmojiMark) return false;
  return NotoColorEmojiCache.instance.hasGlyph(grapheme);
}

/// Decodes bundled Noto Color Emoji PNGs on demand.
class NotoColorEmojiCache extends ChangeNotifier {
  NotoColorEmojiCache._();

  static final NotoColorEmojiCache instance = NotoColorEmojiCache._();

  Map<String, int>? _keyToBlob;
  List<Uint8List>? _blobs;
  final Map<int, ui.Image> _images = {};
  final Set<int> _decoding = {};
  bool _loading = false;
  Object? _loadError;
  int _generation = 0;
  bool _notifyScheduled = false;

  int get generation => _generation;

  final ValueNotifier<int> generationListenable = ValueNotifier(0);

  bool get isLoaded => _blobs != null;

  Future<void> ensureLoaded() async {
    if (_blobs != null || _loading) return;
    _loading = true;
    try {
      final data = await rootBundle.load(kNotoColorEmojiAsset);
      _parse(data.buffer.asByteData(data.offsetInBytes, data.lengthInBytes));
      _scheduleNotify();
    } catch (e) {
      _loadError = e;
    } finally {
      _loading = false;
    }
  }

  void _parse(ByteData data) {
    var o = 0;
    final magic = String.fromCharCodes([
      data.getUint8(o),
      data.getUint8(o + 1),
      data.getUint8(o + 2),
      data.getUint8(o + 3),
    ]);
    o += 4;
    if (magic != 'NCE1') {
      throw FormatException('Bad Noto emoji atlas magic: $magic');
    }
    final nBlobs = data.getUint32(o, Endian.little);
    o += 4;
    final blobs = <Uint8List>[];
    for (var i = 0; i < nBlobs; i++) {
      final len = data.getUint32(o, Endian.little);
      o += 4;
      blobs.add(
        data.buffer.asUint8List(data.offsetInBytes + o, len),
      );
      o += len;
    }
    final nKeys = data.getUint32(o, Endian.little);
    o += 4;
    final keys = <String, int>{};
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    for (var i = 0; i < nKeys; i++) {
      final keyLen = data.getUint16(o, Endian.little);
      o += 2;
      final key = utf8.decode(bytes.sublist(o, o + keyLen));
      o += keyLen;
      final ix = data.getUint32(o, Endian.little);
      o += 4;
      keys[key] = ix;
    }
    _blobs = blobs;
    _keyToBlob = keys;
  }

  int? _blobIndex(String emoji) {
    final map = _keyToBlob;
    if (map == null) {
      unawaited(ensureLoaded());
      return null;
    }
    final direct = map[emoji];
    if (direct != null) return direct;
    final stripped = emoji.replaceAll('\uFE0F', '');
    if (stripped != emoji) {
      final ix = map[stripped];
      if (ix != null) return ix;
    }
    final withVs = '$stripped\uFE0F';
    return map[withVs];
  }

  bool hasGlyph(String emoji) => _blobIndex(emoji) != null;

  /// Returns a decoded frame, or `null` while the atlas / PNG is still loading.
  ui.Image? imageFor(String emoji) {
    final ix = _blobIndex(emoji);
    if (ix == null) return null;
    final hit = _images[ix];
    if (hit != null) return hit;
    unawaited(_decode(ix));
    return null;
  }

  Future<void> _decode(int ix) async {
    if (_images.containsKey(ix) || !_decoding.add(ix)) return;
    final blobs = _blobs;
    if (blobs == null || ix < 0 || ix >= blobs.length) {
      _decoding.remove(ix);
      return;
    }
    try {
      final codec = await ui.instantiateImageCodec(blobs[ix]);
      final frame = await codec.getNextFrame();
      _images[ix] = frame.image;
      _scheduleNotify();
    } finally {
      _decoding.remove(ix);
    }
  }

  void _scheduleNotify() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      _generation++;
      generationListenable.value = _generation;
      notifyListeners();
    });
  }

  /// Test-only: drop decoded frames (keeps the parsed atlas).
  void debugResetImages() {
    _images.clear();
    _decoding.clear();
  }

  Object? get debugLoadError => _loadError;
}
