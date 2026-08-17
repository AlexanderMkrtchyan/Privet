import 'clipboard_files.dart';
import 'shared_intent_stub.dart'
    if (dart.library.html) 'shared_intent_stub.dart'
    if (dart.library.io) 'shared_intent_io.dart' as impl;

/// Content received from another app's Android share sheet. A single share
/// action maps to a single draft so the composer can stage it for review
/// before sending: either [text] (optionally with a [subject]) or [files],
/// or both (e.g. a photo shared with a caption).
class SharedDraft {
  SharedDraft({this.text, this.subject, List<PickedBytes>? files})
      : files = files ?? const [];

  final String? text;
  final String? subject;
  final List<PickedBytes> files;

  bool get isEmpty => (text == null || text!.trim().isEmpty) && files.isEmpty;
}

/// Poll the native side for share-sheet payloads delivered since the last
/// poll. Returns an empty list when none are pending. Android only; on other
/// platforms this is a no-op.
Future<List<SharedDraft>> takePendingShares() => impl.takePendingShares();
