import '../util/clipboard_files.dart';

/// Bound by [ConversationPane] so the image lightbox can stage annotated
/// images into the active composer without threading callbacks through bubbles.
typedef ComposerMediaAttachFn = void Function(PickedBytes file);

/// Bound by [ConversationPane] so OS-shared text ("share" → Privet → chat)
/// can be staged into the active composer. [subject] is the share-sheet
/// subject line, shown above the shared body when present.
typedef ComposerTextAttachFn = void Function(String text, {String? subject});

ComposerMediaAttachFn? _composerMediaAttach;
int _composerMediaAttachId = 0;
ComposerTextAttachFn? _composerTextAttach;
int _composerTextAttachId = 0;

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

/// Register the active composer text-attach hook (see [ComposerTextAttachFn]).
int registerComposerTextAttach(ComposerTextAttachFn handler) {
  final id = ++_composerTextAttachId;
  _composerTextAttach = handler;
  return id;
}

void unregisterComposerTextAttach([int? id]) {
  if (id != null && id != _composerTextAttachId) return;
  _composerTextAttach = null;
}

bool get composerTextAttachAvailable => _composerTextAttach != null;

void attachTextToComposer(String text, {String? subject}) {
  _composerTextAttach?.call(text, subject: subject);
}
