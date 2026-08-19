import 'models.dart';

// 内置模型预设：一键填入 接口地址 + 模型名，方便切换服务商。
class ModelPreset {
  final String name;
  final String baseUrl;
  final String model;
  final String apiProtocol; // openai | anthropic
  final String keyHint; // API Key 格式提示
  final int suggestedMaxTokens; // 该模型推荐的单次输出上限
  const ModelPreset({
    required this.name,
    required this.baseUrl,
    required this.model,
    this.apiProtocol = 'openai',
    required this.keyHint,
    this.suggestedMaxTokens = 8192,
  });
}

const List<ModelPreset> modelPresets = [
  ModelPreset(
    name: 'OpenAI',
    baseUrl: 'https://api.openai.com/v1',
    model: 'gpt-4o',
    keyHint: 'sk-...（OpenAI 控制台创建）',
    suggestedMaxTokens: 16384,
  ),
  ModelPreset(
    name: 'Anthropic Claude',
    baseUrl: 'https://api.anthropic.com',
    model: 'claude-sonnet-4-5',
    apiProtocol: 'anthropic',
    keyHint: 'sk-ant-...（Anthropic Console 创建）',
    suggestedMaxTokens: 16384,
  ),
  ModelPreset(
    name: 'Google Gemini',
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
    model: 'gemini-2.5-flash',
    keyHint: 'AIza...（Google AI Studio API Key）',
    suggestedMaxTokens: 8192,
  ),
  ModelPreset(
    name: 'DeepSeek',
    baseUrl: 'https://api.deepseek.com/v1',
    model: 'deepseek-chat',
    keyHint: 'sk-...',
    suggestedMaxTokens: 8192,
  ),
  ModelPreset(
    name: 'Kimi（Moonshot）',
    baseUrl: 'https://api.moonshot.cn/v1',
    model: 'moonshot-v1-8k',
    keyHint: 'sk-...（Moonshot 开放平台创建）',
    suggestedMaxTokens: 8192,
  ),
  ModelPreset(
    name: '通义千问（DashScope）',
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    model: 'qwen-plus',
    keyHint: 'sk-...（阿里云百炼创建）',
    suggestedMaxTokens: 8192,
  ),
  ModelPreset(
    name: '智谱 GLM',
    baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
    model: 'glm-4-plus',
    keyHint: 'id/Key（智谱开放平台创建）',
    suggestedMaxTokens: 16384,
  ),
  ModelPreset(
    name: '豆包（火山方舟）',
    baseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
    model: 'doubao-1-5-pro-32k-250115',
    keyHint: 'ARK_...（火山方舟控制台创建）',
    suggestedMaxTokens: 8192,
  ),
  ModelPreset(
    name: 'OpenRouter',
    baseUrl: 'https://openrouter.ai/api/v1',
    model: 'openai/gpt-4o',
    keyHint: 'sk-or-...（OpenRouter Keys 创建）',
    suggestedMaxTokens: 16384,
  ),
  ModelPreset(
    name: 'Groq',
    baseUrl: 'https://api.groq.com/openai/v1',
    model: 'llama-3.3-70b-versatile',
    keyHint: 'gsk_...（Groq Console 创建）',
    suggestedMaxTokens: 8192,
  ),
  ModelPreset(
    name: 'MiMo 按量付费',
    baseUrl: 'https://api.xiaomimimo.com/v1',
    model: 'mimo-v2.5-pro',
    keyHint: 'sk-...（MiMo 控制台 API Keys 创建）',
    suggestedMaxTokens: 8192,
  ),
  ModelPreset(
    name: 'MiMo 订阅（Token Plan）',
    baseUrl: 'https://token-plan-cn.xiaomimimo.com/v1',
    model: 'mimo-v2.5-pro',
    keyHint: 'tp-...（订阅后在“订阅管理”里查看）',
    suggestedMaxTokens: 8192,
  ),
  ModelPreset(
    name: 'OpenCode Go',
    baseUrl: 'https://opencode.ai/zen/go/v1',
    model: 'deepseek-v4-flash',
    keyHint: 'sk-...（OpenCode Go 控制台创建）',
    suggestedMaxTokens: 32768,
  ),
];

/// 内置预设 + 用户已保存的自定义配置。同名预设用已保存的密钥和模型覆盖。
List<ApiProfile> mergeApiProfiles(Iterable<ApiProfile> saved) {
  final byName = {for (final p in saved) p.name: p};
  final all = <ApiProfile>[];
  for (final p in modelPresets) {
    final sp = byName[p.name];
    all.add(
      ApiProfile(
        name: p.name,
        baseUrl: p.baseUrl,
        apiKey: sp?.apiKey ?? '',
        model: (sp?.model.isNotEmpty ?? false) ? sp!.model : p.model,
        apiProtocol: p.apiProtocol,
      ),
    );
  }
  for (final p in saved) {
    if (modelPresets.every((m) => m.name != p.name)) all.add(p);
  }
  return all;
}

/// 按当前全局设置匹配一份已保存配置；没有精确命中时退回同接口。
ApiProfile? profileMatchingSettings(
  AppSettings s,
  Iterable<ApiProfile> profiles,
) {
  final baseUrl = s.baseUrl.trim();
  final model = s.model.trim();
  for (final p in profiles) {
    if (p.baseUrl.trim() == baseUrl && p.model.trim() == model) return p;
  }
  for (final p in profiles) {
    if (p.baseUrl.trim() == baseUrl) return p;
  }
  return null;
}
