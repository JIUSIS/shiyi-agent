import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/model_presets.dart';
import 'package:shiyi_agent_app/core/models.dart';
import 'package:shiyi_agent_app/services/llm_client.dart';

void main() {
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
}
