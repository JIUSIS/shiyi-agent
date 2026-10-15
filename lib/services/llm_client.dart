import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/reasoning_models.dart';
import 'llm_error.dart';
import '../core/text_safe.dart';
import 'runtime_logger.dart';
import 'socks5_config.dart';

class LlmException implements Exception {
  final String message;
  LlmException(this.message);
  @override
  String toString() => message;
}

/// HTTP 错误：保留状态码、供应商错误码和参数名，避免 400 只剩一段模糊文本。
class LlmHttpException extends LlmException {
  final LlmErrorInfo info;
  final String rawBody;

  LlmHttpException(this.info, this.rawBody) : super(info.userMessage);

  int get statusCode => info.statusCode;
  bool get retryable => info.retryable;
}

/// 流式回复提前中断（未收到 [DONE] 或连接断开），可自动重试。
class LlmInterruptedException extends LlmException {
  LlmInterruptedException(super.message);
}

/// 用户主动停止当前请求。与网络断流区分开，禁止进入自动重试路径。
class LlmCancelledException extends LlmException {
  LlmCancelledException([super.message = '生成已停止']);
}

/// Result emitted for each assistant turn.
class TurnResult {
  final String text;
  final List<Map<String, String>> toolCalls; // [{id,name,arguments}]
  final String reasoning; // 模型思考内容（reasoning_content）
  final String reasoningEncrypted; // Responses encrypted_content，原样回放

  /// 出口统一做 UTF-16 净化：流式拼接/截断一旦切出孤立代理项，
  /// Flutter 文字引擎会抛 `string is not well-formed UTF-16`，整列表渲染失败
  /// （见 docs/fix-log.md #405）。这里挡在 UI 之前。
  TurnResult({
    String text = '',
    String reasoning = '',
    this.reasoningEncrypted = '',
    List<Map<String, String>>? toolCalls,
  }) : text = sanitizeUtf16(text),
       reasoning = sanitizeUtf16(reasoning),
       toolCalls = toolCalls ?? [];
}

/// OpenAI-compatible streaming client with SSE parsing and tool calls.
class LlmClient {
  final String baseUrl;
  final String apiKey;
  final String model;
  final String protocol; // openai | anthropic | responses
  final String sessionId;
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

  /// 等待响应头 / 流中途无数据的上限。思考型模型可能在网关侧先推理很久才
  /// 出第一个字节，按普通 HTTP 超时砍会误杀（表现为「思考到一半就停了」）。
  /// 同一个值同时用于「等响应头」和「流空闲」，都可由用户配置。
  final Duration streamWaitTimeout;

  /// 被输出上限截断后的自动续写轮数上限（0 = 不续写，只标记不完整）。
  final int maxContinuationRounds;

  /// 最近一次请求的结束原因（Chat 的 finish_reason、Anthropic 的 stop_reason、
  /// Responses 的 incomplete 推导）。`length` / `max_tokens` 表示被输出上限截断。
  String? lastFinishReason;

  /// 本次 send 实际发起的续写轮数。
  int continuationRounds = 0;

  /// 续写预算用尽（或续写无进展）时仍处于截断状态：上层必须告知用户原因，
  /// 不能当成正常完成。
  bool endedIncomplete = false;

  /// 最近一轮是否因连接断开/空闲超时而提前结束（用于续写恢复判定）。
  bool lastRoundInterrupted = false;

  /// 跨续写轮累计的正文/思考（供上层直接取用，避免只看到最后一轮）。
  String get accumulatedText => _displayText;
  String get accumulatedReasoning => _displayReasoning;

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

  /// 单行 SSE 缓冲上限（只用于诊断告警，不再据此丢数据）。
  static const int _maxLineBufferChars = 4 * 1024 * 1024;

  /// 最近一轮收到的文本（纯文本截断续写时拼接用）。
  String _lastRoundText = '';

  /// 最近一轮收到的原始文本（未 trim，续写拼接按字节衔接，不丢中间空格）。
  String _roundTextRaw = '';

  /// 跨续写轮累计的正文（emit 时前缀拼给上层，避免只保留最后一轮）。
  String _displayText = '';

  /// 跨续写轮累计的思考内容。
  String _displayReasoning = '';

  /// 续写轮开头与上一轮结尾重复的字符数（展示时跳过，避免同一句出现两遍）。
  int _roundSkip = 0;

  /// 本轮是否还需要判定开头的重复段（首轮或已判定则为 false）。
  bool _roundTrimPending = false;

  /// 判定接缝重复时最多看本轮前多少字符（超过就认为没有重复）。
  static const int _overlapProbeLimit = 300;

  /// 最近一轮收到的思考内容（thinking 模式网关要求续写时必须
  /// 把 reasoning_content 一起回传，否则 HTTP 400）。
  String _lastRoundReasoning = '';

  /// Responses 加密思考，续写/工具轮必须原样回放。
  String _lastRoundReasoningEncrypted = '';

  /// 当前传输客户端。停止时关闭它，底层 SSE/HTTP Future 会立即结束。
  http.Client? _activeHttpClient;
  bool _cancelRequested = false;

  /// 「静默结束」（既没有 finish_reason 也没有 [DONE]）只补一次续写确认，
  /// 避免对本来就不发 [DONE] 的网关每轮多打一次请求。
  bool _silentEndResumed = false;

  LlmClient({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.protocol = 'openai',
    this.sessionId = '',
    required this.temperature,
    this.maxTokens = 8192,
    required this.tools,
    this.onTurn,
    this.onError,
    this.shouldStop,
    this.reasoningEffortOverride,
    this.onDiag,
    this.streamWaitTimeout = const Duration(minutes: 10),
    this.maxContinuationRounds = 16,
  });

  bool get _isResponses => protocol == 'responses';

  bool get isCancelled => _cancelRequested;

  /// 立即取消当前流式请求。可在 [send] 尚未拿到响应头时调用。
  void cancel() {
    _cancelRequested = true;
    _activeHttpClient?.close();
  }

  void _throwIfCancelled() {
    if (_cancelRequested || (shouldStop?.call() ?? false)) {
      throw LlmCancelledException();
    }
  }

