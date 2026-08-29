import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/services/dsh_api.dart';
import 'package:shiyi_agent_app/services/dsh_provider_config.dart';

void main() {
  test('协议映射覆盖 Chat、Responses 和 Claude', () {
    expect(shiyiProtocolForDshApi('openai-completions'), 'openai');
    expect(shiyiProtocolForDshApi('openai-responses'), 'responses');
    expect(shiyiProtocolForDshApi('anthropic-messages'), 'anthropic');
  });

  test('合并 settings、provider 目录和模型分组时不丢完整配置', () {
    final result = mergeDshProviderConfigs(
      settings: const [
        {
          'id': 'my_gateway',
          'displayName': '我的网关',
          'api': 'openai-responses',
          'baseURL': 'https://gateway.example/v1',
          'apiKeyEnv': 'MY_GATEWAY_API_KEY',
          'models': [
            {'id': 'model-a', 'name': 'model-a'},
          ],
        },
      ],
      directory: const [
        {
          'id': 'my_gateway',
          'declared': true,
          'settingsNs': 'llm-pi-ai',
          'settingsPath': ['providers', 'my_gateway'],
          'api': '',
          'baseURL': '',
          'apiKeyEnv': '',
          'models': [
            {'id': 'model-b', 'name': 'model-b'},
          ],
        },
      ],
      groups: [
        DshModelGroup(
          id: 'my_gateway',
          name: '我的网关',
          models: [
            DshModelInfo(
              id: 'model-c',
              name: 'model-c',
              providerId: 'my_gateway',
              providerName: '我的网关',
            ),
          ],
        ),
      ],
    );

    expect(result, hasLength(1));
    expect(result.single.displayName, '我的网关');
    expect(result.single.protocol, 'responses');
    expect(result.single.baseUrl, 'https://gateway.example/v1');
    expect(result.single.credentialRef, 'MY_GATEWAY_API_KEY');
    expect(
      result.single.models,
      containsAll(['model-a', 'model-b', 'model-c']),
    );
  });

  test('中文名称生成稳定且合法的底层标识', () {
    final first = dshProviderIdFromName('硅基流动');
    final second = dshProviderIdFromName('硅基流动');
    expect(first, second);
    expect(first, startsWith('provider_'));
    expect(isValidDshProviderId(first), isTrue);
    expect(dshCredentialRefForProvider(first), endsWith('_API_KEY'));
  });

  test('模型目录忽略只有凭据元数据的 provider', () {
    final groups = dshModelGroupsFromProviders(const [
      {
        'id': 'github-copilot',
        'displayName': 'GitHub Copilot',
        'credential': {'type': 'oauth'},
      },
      {'id': 'google', 'name': 'Google', 'models': []},
      {
        'id': 'remote-provider',
        'displayName': '远端模型',
        'models': [
          {'id': 'remote-model', 'name': 'Remote Model'},
          {'id': '  ', 'name': '空模型'},
        ],
      },
    ]);

    expect(groups, hasLength(1));
    expect(groups.single.id, 'remote-provider');
    expect(groups.single.models.map((model) => model.id), ['remote-model']);
  });

  test('模型目录支持 map 结构且过滤空模型 ID', () {
    final groups = dshModelGroupsFromProviders(const [
      {
        'providerId': 'map-provider',
        'models': {
          'first': {'model': 'model-a'},
          'empty': {'id': ''},
        },
      },
    ]);

    expect(groups, hasLength(1));
    expect(groups.single.models.map((model) => model.id), ['model-a']);
  });

  test('展示口径：内置活跃 provider 显示，内部镜像与目录噪音不显示', () {
    final result = mergeDshProviderConfigs(
      settings: const [],
      directory: const [
        {
          'provider': 'deepseek-official',
          'displayName': 'DeepSeek',
          'settingsNs': 'llm-deepseek',
          'settingsPath': <dynamic>[],
          'active': true,
        },
        {
          'provider': 'opencode-go',
          'displayName': 'opencode-go',
          'settingsNs': 'llm-pi-ai',
          'settingsPath': ['providers', 'opencode-go'],
          'active': true,
          'declared': false,
        },
        {
          'provider': 'vision-toolkit-deepseek-official',
          'displayName': 'vision-toolkit-deepseek-official',
          'settingsNs': '',
          'settingsPath': <dynamic>[],
          'active': true,
        },
        {
          'provider': 'amazon-bedrock',
          'displayName': 'amazon-bedrock',
          'settingsNs': 'llm-pi-ai',
          'settingsPath': ['providers', 'amazon-bedrock'],
          'active': false,
          'declared': false,
        },
      ],
      groups: [
        DshModelGroup(
          id: 'deepseek-official',
          name: 'DeepSeek',
          models: [
            DshModelInfo(
              id: 'deepseek-chat',
              name: 'deepseek-chat',
              providerId: 'deepseek-official',
              providerName: 'DeepSeek',
            ),
          ],
        ),
      ],
    );

    final ids = result.map((item) => item.id).toList();
    // 内置活跃（llm-deepseek）与启用的 llm-pi-ai 路由都展示。
    expect(ids, containsAll(['deepseek-official', 'opencode-go']));
    // 内部镜像（空命名空间）与未启用未手写的目录噪音不展示。
    expect(ids, isNot(contains('vision-toolkit-deepseek-official')));
    expect(ids, isNot(contains('amazon-bedrock')));
    // 内置 provider 的模型经分组并回。
    final deepseek = result.firstWhere((item) => item.id == 'deepseek-official');
    expect(deepseek.models, contains('deepseek-chat'));
    expect(deepseek.isBuiltinDeclared, isTrue);
  });
}
