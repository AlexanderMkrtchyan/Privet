import 'dart:typed_data';

/// One ANMF frame from an animated WebP, ready to decode as a still image.
class KolobokWebpFrame {
  const KolobokWebpFrame({
    required this.offsetX,
    required this.offsetY,
    required this.width,
    required this.height,
    required this.durationMs,
    required this.blend,
    required this.disposeToBackground,
    required this.stillWebp,
  });

  final int offsetX;
  final int offsetY;
  final int width;
  final int height;
  final int durationMs;

  /// When true, alpha-blend onto the canvas; when false, replace the rect.
  final bool blend;

  /// When true, the frame rect is cleared after this frame is shown.
  final bool disposeToBackground;

  /// A still WebP (VP8/VP8L, optionally with ALPH) for this frame's bitmap.
  final Uint8List stillWebp;
}

/// Canvas size + ANMF frames. Null [parseAnimatedWebp] means not animated WebP.
class KolobokWebpAnimation {
  const KolobokWebpAnimation({
    required this.canvasWidth,
    required this.canvasHeight,
    required this.frames,
  });

  final int canvasWidth;
  final int canvasHeight;
  final List<KolobokWebpFrame> frames;
}

bool isRiffWebp(Uint8List bytes) {
  if (bytes.length < 12) return false;
  return bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50;
}

/// Splits an animated WebP into still-image frames.
///
/// Flutter's Windows decoder often reports [frameCount] == 1 for lossless
/// (VP8L) animated WebP, so callers decode each [KolobokWebpFrame.stillWebp]
/// as a still image — that path works on every backend.
KolobokWebpAnimation? parseAnimatedWebp(Uint8List bytes) {
  if (!isRiffWebp(bytes)) return null;

  var canvasW = 0;
  var canvasH = 0;
  var animated = false;
  final frames = <KolobokWebpFrame>[];

  var i = 12;
  while (i + 8 <= bytes.length) {
    final fourcc = bytes.sublist(i, i + 4);
    final size = _le32(bytes, i + 4);
    final payloadStart = i + 8;
    if (payloadStart + size > bytes.length) break;
    final payload = Uint8List.sublistView(bytes, payloadStart, payloadStart + size);

    if (_eq(fourcc, _vp8x)) {
      if (payload.length >= 10) {
        animated = (payload[0] & 0x02) != 0;
        canvasW = _le24(payload, 4) + 1;
        canvasH = _le24(payload, 7) + 1;
      }
    } else if (_eq(fourcc, _anmf)) {
      final frame = _parseAnmf(payload);
      if (frame != null) frames.add(frame);
    }

    i = payloadStart + size + (size & 1);
  }

  if (!animated || frames.isEmpty || canvasW <= 0 || canvasH <= 0) return null;
  return KolobokWebpAnimation(
    canvasWidth: canvasW,
    canvasHeight: canvasH,
    frames: frames,
  );
}

KolobokWebpFrame? _parseAnmf(Uint8List payload) {
  if (payload.length < 16) return null;
  final x = _le24(payload, 0) * 2;
  final y = _le24(payload, 3) * 2;
  final w = _le24(payload, 6) + 1;
  final h = _le24(payload, 9) + 1;
  final duration = _le24(payload, 12);
  final flags = payload[15];
  final blend = (flags & 0x02) == 0;
  final disposeToBackground = (flags & 0x01) != 0;

  final still = _wrapStillWebp(Uint8List.sublistView(payload, 16));
  if (still == null) return null;

  return KolobokWebpFrame(
    offsetX: x,
    offsetY: y,
    width: w,
    height: h,
    durationMs: duration,
    blend: blend,
    disposeToBackground: disposeToBackground,
    stillWebp: still,
  );
}

/// Packs the ANMF bitstream (ALPH / VP8 / VP8L chunks) into a still WebP.
Uint8List? _wrapStillWebp(Uint8List bitstream) {
  final body = BytesBuilder(copy: false);
  var j = 0;
  var any = false;
  while (j + 8 <= bitstream.length) {
    final size = _le32(bitstream, j + 4);
    final end = j + 8 + size;
    if (end > bitstream.length) break;
    body.add(Uint8List.sublistView(bitstream, j, end));
    if (size.isOdd) body.addByte(0);
    j = end + (size & 1);
    any = true;
  }
  if (!any) return null;

  final bodyBytes = body.takeBytes();
  final riffSize = 4 + bodyBytes.length;
  final out = BytesBuilder(copy: false);
  out.add(_riff);
  out.add(_le32Bytes(riffSize));
  out.add(_webp);
  out.add(bodyBytes);
  return out.takeBytes();
}

int _le24(Uint8List b, int i) => b[i] | (b[i + 1] << 8) | (b[i + 2] << 16);

int _le32(Uint8List b, int i) =>
    b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);

Uint8List _le32Bytes(int v) => Uint8List.fromList([
      v & 0xff,
      (v >> 8) & 0xff,
      (v >> 16) & 0xff,
      (v >> 24) & 0xff,
    ]);

bool _eq(Uint8List a, List<int> b) =>
    a.length >= 4 && a[0] == b[0] && a[1] == b[1] && a[2] == b[2] && a[3] == b[3];

const _riff = [0x52, 0x49, 0x46, 0x46];
const _webp = [0x57, 0x45, 0x42, 0x50];
const _vp8x = [0x56, 0x50, 0x38, 0x58];
const _anmf = [0x41, 0x4e, 0x4d, 0x46];
