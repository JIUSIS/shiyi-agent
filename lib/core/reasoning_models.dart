/// 按模型 ID 关键字识别思考能力：会话页思考开关 / 档位，以及请求体参数都走这里。
/// 拾忆 [LlmClient] 与 DSH 注入共用。
///
/// 只认家族关键字，不绑死版本号：`gpt-5.6` 认 `gpt`，`deepseek-v4-flash` 认
/// `deepseek`。网关前缀（`openai/gpt-5`、`anthropic/claude-opus-4`）同样生效。
class ReasoningProfile {
  /// 未手动选档时的默认强度。
  final String defaultEffort;

  /// 会话页档位；含 `off` 才显示思考开关。值为网关字段，`off: null` 表示关闭时不传档位。
  final Map<String, String?> efforts;

  /// OpenAI 兼容口需要 `thinking: {type: enabled}`（DeepSeek 官方等）。
  final bool usesDeepSeekThinkingParam;

  /// Anthropic Messages 需要 `thinking: {type: enabled, budget_tokens}`。
  final bool usesAnthropicThinking;

  /// GPT 关闭思考时发 `reasoning_effort: none`，不能发 `off`。
  final bool usesNoneForOff;

  const ReasoningProfile({
    required this.defaultEffort,
    required this.efforts,
    this.usesDeepSeekThinkingParam = false,
    this.usesAnthropicThinking = false,
    this.usesNoneForOff = false,
  });
}

class ReasoningModels {
  ReasoningModels._();

  static const offLowHighMax = <String, String?>{
    'off': null,
    'low': 'low',
    'medium': 'medium',
    'high': 'high',
    'max': 'max',
  };

  static const offLowHigh = <String, String?>{
    'off': null,
    'low': 'low',
    'medium': 'medium',
    'high': 'high',
  };

  static const offLowHighXhigh = <String, String?>{
    'off': null,
    'low': 'low',
    'medium': 'medium',
    'high': 'high',
    'xhigh': 'xhigh',
  };

  static const oSeriesEfforts = <String, String?>{
    'low': 'low',
    'medium': 'medium',
    'high': 'high',
  };

  /// 按模型 ID 关键字识别思考能力。对不上家族时仍返回通用档位，会话页一律显示
  /// 思考按钮；默认档位为空，不会自动往请求里塞 thinking 参数。
  static ReasoningProfile? profile(String model) {
    final id = model.trim().toLowerCase();
    if (id.isEmpty) return null;

    if (_has(id, const ['o1', 'o3', 'o4'])) {
      return const ReasoningProfile(
        defaultEffort: 'high',
        efforts: oSeriesEfforts,
      );
    }
    if (_has(id, const ['gpt', 'codex'])) {
      return const ReasoningProfile(
        defaultEffort: 'high',
        efforts: offLowHighXhigh,
        usesNoneForOff: true,
      );
    }
    if (_has(id, const ['claude'])) {
      return const ReasoningProfile(
        defaultEffort: 'high',
        efforts: offLowHighMax,
        usesAnthropicThinking: true,
      );
    }
    if (_has(id, const ['deepseek', 'reasoner', 'r1'])) {
      return const ReasoningProfile(
        defaultEffort: 'high',
        efforts: offLowHighMax,
        usesDeepSeekThinkingParam: true,
      );
    }
    if (_has(id, const ['grok', 'gemini'])) {
      return const ReasoningProfile(defaultEffort: 'high', efforts: offLowHigh);
    }
    if (_has(id, const [
      'qwen',
      'qwq',
      'glm',
      'kimi',
      'moonshot',
      'mimo',
      'doubao',
      'minimax',
      'ernie',
      'hunyuan',
      'step',
      'spark',
      'magistral',
      'thinking',
    ])) {
      return const ReasoningProfile(
        defaultEffort: 'high',
        efforts: offLowHighMax,
      );
    }
    return const ReasoningProfile(defaultEffort: '', efforts: offLowHighMax);
  }

  static String? defaultEffort(String model) {
    final effort = profile(model)?.defaultEffort;
    if (effort == null || effort.isEmpty) return null;
    return effort;
  }

  static Map<String, String?>? effortsFor(String model) =>
      profile(model)?.efforts;

  static bool usesDeepSeekThinkingParam(String model) =>
      profile(model)?.usesDeepSeekThinkingParam ?? false;

  /// Anthropic extended thinking 的 budget_tokens；必须小于 max_tokens。
  static int anthropicBudget(String effort, int maxTokens) {
    final wanted = switch (effort) {
      'low' => 2048,
      'medium' => 8192,
      'max' => 32768,
      _ => 16384,
    };
    final cap = maxTokens > 1024
        ? maxTokens - 1024
        : (maxTokens > 1 ? maxTokens - 1 : 1);
    if (cap < 1024) return cap < 1 ? 1 : cap;
    return wanted < cap ? wanted : cap;
  }

  /// 按分隔符切段后认关键字：`openai/gpt-5.6`、`deepseek-v4-flash` 都能命中。
  /// `o1` 这类短名不会误伤 `go1` / `pro1`。
  static bool _has(String id, List<String> keys) {
    final parts = id.split(RegExp(r'[-_/.]'));
    return keys.any(
      (key) => id.contains(key) && (key.length >= 3 || parts.contains(key)),
    );
  }
}
