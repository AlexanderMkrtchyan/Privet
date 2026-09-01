import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../util/copy_image.dart';
import '../util/media_cache.dart';

/// Renders [url] straight from the on-device media cache when the bytes are
/// already local — the click-to-open path for already-seen media is instant
/// with no server round-trip. Otherwise it loads over the network as usual and
/// warms the persistent cache in the background (via the copy-image prefetch,
/// so there is no extra download) for the next open.
class CachedMediaImage extends StatefulWidget {
  const CachedMediaImage({
    super.key,
    required this.url,
    this.fit = BoxFit.contain,
    this.gaplessPlayback = true,
    this.frameBuilder,
    this.errorBuilder,
    this.width,
    this.height,
    this.cacheWidth,
    this.cacheHeight,
    this.placeholderHeight,
  });

  final String url;
  final BoxFit fit;
  final bool gaplessPlayback;

  /// Passed through to the underlying image. While the widget is on the
  /// network path this runs after the cache-warm hook; on the cached
  /// [Image.memory] path it is passed straight through.
  final ImageFrameBuilder? frameBuilder;
  final ImageErrorWidgetBuilder? errorBuilder;
  final double? width;
  final double? height;
  final int? cacheWidth;
  final int? cacheHeight;

  /// Fallback height while the cache lookup is in flight for widgets that
  /// size to their natural aspect once decoded (single chat images).
  final double? placeholderHeight;

  @override
  State<CachedMediaImage> createState() => _CachedMediaImageState();
}

class _CachedMediaImageState extends State<CachedMediaImage> {
  Uint8List? _bytes;
  bool _cacheResolved = false;

  @override
  void initState() {
    super.initState();
    _lookup();
  }

  @override
  void didUpdateWidget(covariant CachedMediaImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _bytes = null;
      _cacheResolved = false;
      _lookup();
    }
  }

  Future<void> _lookup() async {
    final url = widget.url;
    final syncBytes = mediaCacheLookupSync(url);
    if (syncBytes != null) {
      // Runs synchronously inside initState/didUpdateWidget, so assign the
      // fields directly — the framework builds right after and sees them.
      _bytes = syncBytes;
      _cacheResolved = true;
      return;
    }
    final found = await mediaCacheGet(url);
    if (!mounted || url != widget.url) return;
    setState(() {
      _bytes = found;
      _cacheResolved = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes != null) {
      return Image.memory(
        bytes,
        fit: widget.fit,
        gaplessPlayback: widget.gaplessPlayback,
        width: widget.width,
        height: widget.height,
        cacheWidth: widget.cacheWidth,
        cacheHeight: widget.cacheHeight,
        frameBuilder: widget.frameBuilder,
        errorBuilder: widget.errorBuilder,
      );
    }
    if (!_cacheResolved) {
      // Cache lookup still in flight — hold the layout without firing a
      // network request. The local read resolves in milliseconds, so this is
      // at most a frame or two before the cached bytes render.
      return SizedBox(
        width: widget.width,
        height: widget.height ?? widget.placeholderHeight,
      );
    }
    return Image.network(
      widget.url,
      fit: widget.fit,
      gaplessPlayback: widget.gaplessPlayback,
      width: widget.width,
      height: widget.height,
      cacheWidth: widget.cacheWidth,
      cacheHeight: widget.cacheHeight,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        // First decoded frame → the full-res bytes are local; write them into
        // the persistent cache so the next open needs no download. prefetch
        // dedupes parallel requests and also feeds the copy-image path.
        if (frame != null) {
          unawaited(prefetchImageForCopy(widget.url));
        }
        return widget.frameBuilder == null
            ? child
            : widget.frameBuilder!(
                context, child, frame, wasSynchronouslyLoaded);
      },
      errorBuilder: widget.errorBuilder,
    );
  }
}
