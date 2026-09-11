import 'dart:convert';

import 'package:http/http.dart' as http;

/// LAAP 认知皮层 HTTP 客户端。只给活人感用，不是聊天模型。
class LaapApiException implements Exception {
  final String message;
  final int? statusCode;
  LaapApiException(this.message, {this.statusCode});
  @override
  String toString() =>
      statusCode == null ? message : '$message (HTTP $statusCode)';
}

/// `/v1/cognitive_state` 的官方字段。preamble / cot_hint 进动尾，needs 用来选风格。
class LaapCognitiveState {
  final Map<String, double> needs;
  final double valence;
  final double energy;
  final double arousal;
  final String attentionFocus;
  final int cognitiveCycle;
  final String preamble;
  final String cotHint;

  const LaapCognitiveState({
    required this.needs,
    this.valence = 0,
    this.energy = 10,
    this.arousal = 0.4,
    this.attentionFocus = 'social',
    this.cognitiveCycle = 0,
    this.preamble = '',
    this.cotHint = '',
  });

  static const needNames = [
    'competence',
    'autonomy',
    'relatedness',
    'certainty',
    'growth',
  ];

  bool get isUsable => needs.isNotEmpty || preamble.trim().isNotEmpty;

  factory LaapCognitiveState.fromJson(Map<String, dynamic> json) {
    final rawState = json['state'];
    final state = rawState is Map ? Map<String, dynamic>.from(rawState) : json;
    final rawNeeds = state['needs'];
    final needs = <String, double>{};
    if (rawNeeds is Map) {
      for (final name in needNames) {
        final v = rawNeeds[name];
        if (v is num) needs[name] = v.toDouble();
      }
    }
    final focus =
        (state['attention_focus'] ?? state['attentionFocus'] ?? 'social')
            .toString()
            .trim();
    final preamble = (json['preamble'] ?? '').toString().trim();
    final cotHint = (json['cot_hint'] ?? json['cotHint'] ?? '')
        .toString()
        .trim();
    return LaapCognitiveState(
      needs: needs,
      valence: (state['valence'] as num?)?.toDouble() ?? 0,
      energy: (state['energy'] as num?)?.toDouble() ?? 10,
      arousal: (state['arousal'] as num?)?.toDouble() ?? 0.4,
      attentionFocus: focus.isEmpty ? 'social' : focus,
      cognitiveCycle:
          (state['cognitive_cycle'] as num?)?.toInt() ??
          (state['cognitiveCycle'] as num?)?.toInt() ??
          0,
      preamble: preamble,
      cotHint: cotHint,
    );
  }

  /// 把 `/v1/cognitive_state` 整段 JSON 收成可用状态。error 或空状态都失败。
  static LaapCognitiveState parseResponse(Map<String, dynamic> map) {
    final err = map['error'];
    if (err != null && err.toString().trim().isNotEmpty) {
      throw LaapApiException(err.toString());
    }
    final state = LaapCognitiveState.fromJson(map);
    if (!state.isUsable) {
      throw LaapApiException('cognitive_state 无需求状态');
    }
    return state;
  }
}

class LaapBootstrapResult {
  final String identityName;
  final String ceremony;
  final Map<String, dynamic> identity;
  final Map<String, dynamic> personality;
  final Map<String, dynamic> bond;

  const LaapBootstrapResult({
    this.identityName = '',
    this.ceremony = '',
    this.identity = const {},
    this.personality = const {},
    this.bond = const {},
  });

  factory LaapBootstrapResult.fromJson(Map<String, dynamic> json) {
    final identity = json['identity'] is Map
        ? Map<String, dynamic>.from(json['identity'] as Map)
        : const <String, dynamic>{};
    return LaapBootstrapResult(
      identityName: (identity['name'] ?? '').toString().trim(),
      ceremony: (json['ceremony'] ?? '').toString().trim(),
      identity: identity,
      personality: json['personality'] is Map
          ? Map<String, dynamic>.from(json['personality'] as Map)
          : const {},
      bond: json['bond'] is Map
          ? Map<String, dynamic>.from(json['bond'] as Map)
          : const {},
    );
  }
}

class LaapMemory {
  final String content;
  final Map<String, dynamic> raw;

  const LaapMemory(this.content, {this.raw = const {}});

  factory LaapMemory.fromJson(Map<String, dynamic> json) {
    return LaapMemory(
      (json['content'] ?? json['text'] ?? json['memory'] ?? '')
          .toString()
          .trim(),
      raw: json,
    );
  }
}

class LaapApiClient {
  LaapApiClient({this.baseUrl = 'http://127.0.0.1:11546', http.Client? client})
    : _client = client ?? http.Client();

  static final LaapApiClient instance = LaapApiClient();

  final String baseUrl;
  final http.Client _client;

  Uri _uri(String path) {
    final root = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$root$path');
  }

  Future<bool> health({Duration timeout = const Duration(seconds: 2)}) async {
    try {
      final resp = await _client.get(_uri('/health')).timeout(timeout);
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<LaapCognitiveState> cognitiveState(
    String input, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final resp = await _client
        .post(
          _uri('/v1/cognitive_state'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'input': input}),
        )
        .timeout(timeout);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw LaapApiException('cognitive_state 失败', statusCode: resp.statusCode);
    }
    final decoded = jsonDecode(resp.body);
    if (decoded is! Map) {
      throw LaapApiException('cognitive_state 返回不是对象');
    }
    return LaapCognitiveState.parseResponse(Map<String, dynamic>.from(decoded));
  }

  Future<LaapBootstrapResult> bootstrap({
    required String userName,
    String? preset,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final body = <String, dynamic>{'user_name': userName};
    if (preset != null && preset.trim().isNotEmpty) {
      body['preset'] = preset.trim();
    }
    final resp = await _client
        .post(
          _uri('/v1/bootstrap'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(timeout);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw LaapApiException('bootstrap 失败', statusCode: resp.statusCode);
    }
    final decoded = jsonDecode(resp.body);
    if (decoded is! Map) {
      throw LaapApiException('bootstrap 返回不是对象');
    }
    final result = LaapBootstrapResult.fromJson(
      Map<String, dynamic>.from(decoded),
    );
    if (result.identityName.isEmpty && result.ceremony.isEmpty) {
      throw LaapApiException('bootstrap 未返回身份或觉醒信息');
    }
    return result;
  }

  Future<List<LaapMemory>> recallMemory(
    String query, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final resp = await _client
        .post(
          _uri('/v1/recall_memory'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'query': query}),
        )
        .timeout(timeout);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw LaapApiException('recall_memory 失败', statusCode: resp.statusCode);
    }
    final decoded = jsonDecode(resp.body);
    if (decoded is! Map) {
      throw LaapApiException('recall_memory 返回不是对象');
    }
    final raw = decoded['memories'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((item) => LaapMemory.fromJson(Map<String, dynamic>.from(item)))
        .where((item) => item.content.isNotEmpty)
        .toList();
  }

  Future<bool> cortexReady({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    try {
      await cognitiveState('ping', timeout: timeout);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> reflect(
    String output, {
    bool success = true,
    Map<String, dynamic>? feedback,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final body = <String, dynamic>{
      'output': output,
      'success': success,
      if (feedback != null) 'feedback': feedback,
    };
    final resp = await _client
        .post(
          _uri('/v1/reflect'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(timeout);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw LaapApiException('reflect 失败', statusCode: resp.statusCode);
    }
  }
}
