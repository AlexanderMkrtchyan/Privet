import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import '../util/clipboard_files.dart';
import '../util/composer_media_attach.dart';
import '../util/copy_image.dart';
import '../util/image_context_menu.dart';
import '../util/low_resource.dart';
import '../util/media_cache.dart';
import '../util/web_select_cursor.dart';
import 'cached_media_image.dart';
import 'image_annotation.dart';

/// Full-screen messenger-style image viewer: tap backdrop / close to dismiss,
/// pinch or buttons to zoom, optional prev/next for galleries, and basic
/// markup (pencil, rectangle, arrow). Annotated images can be staged into the
/// message composer.
Future<void> showImageLightbox(
  BuildContext context, {
  required List<String> urls,
  int initialIndex = 0,
  List<String?>? filenames,
}) {
  assert(urls.isNotEmpty);
  final index = initialIndex.clamp(0, urls.length - 1);
  final instant = privetLowResource;
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close image',
    barrierColor: Colors.black.withValues(alpha: 0.92),
    transitionDuration: privetAnim(const Duration(milliseconds: 180)),
    pageBuilder: (ctx, animation, secondaryAnimation) {
      return _ImageLightboxPage(
        urls: urls,
        initialIndex: index,
        filenames: filenames,
      );
    },
    transitionBuilder: (ctx, animation, secondaryAnimation, child) {
      if (instant) return child;
      return FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: child,
      );
    },
  );
}

class _ImageLightboxPage extends StatefulWidget {
  const _ImageLightboxPage({
    required this.urls,
    required this.initialIndex,
    this.filenames,
  });

  final List<String> urls;
  final int initialIndex;
  final List<String?>? filenames;

  @override
  State<_ImageLightboxPage> createState() => _ImageLightboxPageState();
}

class _ImageLightboxPageState extends State<_ImageLightboxPage> {
  static const double _minScale = 1;
  static const double _maxScale = 4;
  static const double _zoomStep = 0.5;

  /// ScaffoldMessenger scoped to this full-screen dialog. The app's root
  /// messenger renders its snackbars behind the lightbox, so confirmations
  /// ("Saved to …") must be shown inside the dialog to be visible.
  final GlobalKey<ScaffoldMessengerState> _snackKey =
      GlobalKey<ScaffoldMessengerState>();

  late final PageController _pageController;
  late final List<TransformationController> _transforms;
  late final List<List<ImageMark>> _marks;
  late final List<GlobalKey> _captureImageKeys;
  late final List<GlobalKey> _captureAnnotKeys;
  late int _index;
  bool _zoomed = false;

  /// True while a pan (left button held) is in progress on a zoomed image —
  /// switches the cursor from an open hand to a clenched grabbing hand.
  bool _grabDragging = false;

  /// Recorded snapshot of committed marks per page — rebuilt on commit/undo/
  /// clear so draw ticks don't re-issue every stroke's path on web.
  late final List<ui.Picture?> _markPictures;

  bool _annotateMode = false;
  ImageAnnotTool _tool = ImageAnnotTool.pencil;
  int _inkIndex = 0;
  ImageMarkDraft? _draft;
  Offset? _cursorLocal;
  bool _cursorOver = false;
  bool _exporting = false;
  bool _hasCommittedMarks = false;

  /// High-frequency draw updates — must not rebuild Image.network.
  final ValueNotifier<int> _draftTick = ValueNotifier<int>(0);

  /// Cursor-only ticks — avoid repainting committed marks on every hover.
  final ValueNotifier<int> _cursorTick = ValueNotifier<int>(0);

  bool get _gallery => widget.urls.length > 1;

  String get _url => widget.urls[_index];

  Color get _ink => kAnnotationInks[_inkIndex];

  List<ImageMark> get _currentMarks => _marks[_index];

  bool get _drawingLocked => _annotateMode;

  bool get _hasMarks =>
      _hasCommittedMarks || _currentMarks.isNotEmpty || _draft != null;

