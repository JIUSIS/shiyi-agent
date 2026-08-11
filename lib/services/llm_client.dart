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
  final String reasoning; // 模型思考内容（reasoning_content）
  TurnResult({
    this.text = '',
    this.reasoning = '',
    List<Map<String, String>>? toolCalls,
  }) : toolCalls = toolCalls ?? [];
}

/// OpenAI-compatible streaming client with SSE parsing and tool calls.
class LlmClient {
  final String baseUrl;
  final String apiKey;
  final String model;
  final double temperature;
  final int maxTokens;
  final List<Map<String, dynamic>> tools;
  final void Function(TurnResult turn)? onTurn;
  final void Function(String error)? onError;
  final bool Function()? shouldStop;

  /// 流诊断回调（排查截断/丢工具调用）：记录流结束方式、finish_reason、
  /// 文本尾部、tool_calls 块数等。
  final void Function(String line)? onDiag;

  /// 最近一次请求的 total_tokens（来自流式 usage，兼容 Chat Completions 与
  /// Responses API 的 input+output 推导）。
  int? lastTotalTokens;

  /// 最近一次请求的输入 token：Chat Completions 的 prompt_tokens 或
  /// Responses API 的 input_tokens。
  int? lastPromptTokens;

  /// 最近一次请求的输出 token：Responses API 的 output_tokens。
  int? lastOutputTokens;

  /// 最近一次请求的输入 token（Responses API 字段，优先于 lastPromptTokens
  /// 使用；两者值相同时只取一个）。
  int? lastInputTokens;

  /// 最近一次请求的缓存输入 token（兼容 OpenAI / 网关 / Anthropic 风格字段）。
  int? lastCachedTokens;

  /// 最近一轮收到的文本（纯文本截断续写时拼接用）。
  String _lastRoundText = '';

  LlmClient({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    required this.temperature,
    this.maxTokens = 8192,
    required this.tools,
    this.onTurn,
    this.onError,
    this.shouldStop,
    this.onDiag,
  });

