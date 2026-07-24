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
    return 'https://messanger.banderdog.com';
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

  Future<ChatMessage> forwardMessage({
    required String conversationId,
    required String messageId,
  }) async {
    final res = await http.post(
      _u('/conversations/$conversationId/forward'),
      headers: _headers,
      body: jsonEncode({'messageId': messageId}),
    );
    final data = _decode(res);
    return ChatMessage.fromJson(data['message'] as Map<String, dynamic>);
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

  Future<List<TaskItem>> createTask({
    required String conversationId,
    required String body,
    String? messageId,
    String? mediaUrl,
    String? mimeType,
    String? fileName,
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
      }),
    );
    final data = _decode(res);
    return (data['items'] as List)
        .map((e) => TaskItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<TaskItem>> updateTask({
    required String taskId,
    String? body,
    bool? done,
    String? mediaUrl,
    String? mimeType,
    String? fileName,
    bool clearMedia = false,
  }) async {
    final res = await http.patch(
      _u('/tasks/$taskId'),
      headers: _headers,
      body: jsonEncode({
        if (body != null) 'body': body,
        if (done != null) 'done': done,
        if (mediaUrl != null) 'mediaUrl': mediaUrl,
        if (mimeType != null) 'mimeType': mimeType,
        if (fileName != null) 'fileName': fileName,
        if (clearMedia) 'clearMedia': true,
      }),
    );
    final data = _decode(res);
    return (data['items'] as List)
        .map((e) => TaskItem.fromJson(e as Map<String, dynamic>))
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
