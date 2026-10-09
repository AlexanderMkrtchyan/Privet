import 'package:flutter_test/flutter_test.dart';
import 'package:privet/models.dart';

TaskItem _task({
  required String id,
  required String status,
  String? parentId,
}) {
  return TaskItem(
    id: id,
    conversationId: 'c',
    body: id,
    status: status,
    priority: 'medium',
    sortOrder: 0,
    createdAt: DateTime.utc(2026, 1, 1),
    parentId: parentId,
  );
}

void main() {
  test('fully checked tasks wait for review; open ones stay on the list', () {
    final board = ConversationTasks(items: [
      _task(id: 'open', status: 'in_progress'),
      _task(id: 'open-sub', status: 'todo', parentId: 'open'),
      _task(id: 'open-sub-2', status: 'review', parentId: 'open'),
      _task(id: 'ready', status: 'in_progress'),
      _task(id: 'ready-sub', status: 'review', parentId: 'ready'),
      _task(id: 'ready-sub-2', status: 'done', parentId: 'ready'),
      _task(id: 'solo', status: 'review'),
      _task(id: 'still', status: 'todo'),
      _task(id: 'closed', status: 'done'),
    ]);

    expect(
      board.awaitingReviewItems.map((t) => t.id).toList(),
      ['ready', 'solo'],
    );
  });
}
