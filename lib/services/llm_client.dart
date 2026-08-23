import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/reasoning_models.dart';
import 'socks5_config.dart';

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
  final String protocol; // openai | anthropic
  final double temperature;
  final int maxTokens;
  final List<Map<String, dynamic>> tools;
  final void Function(TurnResult turn)? onTurn;
  final void Function(String error)? onError;
  final bool Function()? shouldStop;

  /// 拾忆主会话的显式思考强度；null 表示沿用模型默认推断。
  /// 该字段不承载 DSH 的会话模型协议。
  final String? reasoningEffortOverride;

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

  /// 单行 SSE 缓冲上限（防无界增长）。
  static const int _maxLineBufferChars = 1024 * 1024;

  /// 最近一轮收到的文本（纯文本截断续写时拼接用）。
  String _lastRoundText = '';

  /// 最近一轮收到的思考内容（thinking 模式网关要求续写时必须
  /// 把 reasoning_content 一起回传，否则 HTTP 400）。
  String _lastRoundReasoning = '';

  LlmClient({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.protocol = 'openai',
    required this.temperature,
    this.maxTokens = 8192,
    required this.tools,
    this.onTurn,
    this.onError,
    this.shouldStop,
    this.reasoningEffortOverride,
    this.onDiag,
  });

  String get _endpoint {
    final root = protocol == 'anthropic'
        ? normalizeAnthropicBaseUrl(baseUrl)
        : baseUrl.replaceAll(RegExp(r'/*$'), '');
    return protocol == 'anthropic'
        ? '$root/v1/messages'
        : '$root/chat/completions';
  }

  /// Anthropic 自定义网关兼容：去掉结尾的 /v1，避免拼成 /v1/v1/messages。
  static String normalizeAnthropicBaseUrl(String url) {
    return url
        .replaceAll(RegExp(r'/*$'), '')
        .replaceFirst(RegExp(r'/v1$', caseSensitive: false), '');
  }

  Map<String, String> _headers({required bool streaming}) => <String, String>{
    'Content-Type': 'application/json',
    if (streaming) 'Accept': 'text/event-stream',
    if (apiKey.isNotEmpty && protocol == 'openai')
      'Authorization': 'Bearer $apiKey',
    if (apiKey.isNotEmpty && protocol == 'anthropic') 'x-api-key': apiKey,
    if (protocol == 'anthropic') 'anthropic-version': '2023-06-01',
  };

  /// 续写指令：上一轮只输出了计划且没有实际工具调用时，改用“工具唤醒”提示，
  /// 避免模型把“继续写文字”理解成继续描述计划而不是执行工具。
  static String buildContinuationPrompt(
    String lastText, {
    bool hasTools = false,
  }) {
    final t = lastText.trim();
    final toolKick = hasTools && (t.endsWith('：') || t.endsWith(':'));
    return toolKick
        ? '你刚才只输出了计划或开场白，还没有实际执行任何工具。'
              '不要继续输出计划、承诺或重复文字；'
              '现在直接调用需要的工具完成用户请求，'
              '全部执行完后再给出最终结果。'
        : '继续完成上述输出。直接从上次断点继续写，'
              '不要重复已经输出的内容。';
  }

  Future<void> send(List<Map<String, dynamic>> messages) async {
    lastTotalTokens = null;
    lastPromptTokens = null;
    lastOutputTokens = null;
    lastInputTokens = null;
    lastCachedTokens = null;
    _lastRoundReasoning = '';
    final client = await Socks5Proxy.client();
    try {
      var includeUsage = true;
      // 部分网关/中转不支持过大的 max_tokens：HTTP 400 时自动降级到 8192 重试。
      var outputLimit = maxTokens;
      // 明显思考型模型默认请求思考输出；网关拒绝 thinking / reasoning_effort
      // 时分别去掉不兼容字段重试，普通模型/旧网关不受影响。
      // `thinking: {type: enabled}` 只对 DeepSeek 官方 API（api.deepseek.com）
      // 下发：opencode.ai/zen 等网关不识别该参数时会把思考链灌进 content
      // （真机复现：textLen=20 reasoningLen=0 tail=用户用英文问好…），
      // 它们只用 reasoning_effort，思考走 delta.reasoning 字段。
      final profile = ReasoningModels.profile(model);
      String? reasoningEffort =
          reasoningEffortOverride ?? profile?.defaultEffort;
      var thinkingEnabled =
          reasoningEffortOverride != 'off' &&
          reasoningEffort != null &&
          reasoningEffort.isNotEmpty &&
          reasoningEffort != 'off' &&
          ((profile?.usesDeepSeekThinkingParam == true &&
                  baseUrl.contains('deepseek.com')) ||
              (protocol == 'anthropic' &&
                  profile?.usesAnthropicThinking == true));
      // 网关拒绝 max_completion_tokens 时回退 max_tokens（旧网关兼容）。
      var useMaxCompletion = _useMaxCompletionTokens;
      // 续写轮追加的消息：纯文本被截断时，把已输出内容 + 「继续」指令发回，
      // 模型从断点继续（不重发整轮，不丢已输出）。
      final continuation = <Map<String, dynamic>>[];
      for (var round = 0; round < 3; round++) {
        final body = _buildRequestBody(
          messages: [...messages, ...continuation],
          stream: true,
          includeUsage: includeUsage,
          maxTokens: outputLimit,
          thinkingEnabled: thinkingEnabled,
          reasoningEffort: reasoningEffort,
          useMaxCompletionTokens: useMaxCompletion,
        );
        final request = http.Request('POST', Uri.parse(_endpoint))
          ..headers.addAll(_headers(streaming: true))
          ..body = jsonEncode(body);
        onDiag?.call(
          '[stream] request model=$model '
          'thinking=${thinkingEnabled ? 'on' : 'off'} '
          'reasoningEffort=${reasoningEffort ?? 'off'} '
          'tokenField=${useMaxCompletion ? 'max_completion_tokens' : 'max_tokens'}',
        );
        // 完整请求体诊断（无密钥；截断防爆日志）。
        {
          final bodyPreview = jsonEncode(body);
          onDiag?.call(
            '[reqbody] ${bodyPreview.length <= 2000 ? bodyPreview : '${bodyPreview.substring(0, 2000)}…'}',
          );
        }
        try {
          final response = await client
              .send(request)
              .timeout(const Duration(seconds: 60));
          if (response.statusCode != 200) {
            final err = await response.stream.bytesToString();
            // 思考参数被网关拒绝：先分别去掉不兼容字段重试。
            final e = err.toLowerCase();
            if (useMaxCompletion && e.contains('max_completion_tokens')) {
              useMaxCompletion = false;
              onDiag?.call('[stream] max_completion_tokens 被拒绝，回退 max_tokens');
              continue;
            }
            if (thinkingEnabled &&
                (e.contains('thinking') || e.contains('budget_tokens'))) {
              thinkingEnabled = false;
              onDiag?.call('[stream] thinking 参数被网关拒绝，去掉后重试');
              continue;
            }
            if (reasoningEffort != null && e.contains('reasoning_effort')) {
              reasoningEffort = null;
              onDiag?.call('[stream] reasoning_effort 被网关拒绝，去掉后重试');
              continue;
            }
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
          final needContinue = protocol == 'anthropic'
              ? await _parseAnthropicSse(response.stream)
              : await _parseOpenAiSse(response.stream);
          if (!needContinue) return;
          // 纯文本截断：追加已输出 + 继续指令，发起续写请求。
          final lastText = _lastRoundText.trim();
          final toolKick =
              tools.isNotEmpty &&
              (lastText.endsWith('：') || lastText.endsWith(':'));
          onDiag?.call(
            '[stream] 续写第 ${round + 1} 轮${toolKick ? ' (工具唤醒)' : ''}',
          );
          continuation.addAll([
            {
              'role': 'assistant',
              'content': _lastRoundText,
              // thinking 模式网关（OpenCode Go 等）要求 reasoning_content
              // 必须原样回传，否则上游 HTTP 400 拒绝续写请求。
              if (_lastRoundReasoning.isNotEmpty)
                'reasoning_content': _lastRoundReasoning,
            },
            {
              'role': 'user',
              'content': buildContinuationPrompt(
                lastText,
                hasTools: tools.isNotEmpty,
              ),
            },
          ]);
          includeUsage = false;
        } on TimeoutException {
          // 瞬态超时（网络抖动/网关繁忙）：首轮自动重试一次。
          if (round == 0) {
            onDiag?.call('[stream] 请求超时，自动重试一次');
            continue;
          }
          throw LlmException('请求超时：网络连接或响应过慢，请重试');
        } on http.ClientException catch (e) {
          final m = e.message;
          // 连接类瞬态错误（连接超时/拒绝/断连/DNS 失败）：首轮自动重试
          // 一次；仍失败则转成可读的中文提示，不再把原始
          // "ClientException with SocketException ..." 直接抛给界面。
          if (round == 0 &&
              (m.contains('timed out') ||
                  m.contains('SocketException') ||
                  m.contains('Connection refused') ||
                  m.contains('Connection reset') ||
                  m.contains('Failed host lookup'))) {
            onDiag?.call('[stream] 连接异常，自动重试一次: $m');
            continue;
          }
          throw LlmException('网络连接失败：${_short(m)}，请检查网络/代理或稍后重试');
        }
      }
    } finally {
      client.close();
    }
  }

  /// 判断 HTTP 400 是否由 stream_options/include_usage 参数不被支持引起。
  Map<String, dynamic> _buildRequestBody({
    required List<Map<String, dynamic>> messages,
    required bool stream,
    required bool includeUsage,
    required int maxTokens,
    bool thinkingEnabled = false,
    String? reasoningEffort,
    bool? useMaxCompletionTokens,
  }) {
    if (protocol == 'anthropic') {
      final systemParts = <String>[];
      final apiMessages = <Map<String, dynamic>>[];
      for (final m in messages) {
        if (m['role'] == 'system') {
          final c = (m['content'] ?? '').toString().trim();
          if (c.isNotEmpty) systemParts.add(c);
        } else {
          apiMessages.add(m);
        }
      }
      final effort = reasoningEffort;
      final thinkingOn =
          thinkingEnabled &&
          effort != null &&
          effort.isNotEmpty &&
          effort != 'off';
      return <String, dynamic>{
        'model': model,
        if (systemParts.isNotEmpty) 'system': systemParts.join('\n\n'),
        'messages': _toAnthropicMessages(apiMessages),
        'max_tokens': maxTokens,
        'stream': stream,
        // extended thinking 开启时 Anthropic 要求不传 temperature。
        if (!thinkingOn) 'temperature': temperature,
        if (thinkingOn)
          'thinking': {
            'type': 'enabled',
            'budget_tokens': ReasoningModels.anthropicBudget(effort, maxTokens),
          },
        if (tools.isNotEmpty) 'tools': _toAnthropicTools(tools),
        if (tools.isNotEmpty)
          'tool_choice': {'type': 'auto', 'disable_parallel_tool_use': false},
      };
    }
    final effortField = _openAiReasoningEffort(reasoningEffort);
    return <String, dynamic>{
      'model': model,
      'messages': messages,
      'stream': stream,
      if (includeUsage) 'stream_options': {'include_usage': true},
      // 思考模式（reasoning_effort）下不发送 temperature 与 tool_choice：
      // 与 DSH 引擎走通该网关的请求（llm-pi-ai/pi-ai）逐字段对齐——
      // pi-ai 仅在调用方显式传值时才带这两个字段，而 DSH agent 请求
      // 从不带；真机对照：带 temperature=0.2 + tool_choice=auto 时网关把
      // 思考链折叠进 content（reasoning_content 恒 null），DSH 引擎不带
      // 时 reasoning_content 正常下发。
      if (effortField == null || effortField.isEmpty)
        'temperature': temperature,
      // opencode.ai 等 OpenAI 风格网关用 max_completion_tokens 区分新旧
      // 请求路径（与 DSH 内置 pi-ai 的 detectCompat 一致）；发 max_tokens
      // 时网关会把思考链折叠进 content（真机原始 SSE 帧实证：
      // delta.content=思考链, delta.reasoning_content=null）。
      if (useMaxCompletionTokens ?? _useMaxCompletionTokens)
        'max_completion_tokens': maxTokens
      else
        'max_tokens': maxTokens,
      if (thinkingEnabled) 'thinking': {'type': 'enabled'},
      if (effortField != null && effortField.isNotEmpty)
        'reasoning_effort': effortField,
      if (tools.isNotEmpty) 'tools': tools,
      // tool_choice 与 pi-ai 对齐：不显式发送（OpenAI 默认 auto）。
    };
  }

  /// GPT-5 关闭思考发 `none`；其余模型沿用 `off` / 档位原值。
  String? _openAiReasoningEffort(String? effort) {
    if (effort == null || effort.isEmpty) return effort;
    if (effort == 'off' &&
        ReasoningModels.profile(model)?.usesNoneForOff == true) {
      return 'none';
    }
    return effort;
  }

  /// 与 DSH 内置 pi-ai（detectCompat）保持一致的网关判定：
  /// 只有少数网关/中转用 max_tokens 字段，其余（含 opencode.ai/zen）
  /// 走 max_completion_tokens，否则思考链会被折叠进正文。
  bool get _useMaxCompletionTokens {
    final b = baseUrl.toLowerCase();
    if (protocol != 'openai') return false;
    final useMaxTokens =
        b.contains('chutes.ai') ||
        b.contains('api.moonshot.') ||
        b.contains('cloudflare') ||
        b.contains('api.together.ai') ||
        b.contains('api.together.xyz') ||
        b.contains('nvidia') ||
        b.contains('ant-ling') ||
        b.contains('deepseek.com');
    return !useMaxTokens;
  }

  List<Map<String, dynamic>> _toAnthropicMessages(
    List<Map<String, dynamic>> messages,
  ) {
    final out = <Map<String, dynamic>>[];
    for (final m in messages) {
      final role = m['role'];
      if (role == 'tool') {
        out.add({
          'role': 'user',
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': (m['tool_call_id'] ?? '').toString(),
              'content': (m['content'] ?? '').toString(),
            },
          ],
        });
        continue;
      }
      final toolCalls = m['tool_calls'];
      if (role == 'assistant' && toolCalls is List && toolCalls.isNotEmpty) {
        final content = <Map<String, dynamic>>[];
        final text = (m['content'] ?? '').toString();
        if (text.trim().isNotEmpty) {
          content.add({'type': 'text', 'text': text});
        }
        for (final raw in toolCalls) {
          final tc = raw is Map<String, dynamic> ? raw : <String, dynamic>{};
          final fn = tc['function'] is Map<String, dynamic>
              ? tc['function'] as Map<String, dynamic>
              : <String, dynamic>{};
          content.add({
            'type': 'tool_use',
            'id': (tc['id'] ?? '').toString(),
            'name': (fn['name'] ?? '').toString(),
            'input': _decodeArguments(fn['arguments']),
          });
        }
        out.add({'role': 'assistant', 'content': content});
        continue;
      }
      out.add({'role': role, 'content': (m['content'] ?? '').toString()});
    }
    return out;
  }

  Map<String, dynamic> _decodeArguments(Object? raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        final d = jsonDecode(raw);
        if (d is Map<String, dynamic>) return d;
      } catch (_) {}
    }
    return const {};
  }

  List<Map<String, dynamic>> _toAnthropicTools(
    List<Map<String, dynamic>> tools,
  ) {
    return tools.map((t) {
      final fn = t['function'] is Map<String, dynamic>
          ? t['function'] as Map<String, dynamic>
          : <String, dynamic>{};
      final params = fn['parameters'];
      return <String, dynamic>{
        'name': (fn['name'] ?? '').toString(),
        'description': (fn['description'] ?? '').toString(),
        'input_schema': params is Map<String, dynamic>
            ? params
            : const <String, dynamic>{'type': 'object', 'properties': {}},
      };
    }).toList();
  }

  static bool _isUsageParamError(String err) {
    final e = err.toLowerCase();
    return e.contains('stream_options') ||
        e.contains('include_usage') ||
        e.contains('unknown parameter') ||
        e.contains('unknown argument') ||
        e.contains('extra fields');
  }

  /// 与 DSH 模型同步一致的默认思考档位判定。
  static String? defaultReasoningEffort(String model) =>
      ReasoningModels.defaultEffort(model);

  /// 根据模型名返回支持的思考强度档位列表；不支持思考的模型返回 null。
  static Map<String, String?>? reasoningEffortsForModel(String model) =>
      ReasoningModels.effortsFor(model);

  /// DeepSeek 风格的兼容接口需要 `thinking: {type: enabled}` 才会真正
  /// 推送 reasoning_content；OpenAI 风格模型仍只使用 reasoning_effort。
  static bool usesDeepSeekThinkingParam(String model) =>
      ReasoningModels.usesDeepSeekThinkingParam(model);

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
    final body = _buildRequestBody(
      messages: messages,
      stream: false,
      includeUsage: false,
      maxTokens: maxTokens ?? this.maxTokens,
    );
    final request = http.Request('POST', Uri.parse(_endpoint))
      ..headers.addAll(_headers(streaming: false))
      ..body = jsonEncode(body);

    final client = await Socks5Proxy.client();
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
      if (protocol == 'anthropic') {
        final blocks = json['content'] as List<dynamic>? ?? [];
        final parts = <String>[];
        for (final b in blocks) {
          if (b is Map<String, dynamic> && b['type'] == 'text') {
            final t = (b['text'] ?? '').toString().trim();
            if (t.isNotEmpty) parts.add(t);
          }
        }
        return parts.join('\n');
      }
      final choices = json['choices'] as List<dynamic>? ?? [];
      if (choices.isEmpty) return '';
      final msg = choices.first['message'] as Map<String, dynamic>?;
      return (msg?['content'] as String?)?.trim() ?? '';
    } on TimeoutException {
      throw LlmException('请求超时：网络连接或响应过慢，请重试');
    } on http.ClientException catch (e) {
      throw LlmException('网络连接失败：${_short(e.message)}，请检查网络/代理或稍后重试');
    } finally {
      client.close();
    }
  }

  /// 获取模型列表，返回模型 id。
  /// OpenAI 兼容走 GET `{base}/models`；Anthropic Messages 走 GET `{root}/v1/models`。
  Future<List<String>> listModels() async {
    if (protocol == 'anthropic') {
      return _listAnthropicModels();
    }
    final url = '${baseUrl.replaceAll(RegExp(r'/*$'), '')}/models';
    return (await _fetchModelsPage(Uri.parse(url))).ids;
  }

  /// Anthropic 官方与兼容网关：GET /v1/models，按 last_id 翻页直到没有更多。
  Future<List<String>> _listAnthropicModels() async {
    final root = normalizeAnthropicBaseUrl(baseUrl);
    final ids = <String>[];
    String? afterId;
    final client = await Socks5Proxy.client();
    try {
      for (var i = 0; i < 20; i++) {
        final uri = Uri.parse('$root/v1/models').replace(
          queryParameters: {
            'limit': '100',
            if (afterId != null && afterId.isNotEmpty) 'after_id': afterId,
          },
        );
        final fetched = await _fetchModelsPage(uri, client: client);
        ids.addAll(fetched.ids);
        if (fetched.ids.isEmpty) break;
        afterId = fetched.lastId;
        if (!fetched.hasMore || afterId == null || afterId.isEmpty) break;
      }
      return ids;
    } finally {
      client.close();
    }
  }

  Future<({List<String> ids, bool hasMore, String? lastId})> _fetchModelsPage(
    Uri uri, {
    http.Client? client,
  }) async {
    final owned = client == null;
    final httpClient = client ?? await Socks5Proxy.client();
    try {
      final res = await httpClient
          .get(uri, headers: _headers(streaming: false))
          .timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        throw LlmException('HTTP ${res.statusCode}: ${_short(res.body)}');
      }
      final json = _tryDecode(res.body);
      if (json == null) throw LlmException('响应解析失败');
      final data = json['data'] as List<dynamic>? ?? [];
      final ids = data
          .map(
            (e) =>
                (e is Map<String, dynamic>) ? (e['id']?.toString() ?? '') : '',
          )
          .where((s) => s.isNotEmpty)
          .toList();
      return (
        ids: ids,
        hasMore: json['has_more'] == true,
        lastId: json['last_id']?.toString(),
      );
    } finally {
      if (owned) httpClient.close();
    }
  }

  /// 测试模型连通性：发送 hi，返回 HTTP 状态与简要结果。
  Future<String> testChat() async {
    final body = _buildRequestBody(
      messages: [
        {'role': 'user', 'content': 'hi'},
      ],
      stream: false,
      includeUsage: false,
      maxTokens: 8,
    );
    final request = http.Request('POST', Uri.parse(_endpoint))
      ..headers.addAll(_headers(streaming: false))
      ..body = jsonEncode(body);
    final client = await Socks5Proxy.client();
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

  Future<bool> _parseOpenAiSse(Stream<List<int>> raw) async {
    final lineBuffer = StringBuffer(); // 行缓冲
    String text = '';
    String reasoning = '';
    final toolBuf = <int, Map<String, String>>{};
    var doneReceived = false;
    var stoppedByUser = false;
    var reasoningSeeded = false;
    var rawFramesLeft = 25;
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
        // 工具调用不完整（参数半截）：无法续写，抛给上层整轮重试。
        completer.completeError(LlmInterruptedException('工具调用被截断，交上层整轮重试'));
        return false;
      }
      // 思考把输出预算吃完、正文还没开始：空正文续写没有断点，
      // 抛给上层整轮重试，让上层提示模型输出正文而不是继续思考。
      if (finishReason == 'length' && t.isEmpty) {
        completer.completeError(
          LlmInterruptedException('回复中断：模型输出被截断且没有正文，交上层整轮重试'),
        );
        return false;
      }
      return true; // 纯文本截断：续写
    }

    void handleLine(String line) {
      if (line.isEmpty) return;
      if (line.startsWith('data:')) {
        final data = line.substring(5).trim();
        // 受控原始帧诊断：每轮前 25 个 data 帧截断落盘，用于定位网关
        // 实际下发的思考字段（reasoning / reasoning_content / content）。
        if (rawFramesLeft > 0) {
          rawFramesLeft--;
          final preview = data.length <= 500
              ? data
              : '${data.substring(0, 500)}…';
          onDiag?.call('[sse] $preview');
        }
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
            lineBuffer.write(chunk);
            // 单行无界增长防护：异常长行（网关异常/恶意流）不会无限占内存，
            // 超限整段强制按一行处理（解析失败即丢弃）。
            if (lineBuffer.length > _maxLineBufferChars) {
              handleLine(lineBuffer.toString());
              lineBuffer.clear();
              return;
            }
            var s = lineBuffer.toString();
            int idx;
            while ((idx = s.indexOf('\n')) != -1) {
              final line = s.substring(0, idx).trimRight();
              s = s.substring(idx + 1);
              handleLine(line);
            }
            lineBuffer.clear();
            lineBuffer.write(s);
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
            if (lineBuffer.isNotEmpty) {
              final rest = lineBuffer.toString();
              if (rest.trim().isNotEmpty) {
                for (final line in rest.split('\n')) {
                  handleLine(line);
                }
              }
              lineBuffer.clear();
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
            _lastRoundReasoning = reasoning;
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

  /// Anthropic Messages API 流式解析（SSE event + data）。
  Future<bool> _parseAnthropicSse(Stream<List<int>> raw) async {
    final buffer = StringBuffer();
    String text = '';
    String reasoning = '';
    final toolBuf = <int, Map<String, String>>{};
    var doneReceived = false;
    var stoppedByUser = false;
    String? stopReason;
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
      final truncated = stopReason == 'max_tokens' || halfCut;
      if (!truncated) return false;
      if (toolsComplete) return false;
      if (toolBuf.isNotEmpty) {
        completer.completeError(LlmInterruptedException('工具调用被截断，正在自动重试'));
        return false;
      }
      if (stopReason == 'max_tokens' && t.isEmpty) {
        completer.completeError(
          LlmInterruptedException('回复中断：模型输出被截断且没有正文，正在自动重试'),
        );
        return false;
      }
      return true;
    }

    void handleLine(String line) {
      if (line.isEmpty) return;
      if (line.startsWith('data:')) {
        final data = line.substring(5).trim();
        if (data.isEmpty) return;
        final json = _tryDecode(data);
        if (json == null) return;
        final type = json['type'];
        if (type == 'message_start') {
          final message = json['message'];
          if (message is Map<String, dynamic>) {
            final usage = message['usage'];
            if (usage is Map<String, dynamic>) applyUsage(usage);
          }
        } else if (type == 'content_block_start') {
          final index = (json['index'] as num?)?.toInt() ?? 0;
          final cb = json['content_block'];
          if (cb is Map<String, dynamic> && cb['type'] == 'tool_use') {
            toolBuf[index] = {
              'id': (cb['id'] ?? '').toString(),
              'name': (cb['name'] ?? '').toString(),
              'arguments': '',
            };
          }
        } else if (type == 'content_block_delta') {
          final index = (json['index'] as num?)?.toInt() ?? 0;
          final delta = json['delta'];
          if (delta is Map<String, dynamic>) {
            final deltaType = delta['type'];
            if (deltaType == 'text_delta') {
              final chunk = delta['text'];
              if (chunk is String && chunk.isNotEmpty) {
                text += chunk;
                emitPartial();
              }
            } else if (deltaType == 'thinking_delta') {
              final chunk = delta['thinking'];
              if (chunk is String && chunk.isNotEmpty) {
                reasoning += chunk;
                emitPartial();
              }
            } else if (deltaType == 'input_json_delta') {
              final cur = toolBuf[index];
              if (cur != null) {
                final partial = delta['partial_json'];
                if (partial is String && partial.isNotEmpty) {
                  cur['arguments'] = cur['arguments']! + partial;
                }
              }
            }
          }
        } else if (type == 'message_delta') {
          final delta = json['delta'];
          if (delta is Map<String, dynamic>) {
            final sr = delta['stop_reason'];
            if (sr is String && sr.isNotEmpty) stopReason = sr;
          }
          final usage = json['usage'];
          if (usage is Map<String, dynamic>) applyUsage(usage);
        } else if (type == 'message_stop') {
          doneReceived = true;
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
            buffer.write(chunk);
            // 单行无界增长防护：异常长行不会无限占内存，超限整段强制处理。
            if (buffer.length > _maxLineBufferChars) {
              handleLine(buffer.toString());
              buffer.clear();
              return;
            }
            var s = buffer.toString();
            int idx;
            while ((idx = s.indexOf('\n')) != -1) {
              final line = s.substring(0, idx).trimRight();
              s = s.substring(idx + 1);
              handleLine(line);
            }
            buffer.clear();
            buffer.write(s);
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
            if (buffer.isNotEmpty) {
              final rest = buffer.toString();
              if (rest.trim().isNotEmpty) {
                for (final line in rest.split('\n')) {
                  handleLine(line);
                }
              }
              buffer.clear();
            }
            if (text.isNotEmpty || toolBuf.isNotEmpty || reasoning.isNotEmpty) {
              onTurn?.call(
                TurnResult(
                  text: text.trim(),
                  reasoning: reasoning,
                  toolCalls: _snapshotTools(toolBuf),
                ),
              );
            }
            final needContinue = decideContinue();
            _lastRoundText = text.trim();
            _lastRoundReasoning = reasoning;
            if (!completer.isCompleted) {
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
    // DeepSeek 官方风格：prompt_cache_hit_tokens（主）+ cache_miss_tokens
    //（配套未命中字段，用于命中率分母校验）。
    cached ??= _intOf(usage['prompt_cache_hit_tokens']);
    final cacheMiss =
        _intOf(usage['prompt_cache_miss_tokens']) ??
        (promptDetails is Map
            ? _intOf(promptDetails['cache_miss_tokens'])
            : null);
    if (cached == null && cacheMiss != null) {
      // 只有未命中字段时按 input - miss 反推命中（DeepSeek 兼容网关兜底）。
      final input =
          _intOf(usage['input_tokens']) ?? _intOf(usage['prompt_tokens']);
      if (input != null && input >= 0) {
        cached = (input - cacheMiss).clamp(0, input);
      }
    }
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