  bool get _canAddToMessage =>
      _hasMarks && composerMediaAttachAvailable && !_exporting;

  String get _downloadName {
    final named = widget.filenames;
    if (named != null &&
        _index < named.length &&
        named[_index] != null &&
        named[_index]!.isNotEmpty) {
      return named[_index]!;
    }
    return 'image.jpg';
  }

  void _bumpDraft() {
    _draftTick.value++;
  }

  void _bumpCursor() {
    _cursorTick.value++;
  }

  /// Re-record the committed-marks snapshot for [page]. Called only when the
  /// marks list changes (commit/undo/clear), never during a stroke.
  void _rebuildMarkPicture(int page) {
    final old = _markPictures[page];
    if (old != null) {
      old.dispose();
      _markPictures[page] = null;
    }
    final marks = _marks[page];
    if (marks.isEmpty) return;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    for (final mark in marks) {
      mark.paint(canvas);
    }
    _markPictures[page] = recorder.endRecording();
  }

  void _syncHasCommittedMarks() {
    final next = _currentMarks.isNotEmpty;
    if (next != _hasCommittedMarks) {
      setState(() => _hasCommittedMarks = next);
    }
  }

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _pageController = PageController(initialPage: _index);
    _transforms = List.generate(
      widget.urls.length,
      (_) => TransformationController(),
    );
    _marks = List.generate(widget.urls.length, (_) => <ImageMark>[]);
    _markPictures = List.generate(widget.urls.length, (_) => null);
    _captureImageKeys = List.generate(widget.urls.length, (_) => GlobalKey());
    _captureAnnotKeys = List.generate(widget.urls.length, (_) => GlobalKey());
  }

  @override
  void dispose() {
    setPrivetAnnotHover(false);
    _draftTick.dispose();
    _cursorTick.dispose();
    _pageController.dispose();
    for (final p in _markPictures) {
      p?.dispose();
    }
    for (final t in _transforms) {
      t.dispose();
    }
    super.dispose();
  }

  void _close() => Navigator.of(context).maybePop();

  /// Downloads the current image, serving cached bytes when available so the
  /// save is instant instead of a fresh server download. Confirms in the
  /// dialog's own messenger — the root one is hidden behind this overlay.
  Future<void> _downloadCurrent() async {
    final saved = await downloadMediaFromCache(_url, filename: _downloadName);
    if (!mounted || saved == null) return;
    _snackKey.currentState?.showSnackBar(
      SnackBar(
        content: Text('Saved to $saved'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _onPageChanged(int page) {
    _transforms[_index].value = Matrix4.identity();
    _draft = null;
    _cursorLocal = null;
    _cursorOver = false;
    setState(() {
      _index = page;
      _zoomed = false;
      _grabDragging = false;
      _hasCommittedMarks = _marks[page].isNotEmpty;
    });
    _bumpDraft();
    _bumpCursor();
  }

  void _syncZoomed() {
    final scale = _transforms[_index].value.getMaxScaleOnAxis();
    final next = scale > 1.05;
    if (next != _zoomed) {
      setState(() {
        _zoomed = next;
        if (!next) _grabDragging = false;
      });
    }
  }

  void _setScale(double scale, {Offset? focal}) {
    final clamped = scale.clamp(_minScale, _maxScale);
    final controller = _transforms[_index];
    final size = MediaQuery.sizeOf(context);
    final center = focal ?? Offset(size.width / 2, size.height / 2);
    final current = controller.value.getMaxScaleOnAxis();
    if ((clamped - current).abs() < 0.01) return;

    final scene = controller.toScene(center);
    final next = Matrix4.identity()
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..scaleByDouble(clamped, clamped, 1, 1)
      ..translateByDouble(-scene.dx, -scene.dy, 0, 1);
    controller.value = next;
    _syncZoomed();
  }

  void _zoomBy(double delta) {
    if (_drawingLocked) return;
    final current = _transforms[_index].value.getMaxScaleOnAxis();
    _setScale(current + delta);
  }

  void _toggleZoom(TapDownDetails details) {
    if (_drawingLocked) return;
    final current = _transforms[_index].value.getMaxScaleOnAxis();
    if (current > 1.05) {
      _transforms[_index].value = Matrix4.identity();
      setState(() => _zoomed = false);
    } else {
      _setScale(2.5, focal: details.localPosition);
    }
  }

  void _go(int delta) {
    if (!_gallery || _zoomed || _drawingLocked) return;
    final next = (_index + delta).clamp(0, widget.urls.length - 1);
    if (next == _index) return;
    _pageController.animateToPage(
      next,
      duration: privetAnim(const Duration(milliseconds: 220)),
      curve: Curves.easeOutCubic,
    );
  }

  void _setAnnotateMode(bool on) {
    if (!on) setPrivetAnnotHover(false);
    if (_annotateMode == on) return;
    _draft = null;
    _cursorLocal = null;
    _cursorOver = false;
    setState(() {
      _annotateMode = on;
      if (on) {
        _transforms[_index].value = Matrix4.identity();
        _zoomed = false;
        _grabDragging = false;
      }
    });
    _bumpDraft();
    _bumpCursor();
  }

  void _selectTool(ImageAnnotTool tool) {
    final alreadyOn = _annotateMode;
    final sameTool = _tool == tool;
    _draft = null;
    if (alreadyOn && sameTool) {
      _bumpDraft();
      return;
    }
    setState(() {
      _annotateMode = true;
      _tool = tool;
      if (!alreadyOn) {
        _transforms[_index].value = Matrix4.identity();
        _zoomed = false;
        _grabDragging = false;
      }
    });
    _bumpDraft();
  }

  void _cycleInk() {
    setState(() => _inkIndex = (_inkIndex + 1) % kAnnotationInks.length);
    _bumpDraft();
    _bumpCursor();
  }

  void _undo() {
    if (_currentMarks.isEmpty) return;
    _currentMarks.removeLast();
    _draft = null;
    _rebuildMarkPicture(_index);
    _syncHasCommittedMarks();
    _bumpDraft();
    setState(() {});
  }

  void _clearMarks() {
    if (_currentMarks.isEmpty && _draft == null) return;
    _currentMarks.clear();
    _draft = null;
    _hasCommittedMarks = false;
    _rebuildMarkPicture(_index);
    _bumpDraft();
    setState(() {});
  }

  double get _strokeWidth {
    final box = _captureImageKeys[_index].currentContext?.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      return annotationStrokeWidth(box.size);
    }
    final side = MediaQuery.sizeOf(context).shortestSide;
    return annotationStrokeWidth(Size(side, side));
  }

  void _onDrawStart(int page, Offset local) {
    if (!_annotateMode || page != _index) return;
    _cursorLocal = local;
    _cursorOver = true;
    _draft = ImageMarkDraft(
      tool: _tool,
      start: local,
      color: _ink,
      strokeWidth: _strokeWidth,
    );
    _bumpDraft();
    _bumpCursor();
  }

  void _onDrawUpdate(int page, Offset local) {
    if (_draft == null || page != _index) return;
    _cursorLocal = local;
    final changed = _draft!.update(local);
    _bumpCursor();
    // Pencil only repaints the overlay when a new point was added; rect/arrow
    // move their end point every update.
    if (changed || _draft!.tool != ImageAnnotTool.pencil) {
      _bumpDraft();
    }
  }

  void _onDrawEnd(int page) {
    if (_draft == null || page != _index) return;
    final committed = _draft!.commit();
    _draft = null;
    if (committed != null) {
      _marks[page].add(committed);
      _hasCommittedMarks = true;
      _rebuildMarkPicture(page);
      setState(() {});
    }
    _bumpDraft();
  }

  void _showExportError([String message = 'Could not add annotated image']) {
    if (!mounted) return;
    final messenger =
        _snackKey.currentState ?? ScaffoldMessenger.maybeOf(context);
    if (messenger != null) {
      messenger.showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
      return;
    }
    // Dialog routes sometimes sit above the root messenger — show in-dialog.
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Uint8List _pngBytes(ByteData data) =>
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);

  Future<Uint8List?> _captureViaBoundary() async {
    final imageBoundary =
        _captureImageKeys[_index].currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    final annotBoundary =
        _captureAnnotKeys[_index].currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (imageBoundary == null ||
        annotBoundary == null ||
        !imageBoundary.hasSize ||
        !annotBoundary.hasSize ||
        imageBoundary.size.isEmpty ||
        annotBoundary.size.isEmpty) {
      return null;
    }
    final dpr = MediaQuery.devicePixelRatioOf(context).clamp(1.0, 2.5);
    // Wait until the layers are painted; toImage throws if still dirty.
    for (var i = 0; i < 3; i++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return null;
      if (!imageBoundary.debugNeedsPaint && !annotBoundary.debugNeedsPaint) {
        break;
      }
    }
    final image = await imageBoundary.toImage(pixelRatio: dpr);
    final annot = await annotBoundary.toImage(pixelRatio: dpr);
    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImage(
        image,
        Offset.zero,
        Paint()..filterQuality = ui.FilterQuality.none,
      );
      canvas.drawImage(annot, Offset.zero, Paint());
      final picture = recorder.endRecording();
      final out = await picture.toImage(image.width, image.height);
      picture.dispose();
      try {
        final byteData = await out.toByteData(format: ui.ImageByteFormat.png);
        if (byteData == null) return null;
        return _pngBytes(byteData);
      } finally {
        out.dispose();
      }
    } finally {
      image.dispose();
      annot.dispose();
    }
  }

  Future<ui.Image> _decodeNetworkImage(String url) async {
    final completer = Completer<ui.Image>();
    final stream = NetworkImage(url).resolve(const ImageConfiguration());
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        stream.removeListener(listener);
        completer.complete(info.image.clone());
      },
      onError: (error, stack) {
        stream.removeListener(listener);
        completer.completeError(error, stack);
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  Future<Uint8List?> _captureViaComposite() async {
    final box = _captureImageKeys[_index].currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize || box.size.isEmpty) return null;

    final displaySize = box.size;
    final src = await _decodeNetworkImage(_url);
    try {
      final scaleX = src.width / displaySize.width;
      final scaleY = src.height / displaySize.height;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      paintImage(
        canvas: canvas,
        rect: Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
        image: src,
        fit: BoxFit.fill,
        filterQuality: FilterQuality.medium,
      );
      canvas.save();
      canvas.scale(scaleX, scaleY);
      for (final mark in _currentMarks) {
        mark.paint(canvas);
      }
      canvas.restore();

      final picture = recorder.endRecording();
      final out = await picture.toImage(src.width, src.height);
      picture.dispose();
      try {
        final byteData = await out.toByteData(format: ui.ImageByteFormat.png);
        if (byteData == null) return null;
        return _pngBytes(byteData);
      } finally {
        out.dispose();
      }
    } finally {
      src.dispose();
    }
  }

  Future<void> _addAnnotatedToMessage() async {
    if (!_canAddToMessage) {
      if (!composerMediaAttachAvailable) {
        _showExportError('Composer is not ready — open a chat and try again');
      }
      return;
    }
    setState(() => _exporting = true);
    try {
      if (_draft != null) {
        final committed = _draft!.commit();
        if (committed != null) {
          _currentMarks.add(committed);
          _hasCommittedMarks = true;
          _rebuildMarkPicture(_index);
        }
        _draft = null;
        _bumpDraft();
      }
      _transforms[_index].value = Matrix4.identity();
      if (_zoomed) {
        setState(() => _zoomed = false);
      } else {
        setState(() {});
      }
      await WidgetsBinding.instance.endOfFrame;

      Uint8List? bytes;
      try {
        bytes = await _captureViaBoundary();
      } catch (_) {
        bytes = null;
      }
      if (bytes == null || bytes.isEmpty) {
        bytes = await _captureViaComposite();
      }
      if (bytes == null || bytes.isEmpty || !mounted) {
        _showExportError();
        return;
      }

      final base = _downloadName.contains('.')
          ? _downloadName.replaceFirst(RegExp(r'\.[^.]+$'), '')
          : _downloadName;
      if (!composerMediaAttachAvailable) {
        _showExportError('Composer is not ready — open a chat and try again');
        return;
      }
      attachMediaToComposer(
        PickedBytes(
          bytes: bytes,
          filename: '${base}_annotated.png',
          mimeType: 'image/png',
        ),
      );
      if (mounted) _close();
    } catch (_) {
      _showExportError();
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      if (_annotateMode) {
        _setAnnotateMode(false);
      } else {
        _close();
      }
      return KeyEventResult.handled;
    }
    if (_drawingLocked) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.arrowLeft) {
      _go(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _go(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.equal ||
        key == LogicalKeyboardKey.numpadAdd ||
        key == LogicalKeyboardKey.add) {
      _zoomBy(_zoomStep);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.minus ||
        key == LogicalKeyboardKey.numpadSubtract) {
      _zoomBy(-_zoomStep);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Crosshair layer. Drawn on a full-size, self-contained [RepaintBoundary]
  /// instead of a `Positioned` widget: relocating a `Positioned` re-lays-out
  /// the parent `Stack` and bubbles the paint invalidation up to the nearest
  /// ancestor boundary (the whole dialog surface here). On single-context
  /// CanvasKit (Chrome) that re-composited the app on every pointer move —
  /// Firefox's multi-context rendering hid the same cost.
  Widget _toolCursor() {
    final pos = _cursorLocal;
    if (!_annotateMode || !_cursorOver || pos == null) {
      return const SizedBox.shrink();
    }
    return RepaintBoundary(
      child: IgnorePointer(
        child: CustomPaint(
          painter: _CursorOverlayPainter(position: pos, color: _ink),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }

  Widget _buildImagePage(int i) {
    final marks = _marks[i];
    return Stack(
      fit: StackFit.expand,
      children: [
        // Full-page hit target. For small images the picture above does not
        // cover the whole viewport, so a tap on the black backdrop closes.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: (_zoomed || _annotateMode) ? null : _close,
          child: const SizedBox.expand(),
        ),
        Center(
          child: GestureDetector(
            // A tap closes the viewer, a double tap zooms. For large images
            // the picture layer covers the whole viewport, so this detector is
            // the one that actually receives taps — without it nothing would
            // dismiss the viewer except the corner buttons.
            onTap: (_zoomed || _annotateMode) ? null : _close,
            onDoubleTapDown: _annotateMode ? null : _toggleZoom,
            onDoubleTap: _annotateMode ? null : () {},
            // Zoomed-in images can be panned — show an open hand, and a
            // clenched hand while the mouse button is held to drag.
            child: MouseRegion(
              cursor: _zoomed
                  ? (_grabDragging
                        ? SystemMouseCursors.grabbing
                        : SystemMouseCursors.grab)
                  : SystemMouseCursors.basic,
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (event) {
                  // Right-click on the enlarged image: Copy image / Download.
                  if (event.buttons == kSecondaryMouseButton) {
                    handleImageContextMenu(
                      context,
                      url: _url,
                      filename: _downloadName,
                      globalPosition: event.position,
                      // Confirm inside the lightbox, not behind it.
                      messengerKey: _snackKey,
                    );
                  }
                  if (event.buttons & kPrimaryMouseButton != 0 &&
                      !_grabDragging) {
                    setState(() => _grabDragging = true);
                  }
                },
                onPointerUp: (event) {
                  if (_grabDragging) setState(() => _grabDragging = false);
                },
                onPointerCancel: (event) {
                  if (_grabDragging) setState(() => _grabDragging = false);
                },
                child: InteractiveViewer(
                  transformationController: _transforms[i],
                  minScale: _minScale,
                  maxScale: _maxScale,
                  panEnabled: !_annotateMode,
                  scaleEnabled: !_annotateMode,
                  clipBehavior: Clip.none,
                  onInteractionUpdate: (_) => _syncZoomed(),
                  onInteractionEnd: (_) => _syncZoomed(),
                  child: Stack(
                    fit: StackFit.passthrough,
                    children: [
                      // Image lives in its own repaint boundary so draw ticks (which
                      // only touch the annotation overlay) never re-rasterize it —
                      // on web that re-render of a large image was the freezing.
                      RepaintBoundary(
                        key: _captureImageKeys[i],
                        // Renders from the on-device cache when the image is already
                        // local (instant open, no download); otherwise loads over the
                        // network and warms the cache in the background.
                        child: CachedMediaImage(
                          url: widget.urls[i],
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                          // Keep full-res bytes in the local copy cache while the
                          // image is on screen — "Copy image" never re-downloads.
                          frameBuilder: (context, child, frame, sync) {
                            if (frame != null) {
                              unawaited(prefetchImageForCopy(widget.urls[i]));
                            }
                            return child;
                          },
                          errorBuilder: (_, error, stack) => Padding(
                            padding: const EdgeInsets.all(32),
                            child: Text(
                              'Image unavailable',
                              style: TextStyle(color: PrivetTheme.mist),
                            ),
                          ),
                        ),
                      ),
                      Positioned.fill(
                        child: IgnorePointer(
                          ignoring: !_annotateMode,
                          child: MouseRegion(
                            cursor: SystemMouseCursors.none,
                            onEnter: (_) => setPrivetAnnotHover(true),
                            onHover: (event) {
                              setPrivetAnnotHover(true);
                              _cursorLocal = event.localPosition;
                              _cursorOver = true;
                              // While drawing, onPanUpdate already tracks the pen —
                              // skip the redundant hover tick (Chrome fires hover for
                              // every pixel during a drag, doubling repaint rate).
                              if (_draft == null) _bumpCursor();
                            },
                            onExit: (_) {
                              setPrivetAnnotHover(false);
                              _cursorOver = false;
                              _cursorLocal = null;
                              _bumpCursor();
                            },
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onPanStart: (details) =>
                                  _onDrawStart(i, details.localPosition),
                              onPanUpdate: (details) =>
                                  _onDrawUpdate(i, details.localPosition),
                              onPanEnd: (_) => _onDrawEnd(i),
                              onPanCancel: () {
                                _draft = null;
                                _bumpDraft();
                              },
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  // Marks + in-progress stroke repaint in their own
                                  // small boundary — the image above stays cached.
                                  RepaintBoundary(
                                    key: _captureAnnotKeys[i],
                                    child: ValueListenableBuilder<int>(
                                      valueListenable: _draftTick,
                                      builder: (context, _, child) {
                                        final draft = i == _index
                                            ? _draft
                                            : null;
                                        return CustomPaint(
                                          painter: ImageAnnotationPainter(
                                            marks: marks,
                                            draft: draft,
                                            cachedPicture: _markPictures[i],
                                          ),
                                          child: const SizedBox.expand(),
                                        );
                                      },
                                    ),
                                  ),
                                  if (i == _index)
                                    ValueListenableBuilder<int>(
                                      valueListenable: _cursorTick,
                                      builder: (context, _, child) =>
                                          _toolCursor(),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _addToMessageButton() {
    return MouseRegion(
      cursor: _canAddToMessage
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setPrivetAnnotHover(false),
      child: Material(
        color: _canAddToMessage
            ? PrivetTheme.signal.withValues(alpha: 0.95)
            : Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          mouseCursor: _canAddToMessage
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onTap: _canAddToMessage ? _addAnnotatedToMessage : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_exporting)
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: PrivetTheme.onAccent,
                    ),
                  )
                else
                  Icon(
                    Icons.add_photo_alternate_outlined,
                    size: 20,
                    color: _canAddToMessage
                        ? PrivetTheme.onAccent
                        : PrivetTheme.paper.withValues(alpha: 0.4),
                  ),
                const SizedBox(width: 8),
                Text(
                  'Add to message',
                  style: TextStyle(
                    color: _canAddToMessage
                        ? PrivetTheme.onAccent
                        : PrivetTheme.paper.withValues(alpha: 0.4),
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _annotateToolbar() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_hasMarks) ...[_addToMessageButton(), const SizedBox(height: 10)],
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(28),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ChromeIconButton(
                tooltip: 'Pencil',
                icon: Icons.edit_rounded,
                active: _tool == ImageAnnotTool.pencil,
                onPressed: () => _selectTool(ImageAnnotTool.pencil),
              ),
              const SizedBox(width: 6),
              _ChromeIconButton(
                tooltip: 'Rectangle',
                icon: Icons.crop_square_rounded,
                active: _tool == ImageAnnotTool.rect,
                onPressed: () => _selectTool(ImageAnnotTool.rect),
              ),
              const SizedBox(width: 6),
              _ChromeIconButton(
                tooltip: 'Arrow',
                icon: Icons.north_east_rounded,
                active: _tool == ImageAnnotTool.arrow,
                onPressed: () => _selectTool(ImageAnnotTool.arrow),
              ),
              const SizedBox(width: 10),
              _InkSwatchButton(color: _ink, onPressed: _cycleInk),
              const SizedBox(width: 6),
              _ChromeIconButton(
                tooltip: 'Undo',
                icon: Icons.undo_rounded,
                onPressed: _currentMarks.isEmpty ? null : _undo,
              ),
              const SizedBox(width: 6),
              _ChromeIconButton(
                tooltip: 'Clear',
                icon: Icons.delete_outline_rounded,
                onPressed: (_currentMarks.isEmpty && _draft == null)
                    ? null
                    : _clearMarks,
              ),
              const SizedBox(width: 10),
              _ChromeIconButton(
                tooltip: 'Done',
                icon: Icons.check_rounded,
                active: true,
                onPressed: () => _setAnnotateMode(false),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _viewToolbar({required bool canPrev, required bool canNext}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_hasMarks) ...[_addToMessageButton(), const SizedBox(height: 10)],
        if (canPrev || canNext)
          Row(
            children: [
              if (canPrev)
                _ChromeIconButton(
                  tooltip: 'Previous',
                  icon: Icons.chevron_left_rounded,
                  onPressed: () => _go(-1),
                )
              else
                const SizedBox(width: 44),
              const Spacer(),
              if (canNext)
                _ChromeIconButton(
                  tooltip: 'Next',
                  icon: Icons.chevron_right_rounded,
                  onPressed: () => _go(1),
                )
              else
                const SizedBox(width: 44),
            ],
          ),
        if (canPrev || canNext) const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _ChromeIconButton(
              tooltip: 'Zoom out',
              icon: Icons.remove_rounded,
              onPressed: () => _zoomBy(-_zoomStep),
            ),
            const SizedBox(width: 8),
            _ChromeIconButton(
              tooltip: 'Zoom in',
              icon: Icons.add_rounded,
              onPressed: () => _zoomBy(_zoomStep),
            ),
            const SizedBox(width: 8),
            _ChromeIconButton(
              tooltip: 'Annotate',
              icon: Icons.draw_rounded,
              onPressed: () => _setAnnotateMode(true),
            ),
            const SizedBox(width: 8),
            _ChromeIconButton(
              tooltip: 'Download',
              icon: Icons.download_rounded,
              onPressed: _downloadCurrent,
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final canPrev = _gallery && !_zoomed && !_annotateMode && _index > 0;
    final canNext =
        _gallery &&
        !_zoomed &&
        !_annotateMode &&
        _index < widget.urls.length - 1;

    return ScaffoldMessenger(
      key: _snackKey,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Focus(
          autofocus: true,
          onKeyEvent: _onKey,
          child: Material(
            type: MaterialType.transparency,
            child: Stack(
              fit: StackFit.expand,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: (_zoomed || _annotateMode) ? null : _close,
                  child: const SizedBox.expand(),
                ),
                PageView.builder(
                  controller: _pageController,
                  itemCount: widget.urls.length,
                  physics: (_zoomed || _annotateMode)
                      ? const NeverScrollableScrollPhysics()
                      : const PageScrollPhysics(),
                  onPageChanged: _onPageChanged,
                  itemBuilder: (context, i) => _buildImagePage(i),
                ),
                // Chrome overlays only — middle stays pass-through so drawing and
                // tool buttons are not fighting a full-screen hit target.
                SafeArea(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                      child: MouseRegion(
                        onEnter: (_) => setPrivetAnnotHover(false),
                        child: Row(
                          children: [
                            if (_gallery)
                              Padding(
                                padding: const EdgeInsets.only(left: 8),
                                child: Text(
                                  '${_index + 1} / ${widget.urls.length}',
                                  style: TextStyle(
                                    color: PrivetTheme.paper.withValues(
                                      alpha: 0.85,
                                    ),
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            if (_annotateMode)
                              Padding(
                                padding: EdgeInsets.only(
                                  left: _gallery ? 12 : 8,
                                ),
                                child: Text(
                                  'Draw on image',
                                  style: TextStyle(
                                    color: PrivetTheme.paper.withValues(
                                      alpha: 0.7,
                                    ),
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            const Spacer(),
                            _ChromeIconButton(
                              tooltip: 'Close',
                              icon: Icons.close_rounded,
                              onPressed: _close,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                SafeArea(
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      child: MouseRegion(
                        onEnter: (_) => setPrivetAnnotHover(false),
                        child: _annotateMode
                            ? _annotateToolbar()
                            : _viewToolbar(canPrev: canPrev, canNext: canNext),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChromeIconButton extends StatelessWidget {
  const _ChromeIconButton({
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.active = false,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String tooltip;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final bg = active
        ? PrivetTheme.signal.withValues(alpha: 0.92)
        : Colors.black.withValues(alpha: enabled ? 0.45 : 0.25);
    final fg = active
        ? PrivetTheme.onAccent
        : PrivetTheme.paper.withValues(alpha: enabled ? 1 : 0.35);
    return Material(
      color: bg,
      shape: const CircleBorder(),
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        mouseCursor: enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        icon: Icon(icon, color: fg),
      ),
    );
  }
}

/// Flameshot-style centered "+" crosshair (same for every draw tool). Drawn on
/// a full-size overlay so pointer moves only repaint this small boundary — a
/// `Positioned` cursor would relayout the parent `Stack` and bubble paint
/// invalidations all the way up to the nearest ancestor RepaintBoundary.
class _CursorOverlayPainter extends CustomPainter {
  _CursorOverlayPainter({required this.position, required this.color});

  final Offset position;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const arm = 12.8; // 32px crosshair, same proportions as the old 32x32 box.
    void stroke(Paint paint) {
      canvas.drawLine(
        Offset(position.dx - arm, position.dy),
        Offset(position.dx + arm, position.dy),
        paint,
      );
      canvas.drawLine(
        Offset(position.dx, position.dy - arm),
        Offset(position.dx, position.dy + arm),
        paint,
      );
    }

    stroke(
      Paint()
        ..color = Colors.black.withValues(alpha: 0.75)
        ..strokeWidth = 3.2
        ..strokeCap = StrokeCap.square
        ..isAntiAlias = true,
    );
    stroke(
      Paint()
        ..color = color
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.square
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(covariant _CursorOverlayPainter oldDelegate) =>
      oldDelegate.position != position || oldDelegate.color != color;
}

class _InkSwatchButton extends StatelessWidget {
  const _InkSwatchButton({required this.color, required this.onPressed});

  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.45),
      shape: const CircleBorder(),
      child: IconButton(
        tooltip: 'Color',
        onPressed: onPressed,
        mouseCursor: SystemMouseCursors.click,
        icon: Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: PrivetTheme.paper.withValues(alpha: 0.9),
              width: 2,
            ),
          ),
        ),
      ),
    );
  }
}
