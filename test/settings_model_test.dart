import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyi_agent_app/core/model_presets.dart';
import 'package:shiyi_agent_app/core/models.dart';
import 'package:shiyi_agent_app/services/llm_client.dart';
import 'package:shiyi_agent_app/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('enablePresence 默认关闭，并随设置 JSON 往返持久化', () {
    expect(AppSettings().enablePresence, isFalse);
    expect(AppSettings.fromJson({}).enablePresence, isFalse);
    expect(
      AppSettings.fromJson({'enablePresence': true}).enablePresence,
      isTrue,
    );

    final saved = AppSettings(enablePresence: true).toJson();
    expect(AppSettings.fromJson(saved).enablePresence, isTrue);
    expect(AppSettings().copyWith(enablePresence: true).enablePresence, isTrue);
  });

  test('enterToSend 默认开启，并随设置 JSON 往返持久化', () {
    expect(AppSettings().enterToSend, isTrue);
    expect(AppSettings.fromJson({}).enterToSend, isTrue);
    expect(AppSettings.fromJson({'enterToSend': false}).enterToSend, isFalse);

    final saved = AppSettings(enterToSend: false).toJson();
    expect(AppSettings.fromJson(saved).enterToSend, isFalse);
  });

  test('apiProtocol 默认 OpenAI，Anthropic 配置随设置 JSON 往返持久化', () {
    expect(AppSettings().apiProtocol, 'openai');
    expect(AppSettings.fromJson({}).apiProtocol, 'openai');

    final saved = AppSettings(apiProtocol: 'anthropic').toJson();
    expect(AppSettings.fromJson(saved).apiProtocol, 'anthropic');

    final profile = ApiProfile(
      name: 'Claude',
      baseUrl: 'https://api.anthropic.com',
      apiProtocol: 'anthropic',
    );
    expect(ApiProfile.fromJson(profile.toJson()).apiProtocol, 'anthropic');
    expect(ApiProfile.fromJson({}).apiProtocol, 'openai');

    final responses = AppSettings(apiProtocol: 'responses').toJson();
    expect(AppSettings.fromJson(responses).apiProtocol, 'responses');
    final responsesProfile = ApiProfile(
      name: 'Responses',
      baseUrl: 'https://api.deepseek.com/v1',
      apiProtocol: 'responses',
    );
    expect(
      ApiProfile.fromJson(responsesProfile.toJson()).apiProtocol,
      'responses',
    );
  });

  test('API 配置 ID 不依赖模型和密钥，但同名同地址之外互相隔离', () {
    final first = ApiProfile(
      name: '分组 A',
      baseUrl: 'https://gateway.example/v1',
      apiKey: 'key-a',
      model: 'model-a',
    );
    final second = ApiProfile(
      name: '分组 B',
      baseUrl: 'https://gateway.example/v1',
      apiKey: 'key-b',
      model: 'model-b',
    );

    expect(first.profileId, isNot(second.profileId));
    expect(first.copyWith(model: 'model-c').profileId, first.profileId);
    expect(ApiProfile.fromJson(first.toJson()).profileId, first.profileId);
    expect(
      AppSettings(apiProfileId: first.profileId).toJson(),
      isNot(contains('apiProfileId')),
    );
  });

  test('删除配置按 profileId 隔离，相同密钥的另一配置仍保留', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final service = SettingsService();
    final payAsYouGo = ApiProfile(
      name: 'MiMo 按量付费',
      baseUrl: 'https://api.xiaomimimo.com/v1',
      apiKey: 'same-key',
      model: 'wrong-model',
    );
    final tokenPlan = ApiProfile(
      name: 'MiMo 订阅（Token Plan）',
      baseUrl: 'https://token-plan-cn.xiaomimimo.com/v1',
      apiKey: 'same-key',
      model: 'mimo-v2.5-pro',
    );
    await service.saveProfiles([payAsYouGo, tokenPlan]);

    final remaining = await service.deleteProfile(payAsYouGo);

    expect(remaining.map((profile) => profile.profileId), [
      tokenPlan.profileId,
    ]);
    final loaded = await service.loadProfiles();
    expect(loaded, hasLength(1));
    expect(loaded.single.profileId, tokenPlan.profileId);
    expect(loaded.single.apiKey, 'same-key');
    const secure = FlutterSecureStorage();
    expect(
      await secure.read(
        key: 'shiyi_profile_api_key_v2_${payAsYouGo.profileId}',
      ),
      isNull,
    );
    expect(
      await secure.read(key: 'shiyi_profile_api_key_v2_${tokenPlan.profileId}'),
      'same-key',
    );
  });

  test('删除内置配置覆盖后，预设恢复初始值且仍保留入口', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final service = SettingsService();
    final saved = ApiProfile(
      name: 'MiMo 按量付费',
      baseUrl: 'https://api.xiaomimimo.com/v1',
      apiKey: 'wrong-key',
      model: 'wrong-model',
    );
    await service.saveProfiles([saved]);

    final remaining = await service.deleteProfile(saved);
    final restored = mergeApiProfiles(
      remaining,
    ).singleWhere((profile) => profile.name == saved.name);
    final preset = modelPresets.singleWhere((item) => item.name == saved.name);

    expect(restored.baseUrl, preset.baseUrl);
    expect(restored.model, preset.model);
    expect(restored.apiProtocol, preset.apiProtocol);
    expect(restored.apiKey, isEmpty);
  });

  test('dshStopOnExit 默认开启，并随设置 JSON 往返持久化', () {
    expect(AppSettings().dshStopOnExit, isTrue);
    expect(AppSettings.fromJson({}).dshStopOnExit, isTrue);
    expect(
      AppSettings.fromJson({'dshStopOnExit': false}).dshStopOnExit,
      isFalse,
    );

    final saved = AppSettings(dshStopOnExit: false).toJson();
    expect(AppSettings.fromJson(saved).dshStopOnExit, isFalse);
  });

  test('DSH 搜索默认自动免费引擎，并随设置 JSON 往返', () {
    expect(AppSettings().dshSearchProvider, 'auto');
    expect(AppSettings.fromJson({}).dshSearchProvider, 'auto');
    final saved = AppSettings(
      dshSearchProvider: 'ddg',
      dshSearchKey: 'sk-search',
    ).toJson();
    final restored = AppSettings.fromJson(saved);
    expect(restored.dshSearchProvider, 'ddg');
    expect(restored.dshSearchKey, 'sk-search');
  });

  test('内置预设包含 Anthropic 协议接口', () {
    final anthropic = modelPresets
        .where((p) => p.name == 'Anthropic Claude')
        .toList();
    expect(anthropic, hasLength(1));
    expect(anthropic.single.apiProtocol, 'anthropic');
    expect(anthropic.single.baseUrl, 'https://api.anthropic.com');
  });

  test('normalizeOpenAiBaseUrl 自动补 /v1，已有版本段则不动', () {
    expect(normalizeOpenAiBaseUrl(''), '');
    expect(
      normalizeOpenAiBaseUrl('https://api.example.com'),
      'https://api.example.com/v1',
    );
    expect(
      normalizeOpenAiBaseUrl('https://api.example.com/api'),
      'https://api.example.com/api/v1',
    );
    expect(
      normalizeOpenAiBaseUrl('https://api.example.com/v1'),
      'https://api.example.com/v1',
    );
    expect(
      normalizeOpenAiBaseUrl('https://api.example.com/v1/'),
      'https://api.example.com/v1',
    );
    expect(normalizeOpenAiBaseUrl('https://host/v3'), 'https://host/v3');
    expect(
      normalizeOpenAiBaseUrl('https://host/v1beta'),
      'https://host/v1beta',
    );
  });

  test('normalizeAnthropicBaseUrl 去掉结尾 /v1，避免拼成 /v1/v1', () {
    expect(
      LlmClient.normalizeAnthropicBaseUrl('https://api.anthropic.com'),
      'https://api.anthropic.com',
    );
    expect(
      LlmClient.normalizeAnthropicBaseUrl('https://api.anthropic.com/'),
      'https://api.anthropic.com',
    );
    expect(
      LlmClient.normalizeAnthropicBaseUrl('https://gateway.example.com/v1'),
      'https://gateway.example.com',
    );
    expect(
      LlmClient.normalizeAnthropicBaseUrl('https://gateway.example.com/v1/'),
      'https://gateway.example.com',
    );
    expect(
      LlmClient.normalizeAnthropicBaseUrl('https://host/api/v1'),
      'https://host/api',
    );
  });

  test('normalizeResponsesBaseUrl：DeepSeek 官方去掉 /v1，其它网关保留', () {
    expect(
      LlmClient.normalizeResponsesBaseUrl('https://api.deepseek.com/v1'),
      'https://api.deepseek.com',
    );
    expect(
      LlmClient.normalizeResponsesBaseUrl('https://api.deepseek.com/'),
      'https://api.deepseek.com',
    );
    expect(
      LlmClient.normalizeResponsesBaseUrl('https://openrouter.ai/api/v1'),
      'https://openrouter.ai/api/v1',
    );
    expect(
      LlmClient.normalizeResponsesBaseUrl(
        'https://dashscope.aliyuncs.com/compatible-mode/v1',
      ),
      'https://dashscope.aliyuncs.com/compatible-mode/v1',
    );
  });
}
