import 'shared_intent.dart';

/// Non-Android platforms never appear in a share sheet, so there is nothing
/// to poll.
Future<List<SharedDraft>> takePendingShares() async => const [];
