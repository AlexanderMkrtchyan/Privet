import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../util/clipboard_files.dart';

/// Paperclip control. On web, a body-level HTML file input is positioned over
/// this widget so Chromium keeps the real user gesture.
class WebAttachButton extends StatefulWidget {
  const WebAttachButton({
    super.key,
    required this.onPicked,
    required this.onPressedFallback,
    this.onError,
    this.tooltip = 'Attach files',
  });

  final void Function(PickedBytes file) onPicked;
  final VoidCallback onPressedFallback;
  final void Function(Object error)? onError;
  final String tooltip;

  @override
  State<WebAttachButton> createState() => _WebAttachButtonState();
}

class _WebAttachButtonState extends State<WebAttachButton> {
  final _hostKey = GlobalKey();
  int? _attachBindId;
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) return;
    ensureAttachFileInput();
    _attachBindId = setAttachHandlers(
      onPicked: widget.onPicked,
      onError: widget.onError,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void didUpdateWidget(covariant WebAttachButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (kIsWeb) {
      _attachBindId = setAttachHandlers(
        onPicked: widget.onPicked,
        onError: widget.onError,
      );
      _scheduleSync();
    }
  }

  void _scheduleSync() {
    if (!kIsWeb || _scheduled) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      _sync();
    });
  }

  void _sync() {
    if (!kIsWeb || !mounted) return;
    final ctx = _hostKey.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || !box.attached) {
      positionAttachInput(left: 0, top: 0, width: 0, height: 0, active: false);
      return;
    }
    final topLeft = box.localToGlobal(Offset.zero);
    final size = box.size;
    positionAttachInput(
      left: topLeft.dx,
      top: topLeft.dy,
      width: size.width,
      height: size.height,
      active: true,
    );
  }

  @override
  void dispose() {
    if (kIsWeb) {
      clearAttachHandlers(_attachBindId);
      positionAttachInput(left: 0, top: 0, width: 0, height: 0, active: false);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb) {
      return IconButton(
        tooltip: widget.tooltip,
        onPressed: widget.onPressedFallback,
        icon: const Icon(Icons.attach_file_rounded),
      );
    }

    // Reposition after layout without a 100ms polling timer.
    _scheduleSync();

    return SizedBox(
      key: _hostKey,
      width: 48,
      height: 48,
      child: Tooltip(
        message: widget.tooltip,
        child: const Icon(Icons.attach_file_rounded),
      ),
    );
  }
}
