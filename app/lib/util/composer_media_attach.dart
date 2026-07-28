import '../util/clipboard_files.dart';

/// Bound by [ConversationPane] so the image lightbox can stage annotated
/// images into the active composer without threading callbacks through bubbles.
typedef ComposerMediaAttachFn = void Function(PickedBytes file);

ComposerMediaAttachFn? _composerMediaAttach;

void registerComposerMediaAttach(ComposerMediaAttachFn? handler) {
  _composerMediaAttach = handler;
}

bool get composerMediaAttachAvailable => _composerMediaAttach != null;

void attachMediaToComposer(PickedBytes file) {
  _composerMediaAttach?.call(file);
}