  String get _endpoint {
    if (protocol == 'anthropic') {
      return '${normalizeAnthropicBaseUrl(baseUrl)}/v1/messages';
    }
    if (_isResponses) {
      return '${normalizeResponsesBaseUrl(baseUrl)}/responses';
    }
    return '${baseUrl.replaceAll(RegExp(r'/*$'), '')}/chat/completions';
  }

  /// Anthropic 自定义网关兼容：去掉结尾的 /v1，避免拼成 /v1/v1/messages。
  static String normalizeAnthropicBaseUrl(String url) {
    return url
        .replaceAll(RegExp(r'/*$'), '')
        .replaceFirst(RegExp(r'/v1$', caseSensitive: false), '');
  }

  /// Responses 路径：一般是 {base}/responses。DeepSeek 官方文档是
  /// POST https://api.deepseek.com/responses，不是 /v1/responses。
  static String normalizeResponsesBaseUrl(String url) {
    final root = url.replaceAll(RegExp(r'/*$'), '');
    final uri = Uri.tryParse(root);
    if (uri != null &&
        (uri.host == 'api.deepseek.com' || uri.host == 'api.deepseek.ai')) {
      final scheme = uri.scheme.isEmpty ? 'https' : uri.scheme;
      return '$scheme://${uri.host}';
    }
    return root;
  }

  Map<String, String> _headers({required bool streaming}) => <String, String>{
    'Content-Type': 'application/json',
    if (streaming) 'Accept': 'text/event-stream',
    if (apiKey.isNotEmpty && protocol != 'anthropic')
      'Authorization': 'Bearer $apiKey',
    if (apiKey.isNotEmpty && protocol == 'anthropic') 'x-api-key': apiKey,
    if (protocol == 'anthropic') 'anthropic-version': '2023-06-01',
    if (protocol == 'anthropic') 'anthropic-beta': 'prompt-caching-2024-07-31',
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

  /// 续写拼接：模型被截断后重新生成时常会把上一段的结尾再抄一遍，
  /// 取最大重叠后拼上，避免同一句话出现两遍。重叠至少 [minOverlap] 个
  /// 字符才裁剪（单字符重叠多为正常接续用词，不做处理）。
  static String mergeContinuedText(
    String previous,
    String next, {
    int minOverlap = 2,
    int maxProbe = 2000,
  }) {
    if (previous.isEmpty) return next;
    if (next.isEmpty) return previous;
    var limit = previous.length < next.length ? previous.length : next.length;
    if (limit > maxProbe) limit = maxProbe;
    for (var n = limit; n >= minOverlap; n--) {
      if (previous.endsWith(next.substring(0, n))) {
        return previous + next.substring(n);
      }
    }
    return previous + next;
  }

  /// 本轮正文里「第一次与上一轮结尾重叠」的字符数判定：重叠段一定在开头，
  /// 一旦确认就越过了重叠段（本轮已写出新内容），之后固定不再变。
  void _resolveRoundOverlap(String roundText) {
    if (!_roundTrimPending) return;
    if (roundText.isEmpty || _displayText.isEmpty) return;
    final merged = mergeContinuedText(_displayText, roundText);
    final skip = _displayText.length + roundText.length - merged.length;
    if (skip <= 0) {
      // 开头没有重叠；本轮写得够长还是没有，就认为模型没重复上一段。
      if (roundText.length >= _overlapProbeLimit) _roundTrimPending = false;
      return;
    }
    if (roundText.length > skip) {
      _roundSkip = skip;
      _roundTrimPending = false;
    }
  }

  /// 本轮正文中真正要追加到累计正文里的部分（跳过接缝重复）。
  String _visibleRoundText(String roundText) {
    if (_roundSkip <= 0) return roundText;
    return _roundSkip >= roundText.length
        ? ''
        : roundText.substring(_roundSkip);
  }

  Future<void> send(List<Map<String, dynamic>> messages) async {
    lastTotalTokens = null;
    lastPromptTokens = null;
    lastOutputTokens = null;
    lastInputTokens = null;
    lastCachedTokens = null;
    _lastRoundText = '';
    _roundTextRaw = '';
    _lastRoundReasoning = '';
    _lastRoundReasoningEncrypted = '';
    _displayText = '';
    _displayReasoning = '';
    lastFinishReason = null;
    continuationRounds = 0;
    endedIncomplete = false;
    lastRoundInterrupted = false;
    _silentEndResumed = false;
    _roundSkip = 0;
    _roundTrimPending = false;
    final requestId =
        'llm_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    final requestStarted = DateTime.now();
    final client = await Socks5Proxy.client();
    _activeHttpClient = client;
    try {
      _throwIfCancelled();
      var includeUsage = true;
      // 输出上限（max_tokens）：**0 = 不限制** —— 不发该字段，用模型自身最大输出。
      // 不再对模型输出做人为掐断（这是本项目的红线，见 docs/fix-log.md #412）。
      final unlimitedOutput = maxTokens <= 0;
      // 部分网关/中转不支持过大的 max_tokens：HTTP 400 时自动降级重试。
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
      var sendStore = _isResponses;
      var sendParallel = tools.isNotEmpty;
      var sendInclude = _isResponses;
      // 续写轮追加的消息：纯文本被截断时，把已输出内容 + 「继续」指令发回，
      // 模型从断点继续（不重发整轮，不丢已输出）。
      final continuation = <Map<String, dynamic>>[];
      // 连接类瞬态错误的重试预算（**每一轮**都有，不只在首轮）。
      // 之前只在 round==0 重试，导致工具轮（round≥1）里一次断连就整轮失败，
      // 用户看到「网络连接失败」（见 docs/fix-log.md #405）。
      const maxConnectionRetries = 2;
      var connectionRetries = 0;
      // maxContinuationRounds <= 0 视为**不限制**：一直续写到模型自然结束，
      // 用极大值兜底避免 `for` 无法表达无限（真正的收口在「续写无新增内容」）。
      final roundCeiling = maxContinuationRounds > 0
          ? maxContinuationRounds
          : 1000000;
      for (var round = 0; round <= roundCeiling; round++) {
        _throwIfCancelled();
        connectionRetries = 0;
        final body = _buildRequestBody(
          messages: [...messages, ...continuation],
          stream: true,
          includeUsage: includeUsage,
          maxTokens: outputLimit,
          thinkingEnabled: thinkingEnabled,
          reasoningEffort: reasoningEffort,
          useMaxCompletionTokens: useMaxCompletion,
          sendStore: sendStore,
          sendParallel: sendParallel,
          sendInclude: sendInclude,
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
        // 请求体诊断：先写体积和内容类型（才能看见图片块），再截断正文。
        {
          final bodyPreview = jsonEncode(body);
          onDiag?.call(
            '[reqmeta] protocol=$protocol '
            'bytes=${utf8.encode(bodyPreview).length} ${_contentMeta(body)}',
          );
          onDiag?.call('[reqbody] ${_previewRequestBody(bodyPreview)}');
          unawaited(
            RuntimeLogger.instance.info(
              'LLM',
              'request.sent',
              sessionId: sessionId,
              requestId: requestId,
              data: {
                'protocol': protocol,
                'model': model,
                'endpoint': _safeEndpoint(_endpoint),
                'round': round + 1,
                // 0 = 不限制（请求体里不发 max_tokens）。截断排查先看这个值。
                'maxTokens': outputLimit,
                'stream': true,
                'bytes': utf8.encode(bodyPreview).length,
                'messages': messages.length,
                'tools': tools.length,
                'images': _imageCount(body),
                'cache': 'server_usage_pending',
              },
            ),
          );
        }
        try {
          _throwIfCancelled();
          // 等待上限 0 = 不限制（默认）：不套超时，一直等模型回包。
          final response = streamWaitTimeout > Duration.zero
              ? await client.send(request).timeout(streamWaitTimeout)
              : await client.send(request);
          _throwIfCancelled();
          if (response.statusCode != 200) {
            final err = await response.stream.bytesToString();
            _throwIfCancelled();
            unawaited(
              RuntimeLogger.instance.warn(
                'LLM',
                'response.status',
                sessionId: sessionId,
                requestId: requestId,
                durationMs: DateTime.now()
                    .difference(requestStarted)
                    .inMilliseconds,
                result: 'HTTP ${response.statusCode}',
                data: {
                  'protocol': protocol,
                  'model': model,
                  'statusCode': response.statusCode,
                  'round': round + 1,
                  'error': _short(err),
                },
              ),
            );
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
            if (reasoningEffort != null &&
                (e.contains('reasoning_effort') ||
                    _isVagueInvalidRequest(err))) {
              reasoningEffort = null;
              onDiag?.call('[stream] reasoning_effort 被网关拒绝，去掉后重试');
              continue;
            }
            if (sendStore &&
                (e.contains('store') || e.contains('previous_response_id'))) {
              sendStore = false;
              onDiag?.call('[stream] store/previous_response_id 被拒绝，去掉后重试');
              continue;
            }
            if (sendParallel && e.contains('parallel_tool_calls')) {
              sendParallel = false;
              onDiag?.call('[stream] parallel_tool_calls 被拒绝，去掉后重试');
              continue;
            }
            if (sendInclude &&
                (e.contains('include') || e.contains('encrypted_content'))) {
              sendInclude = false;
              onDiag?.call('[stream] include/encrypted_content 被拒绝，去掉后重试');
              continue;
            }
            // 部分网关/中转不支持 stream_options：去掉后重试一次（只少 token 统计，不影响内容）。
            if (includeUsage && _isUsageParamError(err)) {
              includeUsage = false;
              continue;
            }
            // max_tokens 被网关拒（超过该服务商硬上限）：逐步下调到它接受的
            // 值再试，而不是盲降固定数字（盲降仍可能超限）。
            if (outputLimit > 1024 && _isMaxTokensParamError(err)) {
              outputLimit = (outputLimit ~/ 2).clamp(1024, outputLimit);
              onDiag?.call('[stream] max_tokens 被拒，下调到 $outputLimit 重试');
              continue;
            }
            // 「不限制输出」时少发了 max_tokens，而个别协议（Anthropic）要求必填：
            // 补一个足够大的值再试一次，而不是直接失败。
            if (unlimitedOutput &&
                _isMaxTokensParamError(err) &&
                outputLimit <= 0) {
              outputLimit = 64000;
              onDiag?.call('[stream] 该协议要求 max_tokens，补 $outputLimit 重试');
              continue;
            }
            throw LlmHttpException(
              LlmErrorInfo.fromHttp(response.statusCode, err),
              err,
            );
          }
          // 新一轮开始：确认与上一轮结尾的重复段（续写接缝去重）。
          _roundSkip = 0;
          _roundTrimPending = _displayText.isNotEmpty;
          final needContinue = protocol == 'anthropic'
              ? await _parseAnthropicSse(response.stream)
              : _isResponses
              ? await _parseResponsesSse(response.stream)
              : await _parseOpenAiSse(response.stream);
          _throwIfCancelled();
          unawaited(
            RuntimeLogger.instance.info(
              'LLM',
              needContinue ? 'response.continue' : 'response.completed',
              sessionId: sessionId,
              requestId: requestId,
              durationMs: DateTime.now()
                  .difference(requestStarted)
                  .inMilliseconds,
              result: 'HTTP ${response.statusCode}',
              data: {
                'protocol': protocol,
                'model': model,
                'statusCode': response.statusCode,
                'round': round + 1,
                'inputTokens': lastInputTokens ?? lastPromptTokens ?? 0,
                'outputTokens': lastOutputTokens ?? 0,
                'totalTokens': lastTotalTokens ?? 0,
                'cachedTokens': lastCachedTokens ?? 0,
                'cacheKnown': lastCachedTokens != null,
                'textChars': _lastRoundText.length,
              },
            ),
          );
          if (!needContinue) return;
          // 服务商是否明确报了「输出到上限」。
          final providerTruncated =
              lastFinishReason == 'length' || lastFinishReason == 'max_tokens';
          // 续写预算用尽：模型仍被输出上限截断（或连接反复断），如实标记
          // 不完整（上层据此告知用户原因），绝不假装正常完成。
          if (round == roundCeiling) {
            endedIncomplete = providerTruncated || lastRoundInterrupted;
            onDiag?.call(
              '[stream] 续写轮数用尽（$roundCeiling 轮）：'
              'incomplete=$endedIncomplete',
            );
            return;
          }
          // 跨轮拼接：把本轮正文接到累计正文后面，重叠部分裁掉，
          // 否则上层只会看到最后一轮，前面的内容会整体丢失。
          final merged = mergeContinuedText(_displayText, _roundTextRaw);
          if (merged == _displayText && _lastRoundReasoning.isEmpty) {
            // 续写没有产出任何新内容：说明上一段其实已经写完，
            // 只有服务商明确报了截断才算不完整。
            endedIncomplete = providerTruncated;
            onDiag?.call('[stream] 续写无新增内容，收口（incomplete=$endedIncomplete）');
            return;
          }
          _displayText = sanitizeUtf16(merged);
          _displayReasoning += _lastRoundReasoning;
          continuationRounds = round + 1;
          // 纯文本截断：追加已输出 + 继续指令，发起续写请求。
          final lastText = _lastRoundText.trim();
          final toolKick =
              tools.isNotEmpty &&
              (lastText.endsWith('：') || lastText.endsWith(':'));
          onDiag?.call(
            '[stream] 续写第 ${round + 1} 轮${toolKick ? ' (工具唤醒)' : ''}'
            '${lastRoundInterrupted ? ' (断流恢复)' : ''}',
          );
          continuation.addAll([
            {
              'role': 'assistant',
              'content': _roundTextRaw,
              // thinking 模式网关（OpenCode Go 等）要求 reasoning_content
              // 必须原样回传，否则上游 HTTP 400 拒绝续写请求。
              if (_lastRoundReasoning.isNotEmpty)
                'reasoning_content': _lastRoundReasoning,
              if (_lastRoundReasoningEncrypted.isNotEmpty)
                'reasoning_encrypted': _lastRoundReasoningEncrypted,
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
          if (_cancelRequested || (shouldStop?.call() ?? false)) {
            throw LlmCancelledException();
          }
          // 瞬态超时（网络抖动/网关繁忙）：首轮自动重试一次。
          if (round == 0) {
            onDiag?.call('[stream] 请求超时，自动重试一次');
            unawaited(
              RuntimeLogger.instance.warn(
                'LLM',
                'request.retry',
                sessionId: sessionId,
                requestId: requestId,
                result: 'timeout',
                data: {'round': round + 1},
              ),
            );
            continue;
          }
          unawaited(
            RuntimeLogger.instance.error(
              'LLM',
              'request.failed',
              sessionId: sessionId,
              requestId: requestId,
              durationMs: DateTime.now()
                  .difference(requestStarted)
                  .inMilliseconds,
              result: 'timeout',
              data: {'round': round + 1},
            ),
          );
          throw LlmException(
            '等待模型响应已超过 ${streamWaitTimeout.inSeconds} 秒：'
            '可能是网络中断，也可能是模型长时间没出字。'
            '可在「设置 → 上下文 → 长推理等待上限」调大后重试。',
          );
        } on http.ClientException catch (e) {
          if (_cancelRequested || (shouldStop?.call() ?? false)) {
            throw LlmCancelledException();
          }
          final m = e.message;
          // 连接类瞬态错误（连接超时/拒绝/断连/DNS 失败）：**每一轮**都自动
          // 重试，最多 [maxConnectionRetries] 次（递增退避）；仍失败才转成
          // 可读的中文提示，不把原始 ClientException 直接抛给界面。
          final transient = m.contains('timed out') ||
              m.contains('SocketException') ||
              m.contains('Connection refused') ||
              m.contains('Connection reset') ||
              m.contains('Connection closed') ||
              m.contains('Failed host lookup') ||
              m.contains('Connection terminated');
          if (transient && connectionRetries < maxConnectionRetries) {
            connectionRetries++;
            onDiag?.call(
              '[stream] 连接异常（第 $round 轮第 $connectionRetries 次），自动重试: $m',
            );
            unawaited(
              RuntimeLogger.instance.warn(
                'LLM',
                'request.retry',
                sessionId: sessionId,
                requestId: requestId,
                result: 'connection',
                data: {
                  'round': round + 1,
                  'attempt': connectionRetries,
                  'error': m,
                },
              ),
            );
            await Future<void>.delayed(
              Duration(milliseconds: 400 * connectionRetries),
            );
            _throwIfCancelled();
            continue;
          }
          unawaited(
            RuntimeLogger.instance.error(
              'LLM',
              'request.failed',
              sessionId: sessionId,
              requestId: requestId,
              durationMs: DateTime.now()
                  .difference(requestStarted)
                  .inMilliseconds,
              result: 'connection',
              data: {'round': round + 1, 'error': m},
            ),
          );
          throw LlmException(
            '网络连接失败（第 ${round + 1} 轮，已自动重试 $connectionRetries 次）：'
            '${_short(m)}，请检查网络/代理或稍后重试',
          );
        }
      }
    } finally {
      client.close();
      if (identical(_activeHttpClient, client)) _activeHttpClient = null;
    }
  }

  /// 按协议组装 Chat Completions / Anthropic Messages / Responses 请求体。
  Map<String, dynamic> _buildRequestBody({
    required List<Map<String, dynamic>> messages,
    required bool stream,
    required bool includeUsage,
    required int maxTokens,
    bool thinkingEnabled = false,
    String? reasoningEffort,
    bool? useMaxCompletionTokens,
    bool sendStore = false,
    bool sendParallel = false,
    bool sendInclude = false,
  }) {
    // 出口净化：孤立代理项编码成 UTF-8 是非法字节，发出去会被对端直接断连
    // （日志：Connection closed before full header was received，见 #405）。
    final safeMessages = _sanitizeJson(messages);
    if (protocol == 'anthropic') {
      return _buildAnthropicBody(
        messages: safeMessages,
        stream: stream,
        maxTokens: maxTokens,
        thinkingEnabled: thinkingEnabled,
        reasoningEffort: reasoningEffort,
      );
    }
    if (_isResponses) {
      return _buildResponsesBody(
        messages: safeMessages,
        stream: stream,
        maxTokens: maxTokens,
        thinkingEnabled: thinkingEnabled,
        reasoningEffort: reasoningEffort,
        sendStore: sendStore,
        sendParallel: sendParallel,
        sendInclude: sendInclude,
      );
    }
    return _buildChatCompletionsBody(
      messages: safeMessages,
      stream: stream,
      includeUsage: includeUsage,
      maxTokens: maxTokens,
      thinkingEnabled: thinkingEnabled,
      reasoningEffort: reasoningEffort,
      useMaxCompletionTokens: useMaxCompletionTokens,
      sendParallel: sendParallel,
    );
  }

  /// 递归净化 JSON 里的所有字符串（消息、工具参数、图片 URL 等）。
  static List<Map<String, dynamic>> _sanitizeJson(Object? value) {
    final cleaned = _sanitizeValue(value);
    return (cleaned as List).cast<Map<String, dynamic>>();
  }

  static Object? _sanitizeValue(Object? value) {
    if (value is String) return sanitizeUtf16(value);
    if (value is List) return [for (final item in value) _sanitizeValue(item)];
    if (value is Map) {
      return <String, dynamic>{
        for (final entry in value.entries)
          entry.key.toString(): _sanitizeValue(entry.value),
      };
    }
    return value;
  }
  static String _safeEndpoint(String endpoint) {
    final uri = Uri.tryParse(endpoint);
    if (uri == null) return '<endpoint>';
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port${uri.path}';
  }

  static int _imageCount(Map<String, dynamic> body) {
    final root = body['input'] ?? body['messages'];
    if (root is! List) return 0;
    var count = 0;
    for (final item in root) {
      if (item is! Map || item['content'] is! List) continue;
      for (final part in item['content'] as List) {
        if (part is Map &&
            ((part['type'] ?? '').toString() == 'image_url' ||
                (part['type'] ?? '').toString() == 'input_image')) {
          count++;
        }
      }
    }
    return count;
  }

  Map<String, dynamic> _buildChatCompletionsBody({
    required List<Map<String, dynamic>> messages,
    required bool stream,
    required bool includeUsage,
    required int maxTokens,
    required bool thinkingEnabled,
    String? reasoningEffort,
    bool? useMaxCompletionTokens,
    bool sendParallel = false,
  }) {
    final split = _splitSystems(messages);
    final effortField = _openAiReasoningEffort(reasoningEffort);
    final chatMessages = _withReasoningContentFallback(
      split.messages.map(_withoutResponsesOnlyFields).toList(),
      forceReasoning:
          ReasoningModels.usesDeepSeekThinkingParam(model) ||
          split.messages.any(
            (m) =>
                m['role'] == 'assistant' &&
                (m['reasoning_content'] ?? '').toString().trim().isNotEmpty,
          ),
    );
    return <String, dynamic>{
      'model': model,
      'messages': [
        if (split.frozen.trim().isNotEmpty)
          {'role': 'system', 'content': split.frozen},
        ...chatMessages,
        if (split.tail.trim().isNotEmpty)
          {'role': 'system', 'content': split.tail},
      ],
      'stream': stream,
      if (includeUsage) 'stream_options': {'include_usage': true},
      if (effortField == null || effortField.isEmpty)
        'temperature': temperature,
      // 0 = 不限制：不发上限字段，交给模型自身最大输出。
      if (maxTokens > 0)
        if (useMaxCompletionTokens ?? _useMaxCompletionTokens)
          'max_completion_tokens': maxTokens
        else
          'max_tokens': maxTokens,
      if (thinkingEnabled) 'thinking': {'type': 'enabled'},
      if (effortField != null && effortField.isNotEmpty)
        'reasoning_effort': effortField,
      if (tools.isNotEmpty) 'tools': tools,
      if (tools.isNotEmpty) 'tool_choice': 'auto',
      if (tools.isNotEmpty && sendParallel) 'parallel_tool_calls': true,
    };
  }

  Map<String, dynamic> _buildAnthropicBody({
    required List<Map<String, dynamic>> messages,
    required bool stream,
    required int maxTokens,
    required bool thinkingEnabled,
    String? reasoningEffort,
  }) {
    final split = _splitSystems(messages);
    final effort = reasoningEffort;
    final thinkingOn =
        thinkingEnabled &&
        effort != null &&
        effort.isNotEmpty &&
        effort != 'off';
    final systemBlocks = <Map<String, dynamic>>[];
    if (split.frozen.trim().isNotEmpty) {
      systemBlocks.add({
        'type': 'text',
        'text': split.frozen,
        'cache_control': {'type': 'ephemeral'},
      });
    }
    if (split.tail.trim().isNotEmpty) {
      systemBlocks.add({'type': 'text', 'text': split.tail});
    }
    final anthTools = _toAnthropicTools(tools);
    if (anthTools.isNotEmpty) {
      anthTools[anthTools.length - 1] = {
        ...anthTools.last,
        'cache_control': {'type': 'ephemeral'},
      };
    }
    return <String, dynamic>{
      'model': model,
      if (systemBlocks.isNotEmpty) 'system': systemBlocks,
      'messages': _toAnthropicMessages(split.messages),
      if (maxTokens > 0) 'max_tokens': maxTokens,
      'stream': stream,
      if (!thinkingOn) 'temperature': temperature,
      if (thinkingOn)
        'thinking': {
          'type': 'enabled',
          'budget_tokens': ReasoningModels.anthropicBudget(
            effort,
            maxTokens > 0 ? maxTokens : 32000,
          ),
        },
      if (anthTools.isNotEmpty) 'tools': anthTools,
      if (anthTools.isNotEmpty)
        'tool_choice': {'type': 'auto', 'disable_parallel_tool_use': false},
    };
  }

  Map<String, dynamic> _buildResponsesBody({
    required List<Map<String, dynamic>> messages,
    required bool stream,
    required int maxTokens,
    required bool thinkingEnabled,
    String? reasoningEffort,
    required bool sendStore,
    bool sendParallel = false,
    bool sendInclude = false,
  }) {
    final split = _splitSystems(messages);
    final effortField = _openAiReasoningEffort(reasoningEffort);
    final input = _toResponsesInput(split.messages);
    if (split.tail.trim().isNotEmpty) {
      input.add({'type': 'message', 'role': 'system', 'content': split.tail});
    }
    return <String, dynamic>{
      'model': model,
      if (split.frozen.trim().isNotEmpty) 'instructions': split.frozen,
      'input': input,
      'stream': stream,
      if (maxTokens > 0) 'max_output_tokens': maxTokens,
      if (sendStore) 'store': false,
      if (effortField == null || effortField.isEmpty)
        'temperature': temperature,
      if (thinkingEnabled && baseUrl.contains('deepseek.com'))
        'thinking': {'type': 'enabled'},
      if (effortField != null && effortField.isNotEmpty)
        'reasoning': {'effort': effortField},
      if (tools.isNotEmpty) 'tools': _toResponsesTools(tools),
      if (tools.isNotEmpty) 'tool_choice': 'auto',
      if (tools.isNotEmpty && sendParallel) 'parallel_tool_calls': true,
      if (sendInclude) 'include': const ['reasoning.encrypted_content'],
    };
  }

  ({String frozen, String tail, List<Map<String, dynamic>> messages})
  _splitSystems(List<Map<String, dynamic>> messages) {
    var frozen = '';
    final tailParts = <String>[];
    final rest = <Map<String, dynamic>>[];
    var seenFrozen = false;
    for (final m in messages) {
      if (m['role'] == 'system') {
        final c = (m['content'] ?? '').toString().trim();
        if (c.isEmpty) continue;
        if (!seenFrozen) {
          frozen = c;
          seenFrozen = true;
        } else {
          tailParts.add(c);
        }
      } else {
        rest.add(m);
      }
    }
    return (frozen: frozen, tail: tailParts.join('\n\n'), messages: rest);
  }

  List<Map<String, dynamic>> _toResponsesInput(
    List<Map<String, dynamic>> messages,
  ) {
    final input = <Map<String, dynamic>>[];
    var assistantSeq = 0;
    for (final m in messages) {
      final role = (m['role'] ?? '').toString();
      if (role == 'tool') {
        input.add({
          'type': 'function_call_output',
          'call_id': (m['tool_call_id'] ?? '').toString(),
          'output': (m['content'] ?? '').toString(),
        });
        continue;
      }
      final toolCalls = m['tool_calls'];
      if (role == 'assistant' && toolCalls is List && toolCalls.isNotEmpty) {
        _addResponsesReasoning(input, m);
        final text = (m['content'] ?? '').toString();
        if (text.trim().isNotEmpty) {
          assistantSeq++;
          input.add({
            'type': 'message',
            'role': 'assistant',
            'status': 'completed',
            'id': 'msg_asst_$assistantSeq',
            'content': text,
          });
        }
        for (final raw in toolCalls) {
          final tc = raw is Map<String, dynamic> ? raw : <String, dynamic>{};
          final fn = tc['function'] is Map<String, dynamic>
              ? tc['function'] as Map<String, dynamic>
              : <String, dynamic>{};
          input.add({
            'type': 'function_call',
            'call_id': (tc['id'] ?? '').toString(),
            'name': (fn['name'] ?? '').toString(),
            'arguments': (fn['arguments'] ?? '').toString(),
          });
        }
        continue;
      }
      if (role == 'assistant') {
        _addResponsesReasoning(input, m);
        assistantSeq++;
      }
      final resolvedRole = role.isEmpty ? 'user' : role;
      final item = <String, dynamic>{
        'type': 'message',
        'role': resolvedRole,
        'content': _toResponsesContent(m['content'], role: resolvedRole),
      };
      if (role == 'assistant') {
        item['status'] = 'completed';
        item['id'] = 'msg_asst_$assistantSeq';
      }
      input.add(item);
    }
    return input;
  }

  static void _addResponsesReasoning(
    List<Map<String, dynamic>> input,
    Map<String, dynamic> message,
  ) {
    final enc = (message['reasoning_encrypted'] ?? '').toString().trim();
    if (enc.isEmpty) return;
    input.add({'type': 'reasoning', 'encrypted_content': enc});
  }

  static Map<String, dynamic> _withoutResponsesOnlyFields(
    Map<String, dynamic> message,
  ) {
    if (!message.containsKey('reasoning_encrypted')) return message;
    final copy = Map<String, dynamic>.from(message);
    copy.remove('reasoning_encrypted');
    return copy;
  }

  /// thinking 模式网关要求历史里的所有 assistant 消息都带
  /// `reasoning_content`；只要混入了“压缩确认 / 失败占位 / 最终正文”这类
  /// 没有思考内容的助手消息，上游就会报
  /// `The reasoning_content in the thinking mode must be passed back to the API`。
  /// 这里给缺字段的 assistant 补空字符串，避免整轮 400。
  static List<Map<String, dynamic>> _withReasoningContentFallback(
    List<Map<String, dynamic>> messages, {
    required bool forceReasoning,
  }) {
    if (!forceReasoning) return messages;
    return [
      for (final m in messages)
        if (m['role'] == 'assistant' && !m.containsKey('reasoning_content'))
          {...m, 'reasoning_content': ''}
        else
          m,
    ];
  }

  /// Chat Completions 多模态是 `{type:image_url, image_url:{url}}`；
  /// Responses 原生要 `{type:input_image, image_url:"..."}`。
  /// 原样透传会让中转/上游崩成 Cloudflare 502。
  Object _toResponsesContent(Object? raw, {String role = 'user'}) {
    if (raw is! List) return (raw ?? '').toString();
    final parts = <Map<String, dynamic>>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final m = Map<String, dynamic>.from(item);
      final type = (m['type'] ?? '').toString();
      if (type == 'input_text' ||
          type == 'output_text' ||
          type == 'input_image' ||
          type == 'input_file') {
        if (type == 'input_image') {
          final url = _responsesImageUrl(m);
          if (url == null) continue;
          parts.add({'type': 'input_image', 'image_url': url});
          continue;
        }
        parts.add(m);
        continue;
      }
      if (type == 'text' || (type.isEmpty && m['text'] != null)) {
        parts.add({
          'type': role == 'assistant' ? 'output_text' : 'input_text',
          'text': (m['text'] ?? '').toString(),
        });
        continue;
      }
      if (type == 'image_url') {
        final url = _responsesImageUrl(m);
        if (url == null) continue;
        parts.add({'type': 'input_image', 'image_url': url});
      }
    }
    if (parts.isEmpty) return '';
    return parts;
  }

  static String? _responsesImageUrl(Map<dynamic, dynamic> part) {
    final direct = part['image_url'];
    if (direct is String) {
      final url = direct.trim();
      if (url.isEmpty || url.startsWith('file:')) return null;
      return url;
    }
    if (direct is Map) {
      final url = (direct['url'] ?? '').toString().trim();
      if (url.isEmpty || url.startsWith('file:')) return null;
      return url;
    }
    return null;
  }

  static String _previewRequestBody(String encoded) {
    final redacted = encoded.replaceAll(
      RegExp(r'data:image\/[a-zA-Z0-9.+-]+;base64,[A-Za-z0-9+/=]+'),
      'data:image/*;base64,<omitted>',
    );
    return redacted.length <= 2000
        ? redacted
        : cutRunes(redacted, 2000);
  }

  static String _contentMeta(Map<String, dynamic> body) {
    final root = body['input'] ?? body['messages'];
    if (root is! List) return 'images=0 parts=0';
    var images = 0;
    var parts = 0;
    final types = <String>[];
    for (final item in root) {
      if (item is! Map) continue;
      final content = item['content'];
      if (content is List) {
        for (final part in content) {
          parts++;
          if (part is! Map) {
            types.add('unknown');
            continue;
          }
          final type = (part['type'] ?? '').toString();
          types.add(type.isEmpty ? 'unknown' : type);
          if (type == 'image_url' || type == 'input_image') images++;
        }
      } else {
        parts++;
        types.add('string');
      }
    }
    final shown = types.length <= 12
        ? types.join(',')
        : '${types.take(12).join(',')}…';
    final toolNames = _toolNames(body['tools']);
    return 'images=$images parts=$parts types=$shown '
        'tools=${toolNames.length} fingerprint=${toolNames.join(',')} '
        'parallel=${body['parallel_tool_calls'] == true} '
        'include=${body['include'] is List ? (body['include'] as List).join(',') : ''}';
  }

  static List<String> _toolNames(Object? tools) {
    if (tools is! List) return const [];
    final names = <String>[];
    for (final raw in tools) {
      if (raw is! Map) continue;
      final direct = (raw['name'] ?? '').toString();
      if (direct.isNotEmpty) {
        names.add(direct);
        continue;
      }
      final fn = raw['function'];
      if (fn is Map) {
        final name = (fn['name'] ?? '').toString();
        if (name.isNotEmpty) names.add(name);
      }
    }
    return names;
  }

  List<Map<String, dynamic>> _toResponsesTools(
    List<Map<String, dynamic>> tools,
  ) {
    return tools.map((t) {
      final fn = t['function'] is Map<String, dynamic>
          ? t['function'] as Map<String, dynamic>
          : t;
      return <String, dynamic>{
        'type': 'function',
        'name': (fn['name'] ?? '').toString(),
        'description': (fn['description'] ?? '').toString(),
        'parameters': fn['parameters'] is Map<String, dynamic>
            ? fn['parameters']
            : const <String, dynamic>{'type': 'object', 'properties': {}},
      };
    }).toList();
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

  /// MiMo 等网关拒绝未知字段时只回 `Invalid request parameters`，
  /// 不点名 `reasoning_effort`。有思考档位时按该字段被拒处理。
  static bool _isVagueInvalidRequest(String err) {
    final e = err.toLowerCase();
    return e.contains('invalid request parameters') ||
        e.contains('invalid_request_error') ||
        (e.contains('badrequesterror') && e.contains('invalid request'));
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

  /// 测试专用：直接喂一条 SSE 字节流给 Chat Completions 解析器，
  /// 用于精确控制「已经收到内容、之后长时间无数据」的时序。
  @visibleForTesting
  Future<bool> parseOpenAiStreamForTest(Stream<List<int>> raw) =>
      _parseOpenAiSse(raw);

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
    return cutRunes(t, 300);
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
      sendStore: _isResponses,
      sendParallel: tools.isNotEmpty,
      sendInclude: _isResponses,
    );
    final request = http.Request('POST', Uri.parse(_endpoint))
      ..headers.addAll(_headers(streaming: false))
      ..body = jsonEncode(body);

    final client = await Socks5Proxy.client();
    try {
      final response = streamWaitTimeout > Duration.zero
          ? await client.send(request).timeout(streamWaitTimeout)
          : await client.send(request);
      final raw = await response.stream.bytesToString().timeout(
        streamWaitTimeout,
      );
      if (response.statusCode != 200) {
        throw LlmHttpException(
          LlmErrorInfo.fromHttp(response.statusCode, raw),
          raw,
        );
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
      if (_isResponses) {
        return _textFromResponsesObject(json);
      }
      final choices = json['choices'] as List<dynamic>? ?? [];
      if (choices.isEmpty) return '';
      final msg = choices.first['message'] as Map<String, dynamic>?;
      return (msg?['content'] as String?)?.trim() ?? '';
    } on TimeoutException {
      throw LlmException(
        '等待模型响应已超过 ${streamWaitTimeout.inSeconds} 秒，请重试'
        '（可在「设置 → 上下文 → 长推理等待上限」调大）。',
      );
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
        throw LlmHttpException(
          LlmErrorInfo.fromHttp(res.statusCode, res.body),
          res.body,
        );
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

  String _textFromResponsesObject(Map<String, dynamic> json) {
    final direct = json['output_text'];
    if (direct is String && direct.trim().isNotEmpty) return direct.trim();
    final output = json['output'] as List<dynamic>? ?? [];
    final parts = <String>[];
    for (final raw in output) {
      if (raw is! Map) continue;
      final item = Map<String, dynamic>.from(raw);
      if (item['type'] != 'message') continue;
      final content = item['content'];
      if (content is String && content.trim().isNotEmpty) {
        parts.add(content.trim());
        continue;
      }
      if (content is List) {
        for (final block in content) {
          if (block is! Map) continue;
          final type = (block['type'] ?? '').toString();
          if (type == 'output_text' || type == 'text') {
            final text = (block['text'] ?? '').toString().trim();
            if (text.isNotEmpty) parts.add(text);
          }
        }
      }
    }
    return parts.join('\n');
  }

  /// OpenAI / DeepSeek / 百炼 / OpenRouter Responses SSE。
  /// DeepSeek 在 response.completed 结束，没有 data: [DONE]。
  Future<bool> _parseResponsesSse(Stream<List<int>> raw) async {
    final lineBuffer = StringBuffer();
    String text = '';
    String reasoning = '';
    String reasoningEncrypted = '';
    final toolBuf = <int, Map<String, String>>{};
    var doneReceived = false;
    var stoppedByUser = false;
    var rawFramesLeft = 25;
    var streamBroken = false;
    var oversizeWarned = false;
    String? finishReason;
    final completer = Completer<bool>();

    bool toolsComplete() =>
        toolBuf.isNotEmpty &&
        toolBuf.values.every((t) {
          final a = t['arguments'] ?? '';
          return a.trim().isNotEmpty && _tryDecode(a) != null;
        });

    void emitPartial() {
      if (text.isEmpty && reasoning.isEmpty) return;
      _resolveRoundOverlap(text);
      onTurn?.call(
        TurnResult(
          text: _displayText + _visibleRoundText(text),
          reasoning: _displayReasoning + reasoning,
          reasoningEncrypted: reasoningEncrypted,
          toolCalls: _snapshotTools(toolBuf),
        ),
      );
    }

    bool decideContinue() {
      if (completer.isCompleted) return false;
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
      if (toolsComplete()) return false;
      if (toolBuf.isNotEmpty) {
        completer.completeError(LlmInterruptedException('工具调用被截断，交上层整轮重试'));
        return false;
      }
      if (finishReason == 'length' && t.isEmpty) {
        completer.completeError(
          LlmInterruptedException('回复中断：模型输出被截断且没有正文，交上层整轮重试'),
        );
        return false;
      }
      return true;
    }

    void handleFunctionItem(Map<String, dynamic> item, int outputIndex) {
      if ((item['type'] ?? '').toString() != 'function_call') return;
      final cur = toolBuf.putIfAbsent(
        outputIndex,
        () => {'id': '', 'name': '', 'arguments': ''},
      );
      final callId = (item['call_id'] ?? item['id'] ?? '').toString();
      if (callId.isNotEmpty) cur['id'] = callId;
      final name = (item['name'] ?? '').toString();
      if (name.isNotEmpty) cur['name'] = name;
      final args = item['arguments'];
      if (args is String && args.isNotEmpty) {
        cur['arguments'] = args;
      }
    }

    void handleReasoningItem(Map<String, dynamic> item) {
      if ((item['type'] ?? '').toString() != 'reasoning') return;
      final enc = (item['encrypted_content'] ?? '').toString();
      if (enc.trim().isNotEmpty) reasoningEncrypted = enc;
      if (reasoning.isNotEmpty) return;
      final summary = item['summary'];
      if (summary is List) {
        final parts = <String>[];
        for (final block in summary) {
          if (block is! Map) continue;
          final piece = (block['text'] ?? '').toString().trim();
          if (piece.isNotEmpty) parts.add(piece);
        }
        if (parts.isNotEmpty) reasoning = parts.join('\n');
      }
    }

    void handleJson(Map<String, dynamic> json) {
      final usage = json['usage'] as Map<String, dynamic>?;
      if (usage != null) applyUsage(usage);
      final type = (json['type'] ?? '').toString();
      if (type.startsWith('response.reasoning') ||
          type.startsWith('response.thinking') ||
          type == 'response.reasoning_summary_text.delta' ||
          type == 'response.reasoning_text.delta') {
        final rc =
            extractReasoningValue(json['delta']) ??
            extractReasoningValue(json['text']);
        if (rc != null) {
          reasoning += rc;
          emitPartial();
        }
        return;
      }
      if (type == 'response.output_text.delta' ||
          type == 'response.content_part.delta') {
        final delta =
            extractReasoningValue(json['delta']) ??
            extractReasoningValue(json['text']);
        if (delta != null && delta.isNotEmpty) {
          text += delta;
          emitPartial();
        }
        return;
      }
      if (type == 'response.output_item.added' ||
          type == 'response.output_item.done') {
        final item = json['item'];
        final outputIndex =
            (json['output_index'] as num?)?.toInt() ??
            (toolBuf.isEmpty
                ? 0
                : (toolBuf.keys.reduce((a, b) => a > b ? a : b) + 1));
        if (item is Map<String, dynamic>) {
          handleFunctionItem(item, outputIndex);
          handleReasoningItem(item);
          if ((item['type'] ?? '').toString() == 'message' &&
              type == 'response.output_item.done' &&
              text.isEmpty) {
            final content = item['content'];
            if (content is List) {
              for (final block in content) {
                if (block is Map &&
                    ((block['type'] ?? '') == 'output_text' ||
                        (block['type'] ?? '') == 'text')) {
                  final piece = (block['text'] ?? '').toString();
                  if (piece.isNotEmpty) text += piece;
                }
              }
              if (text.isNotEmpty) emitPartial();
            }
          }
        }
        return;
      }
      if (type == 'response.function_call_arguments.delta') {
        final outputIndex = (json['output_index'] as num?)?.toInt() ?? 0;
        final cur = toolBuf.putIfAbsent(
          outputIndex,
          () => {'id': '', 'name': '', 'arguments': ''},
        );
        final delta = json['delta'];
        if (delta is String && delta.isNotEmpty) {
          cur['arguments'] = '${cur['arguments']}$delta';
        }
        return;
      }
      if (type == 'response.completed' ||
          type == 'response.incomplete' ||
          type == 'response.failed') {
        doneReceived = true;
        final response = json['response'];
        if (response is Map<String, dynamic>) {
          final ru = response['usage'];
          if (ru is Map<String, dynamic>) applyUsage(ru);
          if (text.isEmpty) {
            final extracted = _textFromResponsesObject(response);
            if (extracted.isNotEmpty) text = extracted;
          }
          final output = response['output'];
          if (output is List) {
            for (final rawItem in output) {
              if (rawItem is Map<String, dynamic>) {
                handleReasoningItem(rawItem);
              } else if (rawItem is Map) {
                handleReasoningItem(Map<String, dynamic>.from(rawItem));
              }
            }
          }
          if (type == 'response.incomplete') {
            final details = response['incomplete_details'];
            final reason = details is Map
                ? (details['reason'] ?? '').toString()
                : '';
            if (reason.contains('max') || reason.contains('token')) {
              finishReason = 'length';
            }
          }
          if (type == 'response.failed') {
            final err = response['error'];
            final msg = err is Map
                ? (err['message'] ?? 'Responses 请求失败').toString()
                : 'Responses 请求失败';
            if (!completer.isCompleted) {
              completer.completeError(LlmException(msg));
            }
          }
        } else if (type == 'response.incomplete') {
          finishReason = 'length';
        }
        return;
      }
      if (type == 'error') {
        final msg = (json['message'] ?? json['error'] ?? 'Responses 流错误')
            .toString();
        if (!completer.isCompleted) {
          completer.completeError(LlmException(msg));
        }
      }
    }

    void handleLine(String line) {
      if (line.isEmpty) return;
      if (!line.startsWith('data:')) return;
      final data = line.substring(5).trim();
      if (rawFramesLeft > 0) {
        rawFramesLeft--;
        final preview = data.length <= 500
            ? data
            : cutRunes(data, 500);
        onDiag?.call('[sse] $preview');
      }
      if (data == '[DONE]') {
        doneReceived = true;
        return;
      }
      final json = _tryDecode(data);
      if (json == null) return;
      handleJson(json);
    }

    StreamSubscription<String>? sub;
    Timer? idleTimer;

    /// 收口本轮：落定断点文本、决定是否续写。
    void finishRound({required bool broken}) {
      idleTimer?.cancel();
      if (completer.isCompleted) return;
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
          : tailRunes(text, 40);
      onDiag?.call(
        '[stream] end responses model=$model max=$maxTokens '
        'fr=$finishReason done=$doneReceived broken=$broken '
        'textLen=${text.length} tools=${toolBuf.length} '
        'reasoningLen=${reasoning.length} tail=${tail.trim()}',
      );
      if (text.isNotEmpty || toolBuf.isNotEmpty || reasoning.isNotEmpty) {
        _resolveRoundOverlap(text);
        onTurn?.call(
          TurnResult(
            text: _displayText + _visibleRoundText(text).trim(),
            reasoning: _displayReasoning + reasoning,
            reasoningEncrypted: reasoningEncrypted,
            toolCalls: _snapshotTools(toolBuf),
          ),
        );
      }
      if (finishReason != null) lastFinishReason = finishReason;
      _roundTextRaw = text;
      _lastRoundText = text.trim();
      _lastRoundReasoning = reasoning;
      _lastRoundReasoningEncrypted = reasoningEncrypted;
      var needContinue = decideContinue();
      if (completer.isCompleted) return;
      if (!needContinue &&
          !broken &&
          !stoppedByUser &&
          toolBuf.isEmpty &&
          text.trim().isNotEmpty &&
          !doneReceived &&
          finishReason == null &&
          !_silentEndResumed) {
        // 既没有 finish_reason 也没有 [DONE] 就结束：静默截断。
        _silentEndResumed = true;
        needContinue = true;
        lastRoundInterrupted = true;
        onDiag?.call('[stream] 静默结束（无 finish_reason / 无 [DONE]）：续写确认一次');
      }
      if (!needContinue && broken && !stoppedByUser) {
        final hasContent =
            text.trim().isNotEmpty || reasoning.trim().isNotEmpty;
        if (toolBuf.isNotEmpty && !toolsComplete()) {
          completer.completeError(LlmInterruptedException('工具调用被截断，交上层整轮重试'));
          return;
        }
        if (hasContent && toolBuf.isEmpty) {
          // 连接断了但已经生成内容：按断点续写，绝不把半截内容丢掉重来。
          needContinue = true;
          lastRoundInterrupted = true;
          onDiag?.call('[stream] 断流：从已生成内容断点续写');
        }
      }
      onDiag?.call(
        '[stream] needContinue=$needContinue model=$model '
        'max=$maxTokens fr=$finishReason '
        'done=$doneReceived tools=${toolBuf.length}',
      );
      if (needContinue) {
        completer.complete(true);
        return;
      }
      if (broken && !stoppedByUser && text.isEmpty && toolBuf.isEmpty) {
        completer.completeError(LlmInterruptedException('回复不完整：连接提前断开，请重试'));
        return;
      }
      completer.complete(false);
    }

    void resetIdleTimer() {
      idleTimer?.cancel();
      // 等待上限 0 = 不限制：不挂空闲计时器，绝不因为「等太久没数据」砍断。
      if (streamWaitTimeout <= Duration.zero) return;
      idleTimer = Timer(streamWaitTimeout, () {
        idleTimer = null;
        streamBroken = true;
        sub?.cancel();
        onDiag?.call('[stream] idle 超时断开（${streamWaitTimeout.inSeconds}s 无数据）');
        finishRound(broken: true);
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
            // 快路径：本块没有换行且缓冲未超限，先不切片（避免大帧 O(n²)）。
            if (!chunk.contains('\n') &&
                lineBuffer.length <= _maxLineBufferChars) {
              return;
            }
            if (!oversizeWarned && lineBuffer.length > _maxLineBufferChars) {
              oversizeWarned = true;
              onDiag?.call('[stream] 单帧超过 $_maxLineBufferChars 字符：继续缓冲，不丢内容');
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
            onDiag?.call('[stream] onError: $e');
            streamBroken = true;
            finishRound(broken: true);
          },
          onDone: () => finishRound(broken: streamBroken),
          cancelOnError: true,
        );
    // 首个字节之前也要计时：网关收下请求却长时间不出字时，不能永远挂着。
    resetIdleTimer();
    return completer.future;
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
    var streamBroken = false;
    var oversizeWarned = false;
    String? finishReason; // 最后一条 chunk 的 finish_reason：'length' = 输出被截断
    final completer = Completer<bool>();

    /// 工具参数是否已经收齐（能 JSON 解析）。收齐即可照常执行，
    /// 即使 finish_reason=length（截断的只是后续文本）。
    bool toolsComplete() =>
        toolBuf.isNotEmpty &&
        toolBuf.values.every((t) {
          final a = t['arguments'] ?? '';
          return a.trim().isNotEmpty && _tryDecode(a) != null;
        });

    void emitPartial() {
      if (text.isEmpty && reasoning.isEmpty) return;
      _resolveRoundOverlap(text);
      onTurn?.call(
        TurnResult(
          text: _displayText + _visibleRoundText(text),
          reasoning: _displayReasoning + reasoning,
          toolCalls: _snapshotTools(toolBuf),
        ),
      );
    }

    /// 判断本轮是否因输出截断需要续写。
    /// 返回 true = 纯文本被截断，调用方应追加「继续」请求续写；
    /// false = 正常完成。工具调用完整时即使 fr=length 也视为完成
    /// （截断的只是后续文本，工具照常执行）。
    bool decideContinue() {
      if (completer.isCompleted) return false;
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
      if (toolsComplete()) return false; // 工具完整：截断不影响执行
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
              : cutRunes(data, 500);
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

    /// 收口本轮：落定断点文本、决定是否续写。
    /// [broken] = 连接断开/空闲超时（不是服务商正常结束）。
    void finishRound({required bool broken}) {
      idleTimer?.cancel();
      if (completer.isCompleted) return;
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
          : tailRunes(text, 40);
      onDiag?.call(
        '[stream] end model=$model max=$maxTokens '
        'fr=$finishReason done=$doneReceived broken=$broken '
        'textLen=${text.length} tools=${toolBuf.length} '
        'reasoningLen=${reasoning.length} tail=${tail.trim()}',
      );
      if (text.isNotEmpty || toolBuf.isNotEmpty || reasoning.isNotEmpty) {
        _resolveRoundOverlap(text);
        onTurn?.call(
          TurnResult(
            text: _displayText + _visibleRoundText(text).trim(),
            reasoning: _displayReasoning + reasoning,
            toolCalls: _snapshotTools(toolBuf),
          ),
        );
      }
      if (finishReason != null) lastFinishReason = finishReason;
      _roundTextRaw = text;
      _lastRoundText = text.trim();
      _lastRoundReasoning = reasoning;
      // 截断决策：纯文本截断 → 续写；工具完整 → 正常完成。
      var needContinue = decideContinue();
      if (completer.isCompleted) return;
      if (!needContinue &&
          !broken &&
          !stoppedByUser &&
          toolBuf.isEmpty &&
          text.trim().isNotEmpty &&
          !doneReceived &&
          finishReason == null &&
          !_silentEndResumed) {
        // 既没有 finish_reason 也没有 [DONE] 就结束：网关/代理静默截断的
        // 典型特征。已生成内容原样保留，只补一轮续写确认（每轮最多一次）。
        _silentEndResumed = true;
        needContinue = true;
        lastRoundInterrupted = true;
        onDiag?.call('[stream] 静默结束（无 finish_reason / 无 [DONE]）：续写确认一次');
      }
      if (!needContinue && broken && !stoppedByUser) {
        final hasContent =
            text.trim().isNotEmpty || reasoning.trim().isNotEmpty;
        if (toolBuf.isNotEmpty && !toolsComplete()) {
          completer.completeError(LlmInterruptedException('工具调用被截断，交上层整轮重试'));
          return;
        }
        if (hasContent && toolBuf.isEmpty) {
          // 连接断了但已经生成内容：按断点续写，绝不把半截内容丢掉重来。
          needContinue = true;
          lastRoundInterrupted = true;
          onDiag?.call('[stream] 断流：从已生成内容断点续写');
        }
      }
      onDiag?.call(
        '[stream] needContinue=$needContinue model=$model '
        'max=$maxTokens fr=$finishReason '
        'done=$doneReceived tools=${toolBuf.length}',
      );
      if (needContinue) {
        completer.complete(true);
        return;
      }
      // 已经收到内容但没有 [DONE]：不少网关/代理正常结束时不发 [DONE]，
      // 此时视为回复完成，避免误报"回复不完整"导致丢内容重试。
      if (broken && !stoppedByUser && text.isEmpty && toolBuf.isEmpty) {
        completer.completeError(LlmInterruptedException('回复不完整：连接提前断开，请重试'));
        return;
      }
      completer.complete(false);
    }

    void resetIdleTimer() {
      idleTimer?.cancel();
      // 等待上限 0 = 不限制：不挂空闲计时器，绝不因为「等太久没数据」砍断。
      if (streamWaitTimeout <= Duration.zero) return;
      idleTimer = Timer(streamWaitTimeout, () {
        idleTimer = null;
        streamBroken = true;
        sub?.cancel();
        onDiag?.call('[stream] idle 超时断开（${streamWaitTimeout.inSeconds}s 无数据）');
        finishRound(broken: true);
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
            // 快路径：本块没有换行且缓冲未超限，先不切片（避免大帧 O(n²)）。
            if (!chunk.contains('\n') &&
                lineBuffer.length <= _maxLineBufferChars) {
              return;
            }
            if (!oversizeWarned && lineBuffer.length > _maxLineBufferChars) {
              oversizeWarned = true;
              onDiag?.call('[stream] 单帧超过 $_maxLineBufferChars 字符：继续缓冲，不丢内容');
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
            onDiag?.call('[stream] onError: $e');
            streamBroken = true;
            finishRound(broken: true);
          },
          onDone: () => finishRound(broken: streamBroken),
          cancelOnError: true,
        );
    // 首个字节之前也要计时：网关收下请求却长时间不出字时，不能永远挂着。
    resetIdleTimer();
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
    var streamBroken = false;
    var oversizeWarned = false;
    String? stopReason;
    final completer = Completer<bool>();

    bool toolsComplete() =>
        toolBuf.isNotEmpty &&
        toolBuf.values.every((t) {
          final a = t['arguments'] ?? '';
          return a.trim().isNotEmpty && _tryDecode(a) != null;
        });

    void emitPartial() {
      if (text.isEmpty && reasoning.isEmpty) return;
      _resolveRoundOverlap(text);
      onTurn?.call(
        TurnResult(
          text: _displayText + _visibleRoundText(text),
          reasoning: _displayReasoning + reasoning,
          toolCalls: _snapshotTools(toolBuf),
        ),
      );
    }

    bool decideContinue() {
      if (completer.isCompleted) return false;
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
      if (toolsComplete()) return false;
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

    /// 收口本轮：落定断点文本、决定是否续写。
    void finishRound({required bool broken}) {
      idleTimer?.cancel();
      if (completer.isCompleted) return;
      if (buffer.isNotEmpty) {
        final rest = buffer.toString();
        if (rest.trim().isNotEmpty) {
          for (final line in rest.split('\n')) {
            handleLine(line);
          }
        }
        buffer.clear();
      }
      onDiag?.call(
        '[stream] end anthropic model=$model max=$maxTokens '
        'sr=$stopReason done=$doneReceived broken=$broken '
        'textLen=${text.length} tools=${toolBuf.length} '
        'reasoningLen=${reasoning.length}',
      );
      if (text.isNotEmpty || toolBuf.isNotEmpty || reasoning.isNotEmpty) {
        _resolveRoundOverlap(text);
        onTurn?.call(
          TurnResult(
            text: _displayText + _visibleRoundText(text).trim(),
            reasoning: _displayReasoning + reasoning,
            toolCalls: _snapshotTools(toolBuf),
          ),
        );
      }
      if (stopReason != null) lastFinishReason = stopReason;
      _roundTextRaw = text;
      _lastRoundText = text.trim();
      _lastRoundReasoning = reasoning;
      var needContinue = decideContinue();
      if (completer.isCompleted) return;
      if (!needContinue &&
          !broken &&
          !stoppedByUser &&
          toolBuf.isEmpty &&
          text.trim().isNotEmpty &&
          !doneReceived &&
          stopReason == null &&
          !_silentEndResumed) {
        // 既没有 stop_reason 也没有 message_stop 就结束：静默截断。
        _silentEndResumed = true;
        needContinue = true;
        lastRoundInterrupted = true;
        onDiag?.call('[stream] 静默结束（无 stop_reason / 无 message_stop）：续写确认一次');
      }
      if (!needContinue && broken && !stoppedByUser) {
        final hasContent =
            text.trim().isNotEmpty || reasoning.trim().isNotEmpty;
        if (toolBuf.isNotEmpty && !toolsComplete()) {
          completer.completeError(LlmInterruptedException('工具调用被截断，交上层整轮重试'));
          return;
        }
        if (hasContent && toolBuf.isEmpty) {
          // 连接断了但已经生成内容：按断点续写，绝不把半截内容丢掉重来。
          needContinue = true;
          lastRoundInterrupted = true;
          onDiag?.call('[stream] 断流：从已生成内容断点续写');
        }
      }
      if (needContinue) {
        completer.complete(true);
        return;
      }
      if (broken && !stoppedByUser && text.isEmpty && toolBuf.isEmpty) {
        completer.completeError(LlmInterruptedException('回复不完整：连接提前断开，请重试'));
        return;
      }
      completer.complete(false);
    }

    void resetIdleTimer() {
      idleTimer?.cancel();
      // 等待上限 0 = 不限制：不挂空闲计时器，绝不因为「等太久没数据」砍断。
      if (streamWaitTimeout <= Duration.zero) return;
      idleTimer = Timer(streamWaitTimeout, () {
        idleTimer = null;
        streamBroken = true;
        sub?.cancel();
        onDiag?.call('[stream] idle 超时断开（${streamWaitTimeout.inSeconds}s 无数据）');
        finishRound(broken: true);
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
            // 快路径：本块没有换行且缓冲未超限，先不切片（避免大帧 O(n²)）。
            if (!chunk.contains('\n') && buffer.length <= _maxLineBufferChars) {
              return;
            }
            if (!oversizeWarned && buffer.length > _maxLineBufferChars) {
              oversizeWarned = true;
              onDiag?.call('[stream] 单帧超过 $_maxLineBufferChars 字符：继续缓冲，不丢内容');
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
            onDiag?.call('[stream] onError: $e');
            streamBroken = true;
            finishRound(broken: true);
          },
          onDone: () => finishRound(broken: streamBroken),
          cancelOnError: true,
        );
    // 首个字节之前也要计时：网关收下请求却长时间不出字时，不能永远挂着。
    resetIdleTimer();
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
