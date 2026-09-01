import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../models.dart';

class ApiClient {
  ApiClient({String? baseUrl}) : baseUrl = baseUrl ?? resolveBaseUrl();

  final String baseUrl;
  String? token;

  static String resolveBaseUrl() {
    const fromEnv = String.fromEnvironment('PRIVET_API', defaultValue: '');
    if (fromEnv.isNotEmpty) return fromEnv;
    if (kIsWeb) {
      final base = Uri.base;
      // flutter run serves UI on a random port; API lives on the Node server.
      if ((base.host == 'localhost' || base.host == '127.0.0.1') &&
          base.port != 7777) {
        return 'http://127.0.0.1:7777';
      }
      return base.origin;
    }
    return 'https://messenger.banderdog.com';
  }

  Uri _u(String path) => Uri.parse('$baseUrl$path');

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Map<String, String> get _authHeaders => {
        if (token != null) 'Authorization': 'Bearer $token',
      };

  String absoluteMediaUrl(String? path) {
    if (path == null || path.isEmpty) return '';
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    return '$baseUrl$path';
  }

  Future<Map<String, dynamic>> login(String handle, String password) async {
    final res = await http.post(
      _u('/auth/login'),
      headers: _headers,
      body: jsonEncode({'handle': handle, 'password': password}),
    );
    return _decode(res);
  }

  Future<Map<String, dynamic>> register({
    required String handle,
    required String password,
    String? displayName,
  }) async {
    final res = await http.post(
      _u('/auth/register'),
      headers: _headers,
      body: jsonEncode({
        'handle': handle,
        'password': password,
        if (displayName != null && displayName.trim().isNotEmpty)
          'displayName': displayName.trim(),
      }),
    );
    return _decode(res);
  }

  Future<Map<String, dynamic>> inviteInfo(String handle) async {
    final res = await http.get(
      _u('/auth/invite/${Uri.encodeComponent(handle.trim().toLowerCase())}'),
      headers: _authHeaders,
    );
    return _decode(res);
  }

  Future<Map<String, dynamic>> quickJoin({String? inviteHandle}) async {
    final res = await http.post(
      _u('/auth/quick-join'),
      headers: _headers,
      body: jsonEncode({
        if (inviteHandle != null && inviteHandle.trim().isNotEmpty)
          'inviteHandle': inviteHandle.trim().toLowerCase(),
      }),
    );
    return _decode(res);
  }

  Future<Map<String, dynamic>> checkHandle(String handle) async {
    final res = await http.get(
      _u('/auth/check-handle').replace(
        queryParameters: {'handle': handle},
      ),
      headers: _authHeaders,
    );
    return _decode(res);
  }

  Future<PrivetUser> me() async {
    final res = await http.get(_u('/me'), headers: _authHeaders);
    final data = _decode(res);
    return PrivetUser.fromJson(data['user'] as Map<String, dynamic>);
  }

  Future<PrivetUser> updateProfile({
    String? displayName,
    String? avatarUrl,
    int? avatarHue,
    bool clearAvatar = false,
  }) async {
    final res = await http.patch(
      _u('/me'),
      headers: _headers,
      body: jsonEncode({
        if (displayName != null) 'displayName': displayName,
        if (clearAvatar)
          'avatarUrl': null
        else if (avatarUrl != null)
          'avatarUrl': avatarUrl,
        if (avatarHue != null) 'avatarHue': avatarHue,
      }),
    );
    final data = _decode(res);
    return PrivetUser.fromJson(data['user'] as Map<String, dynamic>);
  }

  Future<void> registerDeviceToken({
    required String token,
    String platform = 'android',
  }) async {
    final res = await http.post(
      _u('/devices'),
      headers: _headers,
      body: jsonEncode({'token': token, 'platform': platform}),
    );
    _decode(res);
  }

  Future<void> unregisterDeviceToken(String token) async {
    final res = await http.delete(
      _u('/devices'),
      headers: _headers,
      body: jsonEncode({'token': token}),
    );
    _decode(res);
  }

