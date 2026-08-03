import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class LlmException implements Exception {
  final String message;
  LlmException(this.message);
  @override
  String toString() => message;
}

/// 流式回复提前中断（未收到 [DONE] 或连接断开），可自动重试。
class LlmInterruptedException extends LlmException {
  LlmInterruptedException(super.message);
}

/// Result emitted for each assistant turn.
class TurnResult {
  final String text;
  final List<Map<String, String>> toolCalls; // [{id,name,arguments}]
  TurnResult({this.text = '', List<Map<String, String>>? toolCalls})
    : toolCalls = toolCalls ?? [];
}

/// OpenAI-compatible streaming client with SSE parsing and tool calls.
class LlmClient {
  final String baseUrl;
  final String apiKey;
  final String model;
  final double temperature;
  final List<Map<String, dynamic>> tools;
  final void Function(TurnResult turn)? onTurn;
  final void Function(String error)? onError;
  final bool Function()? shouldStop;

  /// 最近一次请求的 total_tokens（来自流式 usage）。
  int? lastTotalTokens;

  LlmClient({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    required this.temperature,
    required this.tools,
    this.onTurn,
    this.onError,
    this.shouldStop,
  });

  String get _endpoint =>
      '${baseUrl.replaceAll(RegExp(r'/*$'), '')}/chat/completions';

  Future<void> send(List<Map<String, dynamic>> messages) async {
    lastTotalTokens = null;
    final client = http.Client();
    try {
      var includeUsage = true;
      for (var attempt = 0; attempt < 2; attempt++) {
        final body = <String, dynamic>{
          'model': model,
          'messages': messages,
          'stream': true,
          if (includeUsage) 'stream_options': {'include_usage': true},
          'temperature': temperature,
          if (tools.isNotEmpty) 'tools': tools,
          if (tools.isNotEmpty) 'tool_choice': 'auto',
        };
        final request = http.Request('POST', Uri.parse(_endpoint))
          ..headers.addAll(<String, String>{
            'Content-Type': 'application/json',
            'Accept': 'text/event-stream',
            if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
          })
          ..body = jsonEncode(body);
        try {
          final response = await client
              .send(request)
              .timeout(const Duration(seconds: 30));
          if (response.statusCode != 200) {
            final err = await response.stream.bytesToString();
            // 部分网关/中转不支持 stream_options：去掉后重试一次（只少 token 统计，不影响内容）。
            if (includeUsage && _isUsageParamError(err)) {
              includeUsage = false;
              continue;
            }
            throw LlmException('HTTP ${response.statusCode}: ${_short(err)}');
          }
          await _parseSse(response.stream);
          return;
        } on TimeoutException {
          throw LlmException('请求超时：网络连接或响应过慢，请重试');
        }
      }
    } finally {
      client.close();
    }
  }

  /// 判断 HTTP 400 是否由 stream_options/include_usage 参数不被支持引起。
  static bool _isUsageParamError(String err) {
    final e = err.toLowerCase();
    return e.contains('stream_options') ||
        e.contains('include_usage') ||
        e.contains('unknown parameter') ||
        e.contains('unknown argument') ||
        e.contains('extra fields');
  }

  String _short(String s) {
    final t = s.trim();
    return t.length > 300 ? t.substring(0, 300) : t;
  }

  /// 单次非流式补全，返回完整的 assistant 文本。用于自动沉淀记忆等后端调用。
  Future<String> completeOne(
    List<Map<String, dynamic>> messages, {
    double? temperature,
    int? maxTokens,
  }) async {
    final body = <String, dynamic>{
      'model': model,
      'messages': messages,
      'stream': false,
      'temperature': temperature ?? this.temperature,
    };
    if (maxTokens != null) body['max_tokens'] = maxTokens;

    final request = http.Request('POST', Uri.parse(_endpoint))
      ..headers.addAll(<String, String>{
        'Content-Type': 'application/json',
        if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
      })
      ..body = jsonEncode(body);

    final client = http.Client();
    try {
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 90));
      final raw = await response.stream.bytesToString();
      if (response.statusCode != 200) {
        throw LlmException('HTTP ${response.statusCode}: ${_short(raw)}');
      }
      final json = _tryDecode(raw);
      if (json == null) throw LlmException('响应解析失败');
      final choices = json['choices'] as List<dynamic>? ?? [];
      if (choices.isEmpty) return '';
      final msg = choices.first['message'] as Map<String, dynamic>?;
      return (msg?['content'] as String?)?.trim() ?? '';
    } finally {
      client.close();
    }
  }

  /// 获取模型列表（GET /models），返回模型 id 列表。
  Future<List<String>> listModels() async {
    final url = '${baseUrl.replaceAll(RegExp(r'/*$'), '')}/models';
    final client = http.Client();
    try {
      final res = await client
          .get(
            Uri.parse(url),
            headers: <String, String>{
              'Content-Type': 'application/json',
              if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
            },
          )
          .timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        throw LlmException('HTTP ${res.statusCode}: ${_short(res.body)}');
      }
      final json = _tryDecode(res.body);
      if (json == null) throw LlmException('响应解析失败');
      final data = json['data'] as List<dynamic>? ?? [];
      return data
          .map(
            (e) =>
                (e is Map<String, dynamic>) ? (e['id']?.toString() ?? '') : '',
          )
          .where((s) => s.isNotEmpty)
          .toList();
    } finally {
      client.close();
    }
  }

  /// 测试模型连通性：发送 hi，返回 HTTP 状态与简要结果。
  Future<String> testChat() async {
    final body = <String, dynamic>{
      'model': model,
      'messages': [
        {'role': 'user', 'content': 'hi'},
      ],
      'max_tokens': 8,
      'stream': false,
    };
    final request = http.Request('POST', Uri.parse(_endpoint))
      ..headers.addAll(<String, String>{
        'Content-Type': 'application/json',
        if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
      })
      ..body = jsonEncode(body);
    final client = http.Client();
    try {
      final res = await client
          .send(request)
          .timeout(const Duration(seconds: 30));
      final raw = await res.stream.bytesToString();
      if (res.statusCode == 200) {
        return '测试成功（HTTP 200）';
      }
      return '测试失败（HTTP ${res.statusCode}）：${_short(raw)}';
    } finally {
      client.close();
    }
  }

  Future<void> _parseSse(Stream<List<int>> raw) async {
    final denyBuffer = StringBuffer(); // line buffer
    String text = '';
    final toolBuf = <int, Map<String, String>>{};
    var doneReceived = false;
    var stoppedByUser = false;

    void emitPartial() {
      if (text.isNotEmpty) {
        onTurn?.call(
          TurnResult(text: text, toolCalls: _snapshotTools(toolBuf)),
        );
      }
    }

    void handleLine(String line) {
      if (line.isEmpty) return;
      if (line.startsWith('data:')) {
        final data = line.substring(5).trim();
        if (data == '[DONE]') {
          doneReceived = true;
          return;
        }
        final json = _tryDecode(data);
        if (json == null) return;
        final usage = json['usage'] as Map<String, dynamic>?;
        if (usage != null) {
          final total = (usage['total_tokens'] as num?)?.toInt();
          if (total != null && total > 0) lastTotalTokens = total;
        }
        final choices = json['choices'] as List<dynamic>? ?? [];
        if (choices.isEmpty) return;
        final first = choices.first;
        if (first is! Map) return;
        final delta = first['delta'] as Map<String, dynamic>?;
        if (delta == null) return;
        final content = delta['content'];
        if (content is String && content.isNotEmpty) {
          text += content;
          emitPartial();
        }
        final toolCalls = delta['tool_calls'] as List<dynamic>?;
        if (toolCalls != null) {
          for (final tcRaw in toolCalls) {
            final tc = tcRaw is Map<String, dynamic> ? tcRaw : {};
            final i = (tc['index'] as num?)?.toInt() ?? 0;
            final cur = toolBuf.putIfAbsent(
              i,
              () => {'id': '', 'name': '', 'arguments': ''},
            );
            final id = tc['id'];
            if (id is String && id.isNotEmpty) cur['id'] = id;
            final fn = tc['function'] as Map<String, dynamic>?;
            if (fn != null) {
              final name = fn['name'];
              if (name is String && name.isNotEmpty) cur['name'] = name;
              final args = fn['arguments'];
              if (args is String && args.isNotEmpty) {
                cur['arguments'] = cur['arguments']! + args;
              }
            }
          }
        }
      }
    }

    final completer = Completer<void>();
    StreamSubscription<String>? sub;
    Timer? idleTimer;
    void resetIdleTimer() {
      idleTimer?.cancel();
      idleTimer = Timer(const Duration(seconds: 180), () {
        idleTimer = null;
        sub?.cancel();
        if (!completer.isCompleted) {
          completer.completeError(LlmInterruptedException('回复中断：连接长时间无数据，请重试'));
        }
      });
    }

    sub = raw
        .transform(utf8.decoder)
        .listen(
          (chunk) {
            if (shouldStop?.call() ?? false) {
              stoppedByUser = true;
              idleTimer?.cancel();
              sub?.cancel();
              if (!completer.isCompleted) completer.complete();
              return;
            }
            resetIdleTimer();
            denyBuffer.write(chunk);
            var s = denyBuffer.toString();
            int idx;
            while ((idx = s.indexOf('\n')) != -1) {
              final line = s.substring(0, idx).trimRight();
              s = s.substring(idx + 1);
              handleLine(line);
            }
            denyBuffer.clear();
            denyBuffer.write(s);
          },
          onError: (Object e) {
            idleTimer?.cancel();
            if (!completer.isCompleted) {
              completer.completeError(LlmInterruptedException('回复中断（连接断开）：$e'));
            }
          },
          onDone: () {
            idleTimer?.cancel();
            if (denyBuffer.isNotEmpty) {
              final rest = denyBuffer.toString();
              if (rest.trim().isNotEmpty) {
                for (final line in rest.split('\n')) {
                  handleLine(line);
                }
              }
              denyBuffer.clear();
            }
            if (text.isNotEmpty || toolBuf.isNotEmpty) {
              onTurn?.call(
                TurnResult(
                  text: text.trim(),
                  toolCalls: _snapshotTools(toolBuf),
                ),
              );
            }
            if (!completer.isCompleted) {
              // 已收到内容但没有 [DONE]：不少网关/代理正常结束时不发 [DONE]，
              // 此时视为回复完成，避免误报"回复不完整"导致丢内容重试。
              if (!doneReceived &&
                  !stoppedByUser &&
                  text.isEmpty &&
                  toolBuf.isEmpty) {
                completer.completeError(
                  LlmInterruptedException('回复不完整：连接提前断开，请重试'),
                );
              } else {
                completer.complete();
              }
            }
          },
          cancelOnError: true,
        );
    await completer.future;
  }

  List<Map<String, String>> _snapshotTools(Map<int, Map<String, String>> buf) {
    final keys = buf.keys.toList()..sort();
    return keys.map((k) => Map<String, String>.from(buf[k]!)).toList();
  }

  Map<String, dynamic>? _tryDecode(String s) {
    try {
      return jsonDecode(s) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }
}



