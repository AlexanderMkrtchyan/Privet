import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import '../util/low_resource.dart';
import '../util/media_download.dart';

/// Full-screen messenger-style image viewer: tap backdrop / close to dismiss,
/// pinch or buttons to zoom, optional prev/next for galleries.
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
  late int _index;
  bool _zoomed = false;

  bool get _gallery => widget.urls.length > 1;

  String get _url => widget.urls[_index];

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
  }

  @override
  void dispose() {
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
    final current = _transforms[_index].value.getMaxScaleOnAxis();
    _setScale(current + delta);
  }

  void _toggleZoom(TapDownDetails details) {
    final current = _transforms[_index].value.getMaxScaleOnAxis();
    if (current > 1.05) {
      _transforms[_index].value = Matrix4.identity();
      setState(() => _zoomed = false);
    } else {
      _setScale(2.5, focal: details.localPosition);
    }
  }

  void _go(int delta) {
    if (!_gallery || _zoomed) return;
    final next = (_index + delta).clamp(0, widget.urls.length - 1);
    if (next == _index) return;
    _pageController.animateToPage(
      next,
      duration: privetAnim(const Duration(milliseconds: 220)),
      curve: Curves.easeOutCubic,
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _close();
      return KeyEventResult.handled;
    }
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

  @override
  Widget build(BuildContext context) {
    final canPrev = _gallery && !_zoomed && _index > 0;
    final canNext = _gallery && !_zoomed && _index < widget.urls.length - 1;

    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Tap empty chrome to dismiss (only when not zoomed).
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _zoomed ? null : _close,
              child: const SizedBox.expand(),
            ),
            PageView.builder(
              controller: _pageController,
              itemCount: widget.urls.length,
              physics: _zoomed
                  ? const NeverScrollableScrollPhysics()
                  : const PageScrollPhysics(),
              onPageChanged: _onPageChanged,
              itemBuilder: (context, i) {
                return Center(
                  child: GestureDetector(
                    onTap: () {
                      if (!_zoomed) _close();
                    },
                    onDoubleTapDown: _toggleZoom,
                    onDoubleTap: () {},
                    child: InteractiveViewer(
                      transformationController: _transforms[i],
                      minScale: _minScale,
                      maxScale: _maxScale,
                      clipBehavior: Clip.none,
                      onInteractionUpdate: (_) => _syncZoomed(),
                      onInteractionEnd: (_) => _syncZoomed(),
                      child: Image.network(
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
                    ),
                  ),
                );
              },
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
                                color: PrivetTheme.paper.withValues(alpha: 0.85),
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
                    const SizedBox(height: 8),
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
    required this.onPressed,
    required this.tooltip,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.45),
      shape: const CircleBorder(),
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, color: PrivetTheme.paper),
      ),
    );
  }
}