  Future<List<PrivetUser>> blockedUsers() async {
    final res = await http.get(_u('/blocks'), headers: _authHeaders);
    final data = _decode(res);
    return (data['users'] as List)
        .map((e) => PrivetUser.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<PrivetUser>> blockUser(String userId) async {
    final res = await http.post(
      _u('/blocks'),
      headers: _headers,
      body: jsonEncode({'userId': userId}),
    );
    final data = _decode(res);
    return (data['users'] as List)
        .map((e) => PrivetUser.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<PrivetUser>> unblockUser(String userId) async {
    final res = await http.delete(
      _u('/blocks/$userId'),
      headers: _authHeaders,
    );
    final data = _decode(res);
    return (data['users'] as List)
        .map((e) => PrivetUser.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<Conversation>> conversations() async {
    final res = await http.get(_u('/conversations'), headers: _authHeaders);
    final data = _decode(res);
    return (data['conversations'] as List)
        .map((e) => Conversation.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<PrivetUser>> users() async {
    final res = await http.get(_u('/users'), headers: _authHeaders);
    final data = _decode(res);
    return (data['users'] as List)
        .map((e) => PrivetUser.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<ChatMessage>> messages(
    String conversationId, {
    int limit = 40,
    String? before,
  }) async {
    final params = <String, String>{
      'limit': '$limit',
      if (before != null && before.isNotEmpty) 'before': before,
    };
    final res = await http.get(
      _u('/conversations/$conversationId/messages')
          .replace(queryParameters: params),
      headers: _authHeaders,
    );
    final data = _decode(res);
    return (data['messages'] as List)
        .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<ChatMessage>> searchInConversation(
    String conversationId,
    String query, {
    int limit = 50,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final res = await http.get(
      _u('/conversations/$conversationId/messages/search').replace(
        queryParameters: {'q': q, 'limit': '$limit'},
      ),
      headers: _authHeaders,
    );
    final data = _decode(res);
    return (data['messages'] as List)
        .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Every media item shared in the conversation's messages, newest first —
  /// the complete history for the Shared Media browser (not just loaded pages).
  Future<List<SharedMediaItem>> sharedMedia(String conversationId) async {
    final res = await http.get(
      _u('/conversations/$conversationId/media'),
      headers: _authHeaders,
    );
    final data = _decode(res);
    return (data['items'] as List)
        .map((e) => SharedMediaItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<PrivetUser>> members(String conversationId) async {
    final res = await http.get(
      _u('/conversations/$conversationId/members'),
      headers: _authHeaders,
    );
    final data = _decode(res);
    return (data['members'] as List)
        .map((e) => PrivetUser.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<PrivetUser>> addMember(String conversationId, String userId) async {
    final res = await http.post(
      _u('/conversations/$conversationId/members'),
      headers: _headers,
      body: jsonEncode({'userId': userId}),
    );
    final data = _decode(res);
    return (data['members'] as List)
        .map((e) => PrivetUser.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<PrivetUser>> removeMember(
    String conversationId,
    String userId,
  ) async {
    final res = await http.delete(
      _u('/conversations/$conversationId/members/$userId'),
      headers: _authHeaders,
    );
    final data = _decode(res);
    return (data['members'] as List)
        .map((e) => PrivetUser.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> deleteGroup(String conversationId) async {
    final res = await http.delete(
      _u('/conversations/$conversationId'),
      headers: _authHeaders,
    );
    _decode(res);
  }

  Future<void> deleteConversation(String conversationId) async {
    final res = await http.delete(
      _u('/conversations/$conversationId'),
      headers: _authHeaders,
    );
    _decode(res);
  }

  Future<void> hideConversation(String conversationId) async {
    final res = await http.post(
      _u('/conversations/$conversationId/hide'),
      headers: _headers,
      body: '{}',
    );
    _decode(res);
  }

  Future<void> setMuted(String conversationId, {required bool muted}) async {
    final res = await http.post(
      _u('/conversations/$conversationId/mute'),
      headers: _headers,
      body: jsonEncode({'muted': muted}),
    );
    _decode(res);
  }

  Future<void> setPinned(String conversationId, {required bool pinned}) async {
    final res = await http.post(
      _u('/conversations/$conversationId/pin'),
      headers: _headers,
      body: jsonEncode({'pinned': pinned}),
    );
    _decode(res);
  }

  Future<({ChatMessage message, ChatMessage? sourceMessage})> forwardMessage({
    required String conversationId,
    required String messageId,
  }) async {
    final res = await http.post(
      _u('/conversations/$conversationId/forward'),
      headers: _headers,
      body: jsonEncode({'messageId': messageId}),
    );
    final data = _decode(res);
    final message =
        ChatMessage.fromJson(data['message'] as Map<String, dynamic>);
    final sourceRaw = data['sourceMessage'] as Map<String, dynamic>?;
    final sourceMessage =
        sourceRaw == null ? null : ChatMessage.fromJson(sourceRaw);
    return (message: message, sourceMessage: sourceMessage);
  }

  Future<Map<String, dynamic>> markRead(
    String conversationId, {
    String? messageId,
    bool focused = false,
  }) async {
    final res = await http.post(
      _u('/conversations/$conversationId/read'),
      headers: _headers,
      body: jsonEncode({
        if (messageId != null) 'messageId': messageId,
        'focused': focused,
      }),
    );
    return _decode(res);
  }

  Future<SearchResults> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return SearchResults.empty();
    final res = await http.get(
      _u('/search').replace(queryParameters: {'q': q}),
      headers: _authHeaders,
    );
    return SearchResults.fromJson(_decode(res));
  }

  Future<ChatMessage> editMessage(String messageId, String body) async {
    final res = await http.patch(
      _u('/messages/$messageId'),
      headers: _headers,
      body: jsonEncode({'body': body}),
    );
    final data = _decode(res);
    return ChatMessage.fromJson(data['message'] as Map<String, dynamic>);
  }

  Future<ChatMessage> deleteMessage(String messageId) async {
    final res = await http.delete(
      _u('/messages/$messageId'),
      headers: _authHeaders,
    );
    final data = _decode(res);
    return ChatMessage.fromJson(data['message'] as Map<String, dynamic>);
  }

  Future<List<TaskItem>> tasks(String conversationId) async {
    final res = await http.get(
      _u('/conversations/$conversationId/tasks'),
      headers: _authHeaders,
    );
    final data = _decode(res);
    return (data['items'] as List)
        .map((e) => TaskItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<({List<TaskItem> items, bool hasMore})> taskHistory(
    String conversationId, {
    int limit = 20,
    String? before,
  }) async {
    final q = <String>['limit=$limit'];
    if (before != null && before.isNotEmpty) {
      q.add('before=${Uri.encodeComponent(before)}');
    }
    final res = await http.get(
      _u('/conversations/$conversationId/tasks/history?${q.join('&')}'),
      headers: _authHeaders,
    );
    final data = _decode(res);
    final items = (data['items'] as List)
        .map((e) => TaskItem.fromJson(e as Map<String, dynamic>))
        .toList();
    return (items: items, hasMore: data['hasMore'] == true);
  }

  Future<List<TaskItem>> createTask({
    required String conversationId,
    required String body,
    String? messageId,
    String? mediaUrl,
    String? mimeType,
    String? fileName,
    List<Map<String, dynamic>>? attachments,
    String? assignedTo,
    String? parentId,
    String status = 'todo',
    String priority = 'medium',
  }) async {
    final res = await http.post(
      _u('/conversations/$conversationId/tasks'),
      headers: _headers,
      body: jsonEncode({
        'body': body,
        if (messageId != null) 'messageId': messageId,
        if (mediaUrl != null) 'mediaUrl': mediaUrl,
        if (mimeType != null) 'mimeType': mimeType,
        if (fileName != null) 'fileName': fileName,
        if (attachments != null) 'attachments': attachments,
        if (assignedTo != null) 'assignedTo': assignedTo,
        if (parentId != null) 'parentId': parentId,
        'status': status,
        'priority': priority,
      }),
    );
    final data = _decode(res);
    return (data['items'] as List)
        .map((e) => TaskItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Creates a task and returns both the new item and the full board list.
  Future<({TaskItem item, List<TaskItem> items})> createTaskDetailed({
    required String conversationId,
    required String body,
    String? messageId,
    String? mediaUrl,
    String? mimeType,
    String? fileName,
    List<Map<String, dynamic>>? attachments,
    String? assignedTo,
    String? parentId,
    String status = 'todo',
    String priority = 'medium',
  }) async {
    final res = await http.post(
      _u('/conversations/$conversationId/tasks'),
      headers: _headers,
      body: jsonEncode({
        'body': body,
        if (messageId != null) 'messageId': messageId,
        if (mediaUrl != null) 'mediaUrl': mediaUrl,
        if (mimeType != null) 'mimeType': mimeType,
        if (fileName != null) 'fileName': fileName,
        if (attachments != null) 'attachments': attachments,
        if (assignedTo != null) 'assignedTo': assignedTo,
        if (parentId != null) 'parentId': parentId,
        'status': status,
        'priority': priority,
      }),
    );
    final data = _decode(res);
    final items = (data['items'] as List)
        .map((e) => TaskItem.fromJson(e as Map<String, dynamic>))
        .toList();
    final item = data['item'] is Map<String, dynamic>
        ? TaskItem.fromJson(data['item'] as Map<String, dynamic>)
        : items.last;
    return (item: item, items: items);
  }

  Future<List<TaskItem>> updateTask({
    required String taskId,
    String? body,
    bool? done,
    bool? doneConfirmed,
    String? status,
    String? priority,
    String? assignedTo,
    bool? pinned,
    String? mediaUrl,
    String? mimeType,
    String? fileName,
    List<Map<String, dynamic>>? attachments,
    bool clearMedia = false,
  }) async {
    final res = await http.patch(
      _u('/tasks/$taskId'),
      headers: _headers,
      body: jsonEncode({
        if (body != null) 'body': body,
        if (done != null) 'done': done,
        if (doneConfirmed != null) 'doneConfirmed': doneConfirmed,
        if (status != null) 'status': status,
        if (priority != null) 'priority': priority,
        if (assignedTo != null) 'assignedTo': assignedTo,
        if (pinned != null) 'pinned': pinned,
        if (mediaUrl != null) 'mediaUrl': mediaUrl,
        if (mimeType != null) 'mimeType': mimeType,
        if (fileName != null) 'fileName': fileName,
        if (attachments != null) 'attachments': attachments,
        if (clearMedia) 'clearMedia': true,
      }),
    );
    final data = _decode(res);
    return (data['items'] as List)
        .map((e) => TaskItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Change log for a single task (newest first).
  Future<List<TaskActivity>> taskActivity(String taskId) async {
    final res = await http.get(
      _u('/tasks/$taskId/activity'),
      headers: _authHeaders,
    );
    final data = _decode(res);
    return (data['items'] as List)
        .map((e) => TaskActivity.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<TaskItem>> deleteTask(String taskId) async {
    final res = await http.delete(
      _u('/tasks/$taskId'),
      headers: _authHeaders,
    );
    final data = _decode(res);
    return (data['items'] as List)
        .map((e) => TaskItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<TaskItem>> clearDoneTasks(String conversationId) async {
    final res = await http.post(
      _u('/conversations/$conversationId/tasks/clear-done'),
      headers: _headers,
      body: '{}',
    );
    final data = _decode(res);
    return (data['items'] as List)
        .map((e) => TaskItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<TaskItem>> unpinAllTasks(String conversationId) async {
    final res = await http.post(
      _u('/conversations/$conversationId/tasks/unpin-all'),
      headers: _headers,
      body: '{}',
    );
    final data = _decode(res);
    return (data['items'] as List)
        .map((e) => TaskItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<PaymentReminder>> reminders(String conversationId) async {
    final res = await http.get(
      _u('/conversations/$conversationId/reminders'),
      headers: _authHeaders,
    );
    final data = _decode(res);
    return (data['items'] as List)
        .map((e) => PaymentReminder.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<PaymentReminder>> reminderHistory(String conversationId) async {
    final res = await http.get(
      _u('/conversations/$conversationId/reminders/history'),
      headers: _authHeaders,
    );
    final data = _decode(res);
    return (data['items'] as List)
        .map((e) => PaymentReminder.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<PaymentReminder>> createReminder({
    required String conversationId,
    required String kind,
    int? amountCents,
    required String currency,
    required String direction,
    required String dueDate,
    String note = '',
  }) async {
    final res = await http.post(
      _u('/conversations/$conversationId/reminders'),
      headers: _headers,
      body: jsonEncode({
        'kind': kind,
        if (amountCents != null) 'amountCents': amountCents,
        'currency': currency,
        'direction': direction,
        'dueDate': dueDate,
        'note': note,
      }),
    );
    final data = _decode(res);
    return (data['items'] as List)
        .map((e) => PaymentReminder.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<PaymentReminder>> updateReminder({
    required String reminderId,
    int? amountCents,
    String? currency,
    String? direction,
    String? dueDate,
    String? note,
    bool? paid,
    String? snoozedUntil,
    bool? pinned,
  }) async {
    final res = await http.patch(
      _u('/reminders/$reminderId'),
      headers: _headers,
      body: jsonEncode({
        if (amountCents != null) 'amountCents': amountCents,
        if (currency != null) 'currency': currency,
        if (direction != null) 'direction': direction,
        if (dueDate != null) 'dueDate': dueDate,
        if (note != null) 'note': note,
        if (paid != null) 'paid': paid,
        if (snoozedUntil != null) 'snoozedUntil': snoozedUntil,
        if (pinned != null) 'pinned': pinned,
      }),
    );
    final data = _decode(res);
    return (data['items'] as List)
        .map((e) => PaymentReminder.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<PaymentReminder>> deleteReminder(String reminderId) async {
    final res = await http.delete(
      _u('/reminders/$reminderId'),
      headers: _authHeaders,
    );
    final data = _decode(res);
    return (data['items'] as List)
        .map((e) => PaymentReminder.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<({List<PaymentReminder> items, List<PaymentReminder> history})> createExpense({
    required String paymentId,
    required String label,
    required int amountCents,
  }) async {
    final res = await http.post(
      _u('/reminders/$paymentId/expenses'),
      headers: _headers,
      body: jsonEncode({
        'label': label,
        'amountCents': amountCents,
      }),
    );
    final data = _decode(res);
    return (
      items: (data['items'] as List)
          .map((e) => PaymentReminder.fromJson(e as Map<String, dynamic>))
          .toList(),
      history: (data['history'] as List? ?? const [])
          .map((e) => PaymentReminder.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Future<({List<PaymentReminder> items, List<PaymentReminder> history})> updateExpense({
    required String expenseId,
    String? label,
    int? amountCents,
  }) async {
    final res = await http.patch(
      _u('/expenses/$expenseId'),
      headers: _headers,
      body: jsonEncode({
        if (label != null) 'label': label,
        if (amountCents != null) 'amountCents': amountCents,
      }),
    );
    final data = _decode(res);
    return (
      items: (data['items'] as List)
          .map((e) => PaymentReminder.fromJson(e as Map<String, dynamic>))
          .toList(),
      history: (data['history'] as List? ?? const [])
          .map((e) => PaymentReminder.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Future<({List<PaymentReminder> items, List<PaymentReminder> history})> deleteExpense(
    String expenseId,
  ) async {
    final res = await http.delete(
      _u('/expenses/$expenseId'),
      headers: _authHeaders,
    );
    final data = _decode(res);
    return (
      items: (data['items'] as List)
          .map((e) => PaymentReminder.fromJson(e as Map<String, dynamic>))
          .toList(),
      history: (data['history'] as List? ?? const [])
          .map((e) => PaymentReminder.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Future<Conversation> openDm(String userId) async {
    final res = await http.post(
      _u('/conversations/dm'),
      headers: _headers,
      body: jsonEncode({'userId': userId}),
    );
    final data = _decode(res);
    return Conversation.fromJson(data['conversation'] as Map<String, dynamic>);
  }

  Future<Conversation> createGroup({
    required String title,
    required List<String> memberIds,
  }) async {
    final res = await http.post(
      _u('/conversations/group'),
      headers: _headers,
      body: jsonEncode({'title': title, 'memberIds': memberIds}),
    );
    final data = _decode(res);
    return Conversation.fromJson(data['conversation'] as Map<String, dynamic>);
  }

  Future<MediaUpload> uploadBytes({
    required List<int> bytes,
    required String filename,
    required String mimeType,
    bool asVoice = false,
  }) async {
    final uri = _u('/uploads').replace(
      queryParameters: asVoice ? {'as': 'voice'} : null,
    );
    final req = http.MultipartRequest('POST', uri);
    if (token != null) {
      req.headers['Authorization'] = 'Bearer $token';
    }
    MediaType contentType;
    try {
      contentType = MediaType.parse(
        mimeType.isEmpty ? 'application/octet-stream' : mimeType,
      );
    } catch (_) {
      contentType = MediaType('application', 'octet-stream');
    }
    req.files.add(
      http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: filename.isEmpty ? 'attachment.bin' : filename,
        contentType: contentType,
      ),
    );
    final streamed = await req.send();
    final res = await http.Response.fromStream(streamed);
    final data = _decode(res);
    return MediaUpload.fromJson(data);
  }

  Future<List<Map<String, dynamic>>> iceServers() async {
    final res = await http.get(_u('/ice'), headers: _authHeaders);
    final data = _decode(res);
    return ((data['iceServers'] as List?) ?? [])
        .cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> aiChat(
    String conversationId, {
    required String input,
    String? since,
    String? apiKey,
    String? model,
    String? baseUrl,
  }) async {
    final res = await http.post(
      _u('/conversations/$conversationId/ai'),
      headers: _headers,
      body: jsonEncode({
        'input': input,
        if (since != null && since.isNotEmpty) 'since': since,
        if (apiKey != null && apiKey.isNotEmpty) 'apiKey': apiKey,
        if (model != null && model.isNotEmpty) 'model': model,
        if (baseUrl != null && baseUrl.isNotEmpty) 'baseUrl': baseUrl,
      }),
    );
    return _decode(res);
  }

  /// Server AI env status (no secrets) — whether OpenAI-compat / Gemini are configured.
  Future<Map<String, dynamic>> aiStatus() async {
    final res = await http.get(_u('/ai/status'), headers: _authHeaders);
    return _decode(res);
  }

  Map<String, dynamic> _decode(http.Response res) {
    final body = res.body.isEmpty ? <String, dynamic>{} : jsonDecode(res.body);
    if (res.statusCode >= 400) {
      throw ApiException(
        res.statusCode,
        (body is Map && body['error'] != null)
            ? body['error'].toString()
            : 'request failed',
      );
    }
    return body as Map<String, dynamic>;
  }

  String get wsUrl {
    final uri = Uri.parse(baseUrl);
    final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '$scheme://${uri.host}$port/ws';
  }
}

class ApiException implements Exception {
  ApiException(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => 'ApiException($status): $message';
}