  String get _endpoint =>
      '${baseUrl.replaceAll(RegExp(r'/*$'), '')}/chat/completions';

  Future<void> send(List<Map<String, dynamic>> messages) async {
    lastTotalTokens = null;
    lastPromptTokens = null;
    lastOutputTokens = null;
    lastInputTokens = null;
    lastCachedTokens = null;
    final client = http.Client();
    try {
      var includeUsage = true;
      // 部分网关/中转不支持过大的 max_tokens：HTTP 400 时自动降级到 8192 重试。
      var outputLimit = maxTokens;
      // 续写轮追加的消息：纯文本被截断时，把已输出内容 + 「继续」指令发回，
      // 模型从断点继续（不重发整轮，不丢已输出）。
      final continuation = <Map<String, dynamic>>[];
      for (var round = 0; round < 3; round++) {
        final body = <String, dynamic>{
          'model': model,
          'messages': [...messages, ...continuation],
          'stream': true,
          if (includeUsage) 'stream_options': {'include_usage': true},
          'temperature': temperature,
          // 显式声明输出上限：部分网关默认 max_tokens 过小，
          // 思考模型（reasoning 占 token）+ 长工具调用会导致 content 被截断。
          // 默认 8192，可在设置中按模型调大（如 OpenCode Go 的 32768）。
          'max_tokens': outputLimit,
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
              .timeout(const Duration(seconds: 60));
          if (response.statusCode != 200) {
            final err = await response.stream.bytesToString();
            // 部分网关/中转不支持 stream_options：去掉后重试一次（只少 token 统计，不影响内容）。
            if (includeUsage && _isUsageParamError(err)) {
              includeUsage = false;
              continue;
            }
            // max_tokens 过大被网关拒绝：降级到 8192 再试一次。
            if (outputLimit > 8192 && _isMaxTokensParamError(err)) {
              outputLimit = 8192;
              onDiag?.call('[stream] max_tokens 过大被拒绝，降级 8192 重试');
              continue;
            }
            throw LlmException('HTTP ${response.statusCode}: ${_short(err)}');
          }
          final needContinue = await _parseSse(response.stream);
          if (!needContinue) return;
          // 纯文本截断：追加已输出 + 继续指令，发起续写请求。
          onDiag?.call('[stream] 续写第 ${round + 1} 轮');
          continuation.addAll([
            {'role': 'assistant', 'content': _lastRoundText},
            {
              'role': 'user',
              'content':
                  '继续完成上述输出。直接从上次断点继续写，'
                  '不要重复已经输出的内容。',
            },
          ]);
          includeUsage = false;
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

  /// 判断 HTTP 400 是否由 max_tokens 参数过大/不被支持引起。
  static bool _isMaxTokensParamError(String err) {
    final e = err.toLowerCase();
    return e.contains('max_tokens') ||
        e.contains('max tokens') ||
        e.contains('maximum output tokens');
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

  Future<bool> _parseSse(Stream<List<int>> raw) async {
    final denyBuffer = StringBuffer(); // line buffer
    String text = '';
    String reasoning = '';
    final toolBuf = <int, Map<String, String>>{};
    var doneReceived = false;
    var stoppedByUser = false;
    var reasoningSeeded = false;
    String? finishReason; // 最后一条 chunk 的 finish_reason：'length' = 输出被截断
    final completer = Completer<bool>();

    void emitPartial() {
      if (text.isNotEmpty || reasoning.isNotEmpty) {
        onTurn?.call(
          TurnResult(
            text: text,
            reasoning: reasoning,
            toolCalls: _snapshotTools(toolBuf),
          ),
        );
      }
    }

    /// 判断本轮是否因输出截断需要续写。
    /// 返回 true = 纯文本被截断，调用方应追加「继续」请求续写；
    /// false = 正常完成。工具调用完整时即使 fr=length 也视为完成
    /// （截断的只是后续文本，工具照常执行）。
    bool decideContinue() {
      if (completer.isCompleted) return false;
      final toolsComplete =
          toolBuf.isNotEmpty &&
          toolBuf.values.every((t) {
            final a = t['arguments'] ?? '';
            return a.trim().isNotEmpty && _tryDecode(a) != null;
          });
      final t = text.trim();
      final halfCut =
          reasoning.isNotEmpty &&
          t.isNotEmpty &&
          toolBuf.isEmpty &&
          (t.endsWith('：') ||
              t.endsWith(':') ||
              t.endsWith('，') ||
              t.endsWith(','));
      final truncated = finishReason == 'length' || halfCut;
      if (!truncated) return false;
      if (toolsComplete) return false; // 工具完整：截断不影响执行
      if (toolBuf.isNotEmpty) {
        // 工具调用不完整（参数半截）：无法续写，整轮重试。
        completer.completeError(LlmInterruptedException('工具调用被截断，正在自动重试'));
        return false;
      }
      // 思考把输出预算吃完、正文还没开始：空正文续写没有断点，
      // 直接整轮重试，让上层提示模型输出正文而不是继续思考。
      if (finishReason == 'length' && t.isEmpty) {
        completer.completeError(
          LlmInterruptedException('回复中断：模型输出被截断且没有正文，正在自动重试'),
        );
        return false;
      }
      return true; // 纯文本截断：续写
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
        if (usage != null) applyUsage(usage);
        // OpenAI Responses API 风格的事件流：推理摘要/思考文本单独作为
        // SSE 事件推送，不经过 choices[].delta。
        final eventType = json['type'];
        if (eventType is String &&
            (eventType.startsWith('response.reasoning') ||
                eventType.startsWith('response.thinking'))) {
          final rc = extractReasoningValue(json['delta']);
          if (rc != null) {
            reasoning += rc;
            reasoningSeeded = true;
            emitPartial();
          }
          return;
        }
        final choices = json['choices'] as List<dynamic>? ?? [];
        if (choices.isEmpty) return;
        final first = choices.first;
        if (first is! Map) return;
        final fr = first['finish_reason'];
        if (fr is String && fr.isNotEmpty) finishReason = fr;
        final delta = first['delta'] as Map<String, dynamic>?;
        final msg = first['message'] as Map<String, dynamic>?;
        if (delta != null) {
          final content = delta['content'];
          if (content is String && content.isNotEmpty) {
            text += content;
            emitPartial();
          }
          // 兼容各家网关的思考字段：DeepSeek/MiMo/OpenCode Go 的
          // reasoning_content，OpenAI/OpenRouter 的 reasoning，Anthropic
          // 风格的 thinking、reasoning_summary，以及部分 Gemini 兼容端的 thought。
          final rc =
              extractReasoningValue(delta['reasoning_content']) ??
              extractReasoningValue(delta['reasoning']) ??
              extractReasoningValue(delta['reasoning_summary']) ??
              extractReasoningValue(delta['reasoning_summary_text']) ??
              extractReasoningValue(delta['thinking']) ??
              extractReasoningValue(delta['thought']);
          if (rc != null) {
            reasoning += rc;
            reasoningSeeded = true;
            emitPartial();
          } else if (!reasoningSeeded) {
            // 部分网关把完整思考放在 message 而非 delta，只取一次避免重复。
            final staticR = extractReasoningValue(
              msg?['reasoning_content'] ??
                  msg?['reasoning'] ??
                  msg?['reasoning_summary'] ??
                  msg?['reasoning_summary_text'] ??
                  msg?['thinking'] ??
                  msg?['thought'],
            );
            if (staticR != null) {
              reasoning = staticR;
              reasoningSeeded = true;
              emitPartial();
            }
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
        } else if (!reasoningSeeded) {
          // 非流式 chunk：正文和思考都直接放在 message 里。
          final content = msg?['content'];
          if (content is String && content.isNotEmpty && text.isEmpty) {
            text = content;
            emitPartial();
          }
          final staticR = extractReasoningValue(
            msg?['reasoning_content'] ??
                msg?['reasoning'] ??
                msg?['reasoning_summary'] ??
                msg?['reasoning_summary_text'] ??
                msg?['thinking'] ??
                msg?['thought'],
          );
          if (staticR != null) {
            reasoning = staticR;
            reasoningSeeded = true;
            emitPartial();
          }
        }
      }
    }

    StreamSubscription<String>? sub;
    Timer? idleTimer;
    void resetIdleTimer() {
      idleTimer?.cancel();
      idleTimer = Timer(const Duration(seconds: 180), () {
        idleTimer = null;
        sub?.cancel();
        onDiag?.call('[stream] idle 超时断开');
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
              if (!completer.isCompleted) completer.complete(false);
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
            onDiag?.call('[stream] onError: $e');
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
            final tail = text.length <= 40
                ? text
                : '…${text.substring(text.length - 40)}';
            onDiag?.call(
              '[stream] end model=$model max=$maxTokens '
              'fr=$finishReason done=$doneReceived '
              'textLen=${text.length} tools=${toolBuf.length} '
              'reasoningLen=${reasoning.length} tail=${tail.trim()}',
            );
            if (text.isNotEmpty || toolBuf.isNotEmpty || reasoning.isNotEmpty) {
              onTurn?.call(
                TurnResult(
                  text: text.trim(),
                  reasoning: reasoning,
                  toolCalls: _snapshotTools(toolBuf),
                ),
              );
            }
            // 截断决策：纯文本截断 → 续写；工具完整 → 正常完成。
            final needContinue = decideContinue();
            _lastRoundText = text.trim();
            onDiag?.call(
              '[stream] needContinue=$needContinue model=$model '
              'max=$maxTokens fr=$finishReason '
              'done=$doneReceived tools=${toolBuf.length}',
            );
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
                completer.complete(needContinue);
              }
            }
          },
          cancelOnError: true,
        );
    return completer.future;
  }

  List<Map<String, String>> _snapshotTools(Map<int, Map<String, String>> buf) {
    final keys = buf.keys.toList()..sort();
    return keys.map((k) => Map<String, String>.from(buf[k]!)).toList();
  }

  /// 解析一次 usage：同时兼容 Chat Completions（prompt/completion/total）与
  /// Responses API（input/output/total）字段，缓存字段支持常见网关别名。
  /// 服务端没有明确返回缓存字段时保持 lastCachedTokens 为 null。
  void applyUsage(Map<String, dynamic> usage) {
    final input =
        _intOf(usage['input_tokens']) ?? _intOf(usage['prompt_tokens']);
    final output =
        _intOf(usage['output_tokens']) ?? _intOf(usage['completion_tokens']);
    final total =
        _intOf(usage['total_tokens']) ??
        (input != null && output != null ? input + output : null);
    if (total != null && total > 0) lastTotalTokens = total;
    if (input != null && input >= 0) {
      lastInputTokens = input;
      lastPromptTokens = input;
    } else if (total != null && output != null && output >= 0) {
      lastPromptTokens = total - output;
    }
    if (output != null && output >= 0) lastOutputTokens = output;

    final promptDetails = usage['prompt_tokens_details'];
    final inputDetails = usage['input_tokens_details'];
    // 每次请求独立：服务端没有返回缓存字段就表示未知，不沿用上次结果。
    lastCachedTokens = null;
    var cached = promptDetails is Map
        ? _intOf(promptDetails['cached_tokens'])
        : null;
    cached ??= inputDetails is Map
        ? _intOf(inputDetails['cached_tokens'])
        : null;
    cached ??= _intOf(usage['cached_tokens']);
    cached ??= _intOf(usage['cached_input_tokens']);
    cached ??= _intOf(usage['cache_read_input_tokens']);
    if (cached != null && cached >= 0) {
      lastCachedTokens = cached;
    }
  }

  static int? _intOf(Object? v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  /// 从流式 chunk 里提取思考文本，兼容字符串、嵌套 List 和
  /// {summary/text/content/thinking/thought/delta/value} 对象；
  /// 空值统一返回 null，方便逐字段回退。
  static String? extractReasoningValue(Object? value) {
    if (value is String) {
      return value.trim().isEmpty ? null : value;
    }
    if (value is List) {
      final parts = <String>[];
      for (final item in value) {
        final s = extractReasoningValue(item);
        if (s != null) parts.add(s);
      }
      return parts.isEmpty ? null : parts.join();
    }
    if (value is Map) {
      for (final key in const [
        'summary',
        'text',
        'content',
        'thought',
        'thinking',
        'delta',
        'value',
      ]) {
        final s = extractReasoningValue(value[key]);
        if (s != null) return s;
      }
    }
    return null;
  }

  Map<String, dynamic>? _tryDecode(String s) {
    try {
      return jsonDecode(s) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }
}
