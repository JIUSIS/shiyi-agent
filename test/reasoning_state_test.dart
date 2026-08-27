import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/app_state.dart';
import 'package:shiyi_agent_app/core/model_presets.dart';
import 'package:shiyi_agent_app/core/models.dart';

void main() {
  test('拾忆思考强度按会话隔离，空值恢复提供商默认', () {
    final state = ShiyiState();

    state.setReasoningEffortForSession('session-a', 'high');
    state.setReasoningEffortForSession('session-b', 'low');

    expect(state.reasoningEffortForSession('session-a'), 'high');
    expect(state.reasoningEffortForSession('session-b'), 'low');
    expect(state.reasoningEffortForSession('session-c'), isNull);

    state.setReasoningEffortForSession('session-a', '');
    expect(state.reasoningEffortForSession('session-a'), isNull);
    expect(state.reasoningEffortForSession('session-b'), 'low');
  });

  test('拾忆思考开关与档位分离，关闭不丢上一档', () {
    final state = ShiyiState();

    state.setReasoningEffortForSession('session-a', 'low');
    expect(state.thinkingOnForSession('session-a'), isTrue);
    expect(state.reasoningEffortForSession('session-a'), 'low');

    state.setThinkingOnForSession('session-a', false);
    expect(state.thinkingOnForSession('session-a'), isFalse);
    expect(state.reasoningEffortForSession('session-a'), 'low');

    state.setThinkingOnForSession('session-a', true);
    expect(state.thinkingOnForSession('session-a'), isTrue);
    expect(state.reasoningEffortForSession('session-a'), 'low');

    state.setReasoningEffortForSession('session-a', 'off');
    expect(state.thinkingOnForSession('session-a'), isFalse);
    expect(state.reasoningEffortForSession('session-a'), 'low');

    state.setReasoningEffortForSession('session-b', 'max');
    expect(state.thinkingOnForSession('session-a'), isFalse);
    expect(state.thinkingOnForSession('session-b'), isTrue);
    expect(state.thinkingOnForSession('session-c'), isTrue);
  });

  test('拾忆会话模型按配置隔离，不改全局设置', () {
    final state = ShiyiState()
      ..settings = AppSettings(
        baseUrl: 'https://api.deepseek.com/v1',
        apiKey: 'sk-global',
        model: 'deepseek-chat',
        apiProtocol: 'openai',
      )
      ..apiProfiles = [
        const ApiProfile(
          name: 'DeepSeek',
          baseUrl: 'https://api.deepseek.com/v1',
          apiKey: 'sk-ds',
          model: 'deepseek-chat',
        ),
        const ApiProfile(
          name: 'OpenCode Go',
          baseUrl: 'https://opencode.ai/zen/go/v1',
          apiKey: 'sk-go',
          model: 'deepseek-v4-flash',
        ),
        const ApiProfile(
          name: 'Custom Claude',
          baseUrl: 'https://api.anthropic.com',
          apiKey: 'sk-ant',
          model: 'claude-sonnet-4-5',
          apiProtocol: 'anthropic',
        ),
      ]
      ..sessions = [
        Session(
          id: 'session-a',
          title: 'A',
          model: 'deepseek-chat',
          apiProfile: 'DeepSeek',
          createdAt: 1,
          updatedAt: 1,
        ),
        Session(
          id: 'session-b',
          title: 'B',
          model: 'deepseek-v4-flash',
          apiProfile: 'OpenCode Go',
          createdAt: 1,
          updatedAt: 1,
        ),
      ];

    expect(state.profileForSession('session-a')?.name, 'DeepSeek');
    expect(state.profileForSession('session-b')?.name, 'OpenCode Go');
    expect(state.clientSettingsForSession('session-a').model, 'deepseek-chat');
    expect(
      state.clientSettingsForSession('session-b').model,
      'deepseek-v4-flash',
    );
    expect(
      state.clientSettingsForSession('session-b').baseUrl,
      'https://opencode.ai/zen/go/v1',
    );
    expect(state.settings.model, 'deepseek-chat');
    expect(state.settings.baseUrl, 'https://api.deepseek.com/v1');

    final sessionA = state.sessions.firstWhere((s) => s.id == 'session-a');
    sessionA.apiProfile = 'Custom Claude';
    sessionA.model = 'claude-sonnet-4-5';

    expect(state.profileForSession('session-a')?.name, 'Custom Claude');
    expect(
      state.clientSettingsForSession('session-a').apiProtocol,
      'anthropic',
    );
    expect(
      state.clientSettingsForSession('session-a').model,
      'claude-sonnet-4-5',
    );
    expect(
      state.clientSettingsForSession('session-b').model,
      'deepseek-v4-flash',
    );
    expect(state.settings.model, 'deepseek-chat');
    expect(state.settings.apiProtocol, 'openai');

    sessionA.model = 'claude-opus-4-1';
    expect(state.profileForSession('session-a')?.name, 'Custom Claude');
    expect(
      state.clientSettingsForSession('session-a').model,
      'claude-opus-4-1',
    );
    expect(
      state.clientSettingsForSession('session-a').baseUrl,
      'https://api.anthropic.com',
    );
    expect(state.settings.model, 'deepseek-chat');
  });

  test('cachedModelsForProfile 合并配置自身模型与缓存目录', () {
    final profile = const ApiProfile(
      name: '家里的网关',
      baseUrl: 'https://home.example/v1',
      model: 'local-model',
    );
    final state = ShiyiState()
      ..apiProfiles = [profile]
      ..modelCatalogsByProfile = {
        '家里的网关': ['cached-id', 'local-model'],
      };

    expect(state.cachedModelsForProfile(profile), ['cached-id', 'local-model']);
  });

  test('同一接口的会话按稳定配置 ID 取密钥，不按模型名串组', () {
    final first = const ApiProfile(
      name: '分组 A',
      baseUrl: 'https://gateway.example/v1',
      apiKey: 'key-a',
      model: 'model-a',
    );
    final second = const ApiProfile(
      name: '分组 B',
      baseUrl: 'https://gateway.example/v1',
      apiKey: 'key-b',
      model: 'model-b',
    );
    final state = ShiyiState()
      ..settings = AppSettings(
        baseUrl: first.baseUrl,
        apiKey: 'global-key',
        model: first.model,
      )
      ..apiProfiles = [first, second]
      ..sessions = [
        Session(
          id: 'bound',
          title: 'bound',
          model: 'model-a',
          apiProfile: first.name,
          apiProfileId: second.profileId,
          createdAt: 1,
          updatedAt: 1,
        ),
        Session(
          id: 'missing',
          title: 'missing',
          model: 'model-a',
          apiProfile: '已删除分组',
          apiProfileId: 'profile_missing',
          createdAt: 1,
          updatedAt: 1,
        ),
      ];

    expect(state.profileForSession('bound')?.name, second.name);
    expect(state.clientSettingsForSession('bound').apiKey, 'key-b');
    expect(state.clientSettingsForSession('bound').baseUrl, first.baseUrl);
    expect(state.profileForSession('missing'), isNull);
    expect(state.clientSettingsForSession('missing').apiKey, isEmpty);
  });

  test('mergeApiProfiles 保留内置预设并追加自定义配置', () {
    final merged = mergeApiProfiles([
      const ApiProfile(
        name: 'DeepSeek',
        baseUrl: 'https://api.deepseek.com/v1',
        apiKey: 'sk-saved',
        model: 'deepseek-reasoner',
      ),
      const ApiProfile(
        name: '家里的网关',
        baseUrl: 'https://home.example/v1',
        apiKey: 'sk-home',
        model: 'local-model',
      ),
    ]);

    expect(merged.map((p) => p.name), containsAll(['DeepSeek', '家里的网关']));
    final deepseek = merged.firstWhere((p) => p.name == 'DeepSeek');
    expect(deepseek.apiKey, 'sk-saved');
    expect(deepseek.model, 'deepseek-reasoner');
    expect(merged.where((p) => p.name == '家里的网关'), hasLength(1));
  });
}
