import '../util/clipboard_files.dart';

/// Bound by [ConversationPane] so the image lightbox can stage annotated
/// images into the active composer without threading callbacks through bubbles.
typedef ComposerMediaAttachFn = void Function(PickedBytes file);

ComposerMediaAttachFn? _composerMediaAttach;
int _composerMediaAttachId = 0;

/// Register the active composer attach hook. Returns an id that must be passed
/// to [unregisterComposerMediaAttach] so a remounted pane's dispose cannot
/// clear the newer registration.
int registerComposerMediaAttach(ComposerMediaAttachFn handler) {
  final id = ++_composerMediaAttachId;
  _composerMediaAttach = handler;
  return id;
}

void unregisterComposerMediaAttach([int? id]) {
  if (id != null && id != _composerMediaAttachId) return;
  _composerMediaAttach = null;
}

bool get composerMediaAttachAvailable => _composerMediaAttach != null;

void attachMediaToComposer(PickedBytes file) {
  _composerMediaAttach?.call(file);
}
