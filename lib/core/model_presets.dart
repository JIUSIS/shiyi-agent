// 内置模型预设：一键填入 接口地址 + 模型名，方便切换服务商。
class ModelPreset {
  final String name;
  final String baseUrl;
  final String model;
  final String keyHint; // API Key 格式提示
  const ModelPreset({
    required this.name,
    required this.baseUrl,
    required this.model,
    required this.keyHint,
  });
}

const List<ModelPreset> modelPresets = [
  ModelPreset(
    name: 'DeepSeek',
    baseUrl: 'https://api.deepseek.com/v1',
    model: 'deepseek-chat',
    keyHint: 'sk-...',
  ),
  ModelPreset(
    name: 'MiMo 按量付费',
    baseUrl: 'https://api.xiaomimimo.com/v1',
    model: 'mimo-v2.5-pro',
    keyHint: 'sk-...（MiMo 控制台 API Keys 创建）',
  ),
  ModelPreset(
    name: 'MiMo 订阅（Token Plan）',
    baseUrl: 'https://token-plan-cn.xiaomimimo.com/v1',
    model: 'mimo-v2.5-pro',
    keyHint: 'tp-...（订阅后在“订阅管理”里查看）',
  ),
];
