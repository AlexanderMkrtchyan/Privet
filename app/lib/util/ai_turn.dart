import 'dart:convert';

/// One saved AI (API key + optional OpenAI-compat base URL + model).
class AiProfile {
  AiProfile({
    required this.id,
    required this.apiKey,
    required this.model,
    this.baseUrl = '',
  });

  final String id;
  String apiKey;
  String model;

  /// OpenAI-compatible API host (prefix before `/chat/completions`).
  /// Not used for Gemini (`AIza…`) keys.
  String baseUrl;

  bool get isGeminiKey => apiKey.trim().startsWith('AIza');

  /// UI / badges show only the model id.
  String get displayName {
    final m = model.trim();
    return m.isEmpty ? 'Unnamed model' : m;
  }

  String get maskedKey {
    final k = apiKey.trim();
    if (k.isEmpty) return 'No key';
    if (k.length <= 10) return '••••••••';
    return '${k.substring(0, 4)}…${k.substring(k.length - 4)}';
  }

  bool get isReady {
    if (apiKey.trim().isEmpty || model.trim().isEmpty) return false;
    if (isGeminiKey) return true;
    return baseUrl.trim().isNotEmpty;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'apiKey': apiKey,
        'model': model,
        'baseUrl': baseUrl,
      };

  factory AiProfile.fromJson(Map<String, dynamic> json) => AiProfile(
        id: json['id']?.toString() ?? '',
        apiKey: json['apiKey']?.toString() ?? '',
        model: json['model']?.toString() ?? '',
        baseUrl: json['baseUrl']?.toString() ?? '',
      );
}

/// Packed Q+A body for shared (and private) Privet AI messages.
class AiTurnPayload {
  AiTurnPayload({
    required this.question,
    required this.answer,
    this.provider,
    this.model,
    this.private = false,
  });

  final String question;
  final String answer;
  final String? provider;
  final String? model;
  final bool private;

  String get headerLabel {
    final bits = <String>['Privet AI'];
    if (private) bits.add('only you');
    final m = model?.trim();
    if (m != null && m.isNotEmpty) bits.add(m);
    return bits.join(' · ');
  }

  String encode() => jsonEncode({
        'v': 1,
        'q': question,
        'a': answer,
        if (provider != null && provider!.isNotEmpty) 'provider': provider,
        if (model != null && model!.isNotEmpty) 'model': model,
        if (private) 'private': true,
      });

  static AiTurnPayload? tryParse(String body) {
    final trimmed = body.trim();
    if (!trimmed.startsWith('{')) return null;
    try {
      final map = jsonDecode(trimmed);
      if (map is! Map) return null;
      final q = map['q']?.toString() ?? '';
      final a = map['a']?.toString() ?? '';
      if (q.isEmpty && a.isEmpty) return null;
      return AiTurnPayload(
        question: q,
        answer: a,
        provider: map['provider']?.toString(),
        model: map['model']?.toString(),
        private: map['private'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}
