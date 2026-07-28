import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import '../util/clipboard_files.dart';
import '../util/composer_media_attach.dart';
import '../util/low_resource.dart';
import '../util/media_download.dart';
import '../util/web_select_cursor.dart';
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

  late final PageController _pageController;
  late final List<TransformationController> _transforms;
  late final List<List<ImageMark>> _marks;
  late final List<GlobalKey> _captureKeys;
  late int _index;
  bool _zoomed = false;

  bool _annotateMode = false;
  ImageAnnotTool _tool = ImageAnnotTool.pencil;
  int _inkIndex = 0;
  ImageMarkDraft? _draft;
  Offset? _cursorLocal;
  bool _cursorOver = false;
  bool _exporting = false;

  bool get _gallery => widget.urls.length > 1;

  String get _url => widget.urls[_index];

  Color get _ink => kAnnotationInks[_inkIndex];

  List<ImageMark> get _currentMarks => _marks[_index];

  bool get _drawingLocked => _annotateMode;

  bool get _hasMarks => _currentMarks.isNotEmpty || _draft != null;

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
    _captureKeys = List.generate(widget.urls.length, (_) => GlobalKey());
  }

  @override
  void dispose() {
    setPrivetAnnotHover(false);
    _pageController.dispose();
    for (final t in _transforms) {
      t.dispose();
    }
    super.dispose();
  }

  void _close() => Navigator.of(context).maybePop();

  void _onPageChanged(int page) {
    _transforms[_index].value = Matrix4.identity();
    setState(() {
      _index = page;
      _zoomed = false;
      _draft = null;
      _cursorLocal = null;
      _cursorOver = false;
    });
  }

  void _syncZoomed() {
    final scale = _transforms[_index].value.getMaxScaleOnAxis();
    final next = scale > 1.05;
    if (next != _zoomed) setState(() => _zoomed = next);
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
    setPrivetAnnotHover(on);
    setState(() {
      _annotateMode = on;
      _draft = null;
      _cursorLocal = null;
      _cursorOver = false;
      if (on) {
        _transforms[_index].value = Matrix4.identity();
        _zoomed = false;
      }
    });
  }

  void _selectTool(ImageAnnotTool tool) {
    setPrivetAnnotHover(true);
    setState(() {
      _annotateMode = true;
      _tool = tool;
      _draft = null;
      _transforms[_index].value = Matrix4.identity();
      _zoomed = false;
    });
  }

  void _cycleInk() {
    setState(() => _inkIndex = (_inkIndex + 1) % kAnnotationInks.length);
  }

  void _undo() {
    if (_currentMarks.isEmpty) return;
    setState(() {
      _currentMarks.removeLast();
      _draft = null;
    });
  }

  void _clearMarks() {
    if (_currentMarks.isEmpty && _draft == null) return;
    setState(() {
      _currentMarks.clear();
      _draft = null;
    });
  }

  double get _strokeWidth {
    final side = MediaQuery.sizeOf(context).shortestSide;
    return annotationStrokeWidth(Size(side, side));
  }

  void _onDrawStart(int page, Offset local) {
    if (!_annotateMode || page != _index) return;
    setState(() {
      _cursorLocal = local;
      _cursorOver = true;
      _draft = ImageMarkDraft(
        tool: _tool,
        start: local,
        color: _ink,
        strokeWidth: _strokeWidth,
      );
    });
  }

  void _onDrawUpdate(int page, Offset local) {
    if (_draft == null || page != _index) return;
    setState(() {
      _cursorLocal = local;
      _draft!.update(local);
    });
  }

  void _onDrawEnd(int page) {
    if (_draft == null || page != _index) return;
    final committed = _draft!.commit();
    setState(() {
      if (committed != null) _marks[page].add(committed);
      _draft = null;
    });
  }

  Future<void> _addAnnotatedToMessage() async {
    if (!_canAddToMessage) return;
    setState(() => _exporting = true);
    try {
      if (_draft != null) {
        final committed = _draft!.commit();
        if (committed != null) _currentMarks.add(committed);
        _draft = null;
      }
      _transforms[_index].value = Matrix4.identity();
      _zoomed = false;
      setState(() {});
      await WidgetsBinding.instance.endOfFrame;

      final boundary = _captureKeys[_index].currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null || !mounted) return;

      final dpr = MediaQuery.devicePixelRatioOf(context).clamp(1.0, 3.0);
      final image = await boundary.toImage(pixelRatio: dpr);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (byteData == null || !mounted) return;

      final base = _downloadName.contains('.')
          ? _downloadName.replaceFirst(RegExp(r'\.[^.]+$'), '')
          : _downloadName;
      attachMediaToComposer(
        PickedBytes(
          bytes: byteData.buffer.asUint8List(),
          filename: '${base}_annotated.png',
          mimeType: 'image/png',
        ),
      );
      if (mounted) _close();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('Could not add annotated image'),
          behavior: SnackBarBehavior.floating,
        ),
      );
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

  Widget _toolCursor() {
    final pos = _cursorLocal;
    if (!_annotateMode || !_cursorOver || pos == null) {
      return const SizedBox.shrink();
    }
    const size = 32.0;
    return Positioned(
      left: pos.dx - size / 2,
      top: pos.dy - size / 2,
      width: size,
      height: size,
      child: IgnorePointer(
        child: CustomPaint(
          painter: _PlusCursorPainter(color: _ink),
        ),
      ),
    );
  }

  Widget _buildImagePage(int i) {
    final marks = _marks[i];
    final draft = i == _index ? _draft : null;
    return Center(
      child: GestureDetector(
        onTap: () {
          if (!_zoomed && !_annotateMode) _close();
        },
        onDoubleTapDown: _annotateMode ? null : _toggleZoom,
        onDoubleTap: _annotateMode ? null : () {},
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
              RepaintBoundary(
                key: _captureKeys[i],
                child: Stack(
                  fit: StackFit.passthrough,
                  children: [
                    Image.network(
                      widget.urls[i],
                      fit: BoxFit.contain,
                      errorBuilder: (_, error, stack) => Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          'Image unavailable',
                          style: TextStyle(color: PrivetTheme.mist),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: CustomPaint(
                        painter: ImageAnnotationPainter(
                          marks: marks,
                          draft: draft,
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ],
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: !_annotateMode,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.none,
                    onHover: (event) {
                      setState(() {
                        _cursorLocal = event.localPosition;
                        _cursorOver = true;
                      });
                    },
                    onExit: (_) {
                      setState(() {
                        _cursorOver = false;
                        _cursorLocal = null;
                      });
                    },
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: (details) =>
                          _onDrawStart(i, details.localPosition),
                      onPanUpdate: (details) =>
                          _onDrawUpdate(i, details.localPosition),
                      onPanEnd: (_) => _onDrawEnd(i),
                      onPanCancel: () => setState(() => _draft = null),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          const SizedBox.expand(),
                          if (i == _index) _toolCursor(),
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
    );
  }

  Widget _addToMessageButton() {
    return Material(
      color: _canAddToMessage
          ? PrivetTheme.signal.withValues(alpha: 0.95)
          : Colors.black.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
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
    );
  }

  Widget _annotateToolbar() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_hasMarks) ...[
          _addToMessageButton(),
          const SizedBox(height: 10),
        ],
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
              _InkSwatchButton(
                color: _ink,
                onPressed: _cycleInk,
              ),
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
        if (_hasMarks) ...[
          _addToMessageButton(),
          const SizedBox(height: 10),
        ],
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
              onPressed: () => downloadMedia(
                _url,
                filename: _downloadName,
              ),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final canPrev = _gallery && !_zoomed && !_annotateMode && _index > 0;
    final canNext = _gallery &&
        !_zoomed &&
        !_annotateMode &&
        _index < widget.urls.length - 1;

    return Focus(
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
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                child: Column(
                  children: [
                    Row(
                      children: [
                        if (_gallery)
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Text(
                              '${_index + 1} / ${widget.urls.length}',
                              style: TextStyle(
                                color:
                                    PrivetTheme.paper.withValues(alpha: 0.85),
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
                                color:
                                    PrivetTheme.paper.withValues(alpha: 0.7),
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
                    const Spacer(),
                    if (_annotateMode)
                      _annotateToolbar()
                    else
                      _viewToolbar(canPrev: canPrev, canNext: canNext),
                  ],
                ),
              ),
            ),
          ],
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
        icon: Icon(icon, color: fg),
      ),
    );
  }
}

/// Flameshot-style centered "+" crosshair (same for every draw tool).
class _PlusCursorPainter extends CustomPainter {
  _PlusCursorPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final arm = size.shortestSide * 0.4;
    void stroke(Paint paint) {
      canvas.drawLine(Offset(c.dx - arm, c.dy), Offset(c.dx + arm, c.dy), paint);
      canvas.drawLine(Offset(c.dx, c.dy - arm), Offset(c.dx, c.dy + arm), paint);
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
  bool shouldRepaint(covariant _PlusCursorPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _InkSwatchButton extends StatelessWidget {
  const _InkSwatchButton({
    required this.color,
    required this.onPressed,
  });

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
