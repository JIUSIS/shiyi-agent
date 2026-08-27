import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yaml/yaml.dart';
import 'package:shiyi_agent_app/services/dsh_api.dart';
import 'package:shiyi_agent_app/core/models.dart';
import 'package:shiyi_agent_app/services/dsh_endpoint.dart';
import 'package:shiyi_agent_app/services/dsh_model_sync.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('DshModelSync file synchronization', () {
    test('注入记录按本机、局域网、公网 scope 隔离', () async {
      final local = AppSettings(
        baseUrl: 'https://local.example/v1',
        model: 'local-model',
      );
      final lan = AppSettings(
        baseUrl: 'https://lan.example/v1',
        model: 'lan-model',
        dshConnectionMode: 'lan',
        dshLanHost: '192.168.1.8',
      );
      final remote = AppSettings(
        baseUrl: 'https://remote.example/v1',
        model: 'remote-model',
        dshConnectionMode: 'remote',
        dshRemoteUrl: 'https://dsh.example.com',
      );
      final localScope = DshEndpoint.scopeKeyOf(local);
      final lanScope = DshEndpoint.scopeKeyOf(lan);
      final remoteScope = DshEndpoint.scopeKeyOf(remote);

      await DshModelSync.rememberInjectedConfig(local, scopeKey: localScope);
      await DshModelSync.rememberInjectedConfig(lan, scopeKey: lanScope);
      await DshModelSync.rememberInjectedConfig(remote, scopeKey: remoteScope);

      expect(
        (await DshModelSync.listInjectedConfigs(
          scopeKey: localScope,
        )).single.model,
        'local-model',
      );
      expect(
        (await DshModelSync.listInjectedConfigs(
          scopeKey: lanScope,
        )).single.model,
        'lan-model',
      );
      expect(
        (await DshModelSync.listInjectedConfigs(
          scopeKey: remoteScope,
        )).single.model,
        'remote-model',
      );
    });

    test('公网 live 同步只走远端 API，不读取或写入本地 DSH 文件', () async {
      final dir = await Directory.systemTemp.createTemp('dsh-remote-sync-');
      addTearDown(() => dir.delete(recursive: true));
      var homeRequested = false;
      final mock = MockClient((req) async {
        return http.Response(
          jsonEncode({
            'type': 'server-response',
            'rpcId': 'remote-sync',
            'result': {'ok': true, 'value': {}},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final settings = AppSettings(
        baseUrl: 'https://api.example/v1',
        apiKey: 'sk-remote',
        model: 'remote-model',
        dshConnectionMode: 'remote',
        dshRemoteUrl: 'https://dsh.example.com',
      );
      final api = DshApiClient(
        baseUrl: 'https://dsh.example.com',
        client: mock,
      );

      await DshModelSync.syncLive(
        settings,
        api,
        scopeKey: DshEndpoint.scopeKeyOf(settings),
        homeDir: () async {
          homeRequested = true;
          return dir.path;
        },
      );

      expect(homeRequested, isFalse);
      expect(await File('${dir.path}/settings.yaml').exists(), isFalse);
      expect(await File('${dir.path}/.credentials.yaml').exists(), isFalse);
      expect(
        await File('${dir.path}/shiyi-free-search.json').exists(),
        isFalse,
      );
    });

    test('并发同步串行替换 settings.yaml 且保留完整配置', () async {
      final dir = await Directory.systemTemp.createTemp('dsh-sync-race-');
      addTearDown(() => dir.delete(recursive: true));
      await File('${dir.path}/settings.yaml').writeAsString('''
custom:
  keep: true
''');

      final first = AppSettings(
        baseUrl: 'https://alpha.example/v1',
        apiKey: 'sk-alpha',
        model: 'alpha-model',
      );
      final second = AppSettings(
        baseUrl: 'https://beta.example/v1',
        apiKey: 'sk-beta',
        model: 'beta-model',
      );

      await Future.wait([
        for (var i = 0; i < 4; i++)
          DshModelSync.syncFiles(first, dir.path, name: 'Alpha'),
        for (var i = 0; i < 4; i++)
          DshModelSync.syncFiles(second, dir.path, name: 'Beta'),
      ]);
      await DshModelSync.waitForFileSyncs();

      final text = await File('${dir.path}/settings.yaml').readAsString();
      expect(text, startsWith('custom:\n  keep: true'));
      expect(text, contains('shiyi_alpha:'));
      expect(text, contains('shiyi_beta:'));
      expect(text, contains('baseURL: "https://alpha.example/v1"'));
      expect(text, contains('baseURL: "https://beta.example/v1"'));
      expect(await File('${dir.path}/settings.yaml.tmp').exists(), isFalse);
    });

    test('已有损坏 settings.yaml 时重建可解析文件', () async {
      final dir = await Directory.systemTemp.createTemp('dsh-sync-repair-');
      addTearDown(() => dir.delete(recursive: true));
      await File('${dir.path}/settings.yaml').writeAsString('''
llm-pi-ai:
  providers:
    shiyi:
      models:
        - id: broken
          inputs: [text]
      broken:
 invalid: true
''');

      await DshModelSync.syncFiles(
        AppSettings(
          baseUrl: 'https://repair.example/v1',
          apiKey: 'sk-repair',
          model: 'repair-model',
        ),
        dir.path,
      );

      final text = await File('${dir.path}/settings.yaml').readAsString();
      expect(() => loadYaml(text), returnsNormally);
      expect(text, contains('baseURL: "https://repair.example/v1"'));
      expect(await File('${dir.path}/settings.yaml.corrupt').exists(), isTrue);
    });
  });

  group('DshModelSync protocol / patch', () {
    test('openai -> openai-completions，anthropic -> anthropic-messages', () {
      expect(DshModelSync.dshApiFor('openai'), 'openai-completions');
      expect(DshModelSync.dshApiFor('anthropic'), 'anthropic-messages');
      expect(DshModelSync.dshApiFor('responses'), 'openai-responses');
    });

    test('mimo 与 deepseek 一样声明思考档位，对不上家族关键字的也有通用档位', () {
      expect(DshModelSync.defaultReasoningEffort('mimo-v2.5'), 'high');
      expect(DshModelSync.defaultReasoningEffort('mimo-v2.5-pro'), 'high');
      expect(DshModelSync.reasoningEffortsForModel('mimo-v2.5'), {
        'off': null,
        'low': 'low',
        'medium': 'medium',
        'high': 'high',
        'max': 'max',
      });
      expect(
        DshModelSync.defaultReasoningEffort('llama-3.3-70b-versatile'),
        isNull,
      );
      expect(DshModelSync.reasoningEffortsForModel('llama-3.3-70b-versatile'), {
        'off': null,
        'low': 'low',
        'medium': 'medium',
        'high': 'high',
        'max': 'max',
      });
    });

    test('OpenRouter 注入关闭 store，且不把 gpt-4o 当成思考模型', () {
      final s = AppSettings(
        baseUrl: 'https://openrouter.ai/api/v1',
        apiKey: 'sk-or-secret',
        model: 'openai/gpt-4o',
        apiProtocol: 'openai',
      );
      final value = DshModelSync.mutateOps(s).single['value'] as Map;
      expect(value['api'], 'openai-completions');
      expect(value['baseURL'], 'https://openrouter.ai/api/v1');
      expect(value.containsKey('reasoning'), isFalse);
      expect(value['compat'], {'supportsStore': false});
      expect((value['models'] as List).first, {
        'id': 'openai/gpt-4o',
        'name': 'openai/gpt-4o',
        'input': ['text', 'image'],
      });
      expect(value.containsKey('apiKey'), isFalse);
    });

    test('OpenRouter 思考模型仍声明 reasoning，同时关闭 store', () {
      final value =
          DshModelSync.mutateOps(
                AppSettings(
                  baseUrl: 'https://openrouter.ai/api/v1',
                  model: 'openai/gpt-5',
                ),
              ).single['value']
              as Map;
      expect(value['reasoning'], 'high');
      expect(value['compat'], {'supportsStore': false});
      expect(((value['models'] as List).first as Map)['reasoningEfforts'], {
        'off': null,
        'low': 'low',
        'medium': 'medium',
        'high': 'high',
        'xhigh': 'xhigh',
      });
    });

    test('OpenRouter settings.yaml 写出 compat.supportsStore=false', () {
      final yaml = DshModelSync.upsertSettingsYaml(
        '',
        baseUrl: 'https://openrouter.ai/api/v1',
        model: 'openai/gpt-4o',
        apiProtocol: 'openai',
      );
      expect(yaml, contains('      baseURL: "https://openrouter.ai/api/v1"'));
      expect(yaml, contains('      compat:'));
      expect(yaml, contains('        supportsStore: false'));
      expect(yaml, isNot(contains('      reasoning: high')));
      expect(yaml, isNot(contains('          reasoningEfforts:')));
    });

    test('非 OpenRouter 网关不写 store compat', () {
      final value =
          DshModelSync.mutateOps(
                AppSettings(
                  baseUrl: 'https://api.deepseek.com/v1',
                  model: 'deepseek-chat',
                ),
              ).single['value']
              as Map;
      expect(value.containsKey('compat'), isFalse);
    });

    test('手写路由 patch 含 api + baseURL + 非空 models，密钥不进 settings', () {
      final s = AppSettings(
        baseUrl: 'https://api.deepseek.com/v1',
        apiKey: 'sk-secret',
        model: 'deepseek-chat',
        apiProtocol: 'openai',
      );
      expect(DshModelSync.canWriteProvider(s), isTrue);
      final ops = DshModelSync.mutateOps(s);
      expect(ops, hasLength(1));
      expect(ops.single['op'], 'set');
      expect(ops.single['path'], ['providers', 'shiyi']);
      final value = ops.single['value'] as Map<String, dynamic>;
      expect(value['displayName'], '拾忆');
      expect(value['apiKeyEnv'], 'SHIYI_API_KEY');
      expect(value['api'], 'openai-completions');
      expect(value['baseURL'], 'https://api.deepseek.com/v1');
      expect(value['reasoning'], 'high');
      expect(value['models'], [
        {
          'id': 'deepseek-chat',
          'name': 'deepseek-chat',
          'input': ['text', 'image'],
          'reasoningEfforts': {
            'off': null,
            'low': 'low',
            'medium': 'medium',
            'high': 'high',
            'max': 'max',
          },
        },
        {
          'id': 'deepseek-v4-flash',
          'name': 'deepseek-v4-flash',
          'input': ['text', 'image'],
          'reasoningEfforts': {
            'off': null,
            'low': 'low',
            'medium': 'medium',
            'high': 'high',
            'max': 'max',
          },
        },
      ]);
      expect(value.containsKey('apiKey'), isFalse);
    });

    test('开启视觉时模型声明 image input，视觉模型不同则加入列表', () {
      final s = AppSettings(
        baseUrl: 'https://api.example.com/v1',
        apiKey: 'sk-secret',
        model: 'mimo-v2.5',
        apiProtocol: 'openai',
        visionEnabled: true,
        visionModel: 'vision-model-x',
      );
      final value = DshModelSync.mutateOps(s).single['value'] as Map;
      expect(value['models'], [
        {
          'id': 'mimo-v2.5',
          'name': 'mimo-v2.5',
          'input': ['text', 'image'],
          'reasoningEfforts': {
            'off': null,
            'low': 'low',
            'medium': 'medium',
            'high': 'high',
            'max': 'max',
          },
        },
        {
          'id': 'vision-model-x',
          'name': 'vision-model-x',
          'input': ['text', 'image'],
          'reasoningEfforts': {
            'off': null,
            'low': 'low',
            'medium': 'medium',
            'high': 'high',
            'max': 'max',
          },
        },
      ]);
    });

    test('未开启视觉时主模型仍声明 image，视觉模型不加入', () {
      final s = AppSettings(
        baseUrl: 'https://api.example.com/v1',
        model: 'mimo-v2.5',
        visionEnabled: false,
        visionModel: 'vision-model-x',
      );
      final value = DshModelSync.mutateOps(s).single['value'] as Map;
      expect(value['models'], [
        {
          'id': 'mimo-v2.5',
          'name': 'mimo-v2.5',
          'input': ['text', 'image'],
          'reasoningEfforts': {
            'off': null,
            'low': 'low',
            'medium': 'medium',
            'high': 'high',
            'max': 'max',
          },
        },
      ]);
    });

    test('响应模型别名按网关配置持久化并加入 provider', () async {
      final s = AppSettings(
        baseUrl: 'https://gateway.example/v1',
        model: 'request-alias',
        apiProtocol: 'openai',
      );
      expect(
        await DshModelSync.rememberResponseModels(s, ['gateway-real-model']),
        isTrue,
      );
      final remembered = await DshModelSync.responseModelsFor(s);
      expect(remembered, {'gateway-real-model'});
      final value =
          DshModelSync.mutateOps(s, responseModels: remembered).single['value']
              as Map;
      expect(value['models'], [
        {
          'id': 'request-alias',
          'name': 'request-alias',
          'input': ['text', 'image'],
          'reasoningEfforts': {
            'off': null,
            'low': 'low',
            'medium': 'medium',
            'high': 'high',
            'max': 'max',
          },
        },
        {
          'id': 'gateway-real-model',
          'name': 'gateway-real-model',
          'input': ['text', 'image'],
          'reasoningEfforts': {
            'off': null,
            'low': 'low',
            'medium': 'medium',
            'high': 'high',
            'max': 'max',
          },
        },
      ]);

      final otherGateway = s.copyWith(baseUrl: 'https://other.example/v1');
      expect(
        await DshModelSync.responseModelsFor(otherGateway),
        isNot(contains('gateway-real-model')),
      );
    });

    test('获取到的完整模型目录会缓存、隔离并加入 provider', () async {
      final first = AppSettings(
        baseUrl: 'https://gateway-a.example/v1',
        model: 'model-a',
        apiProtocol: 'openai',
      );
      final second = AppSettings(
        baseUrl: 'https://gateway-b.example/v1',
        model: 'model-b',
        apiProtocol: 'openai',
      );

      expect(
        await DshModelSync.rememberModelCatalog(first, [
          'model-z',
          'model-a',
          'model-c',
        ]),
        isTrue,
      );
      expect(await DshModelSync.cachedModelCatalogFor(first), [
        'model-a',
        'model-c',
        'model-z',
      ]);
      expect(await DshModelSync.cachedModelCatalogFor(second), isEmpty);

      final value = DshModelSync.providerProfile(
        first,
        catalogModels: await DshModelSync.cachedModelCatalogFor(first),
      );
      expect((value['models'] as List).map((e) => (e as Map)['id']), [
        'model-a',
        'model-c',
        'model-z',
      ]);
    });

    test('同一接口地址的不同配置 ID 不共享模型目录缓存', () async {
      final first = AppSettings(
        apiProfileId: 'profile-a',
        baseUrl: 'https://same-gateway.example/v1',
        model: 'model-a',
      );
      final second = AppSettings(
        apiProfileId: 'profile-b',
        baseUrl: 'https://same-gateway.example/v1',
        model: 'model-b',
      );

      await DshModelSync.rememberModelCatalog(first, ['only-a']);
      await DshModelSync.rememberModelCatalog(second, ['only-b']);

      expect(await DshModelSync.cachedModelCatalogFor(first), ['only-a']);
      expect(await DshModelSync.cachedModelCatalogFor(second), ['only-b']);
    });

    test('缓存模型可以删除，但当前主模型不能删除', () async {
      final settings = AppSettings(
        baseUrl: 'https://gateway.example/v1',
        model: 'keep-model',
      );
      await DshModelSync.rememberModelCatalog(settings, [
        'keep-model',
        'delete-model',
      ]);

      expect(
        await DshModelSync.removeCachedModel(settings, 'keep-model'),
        isFalse,
      );
      expect(
        await DshModelSync.removeCachedModel(settings, 'delete-model'),
        isTrue,
      );
      expect(await DshModelSync.cachedModelCatalogFor(settings), [
        'keep-model',
      ]);
    });

    test('不同配置名写成不同 provider，不会互相覆盖', () {
      final first = AppSettings(
        baseUrl: 'https://api.deepseek.com/v1',
        model: 'deepseek-chat',
      );
      final second = AppSettings(
        baseUrl: 'https://gateway.example/v1',
        model: 'local-model',
      );
      expect(DshModelSync.providerIdForName('DeepSeek'), 'shiyi_deepseek');
      final firstOps = DshModelSync.mutateOps(
        first,
        provider: DshModelSync.providerIdForName('DeepSeek'),
        name: 'DeepSeek',
      );
      final secondOps = DshModelSync.mutateOps(
        second,
        provider: DshModelSync.providerIdForName('家里的网关'),
        name: '家里的网关',
      );
      expect(firstOps.single['path'], ['providers', 'shiyi_deepseek']);
      expect(secondOps.single['path'], isNot(['providers', 'shiyi_deepseek']));
      expect(
        (firstOps.single['value'] as Map)['baseURL'],
        'https://api.deepseek.com/v1',
      );
      expect(
        (secondOps.single['value'] as Map)['baseURL'],
        'https://gateway.example/v1',
      );
    });

    test('新注入只替换同名配置，保留其它已注入项', () {
      const existing = '''
llm-pi-ai:
  providers:
    shiyi_deepseek:
      displayName: DeepSeek
      api: openai-completions
      baseURL: "https://api.deepseek.com/v1"
      models:
        - id: deepseek-chat
''';
      final yaml = DshModelSync.upsertSettingsYaml(
        existing,
        baseUrl: 'https://gateway.example/v1',
        model: 'local-model',
        apiProtocol: 'openai',
        provider: 'shiyi_home',
        name: '家里的网关',
      );
      expect(yaml, contains('    shiyi_deepseek:'));
      expect(yaml, contains('      baseURL: "https://api.deepseek.com/v1"'));
      expect(yaml, contains('        - id: deepseek-chat'));
      expect(yaml, contains('    shiyi_home:'));
      expect(yaml, contains('      baseURL: "https://gateway.example/v1"'));
      expect(yaml, contains('        - id: local-model'));
    });

    test('删除一份已注入配置不会带走其它配置', () {
      const existing = '''
llm-pi-ai:
  providers:
    shiyi_deepseek:
      displayName: DeepSeek
      api: openai-completions
    shiyi_home:
      displayName: 家里的网关
      api: openai-completions
''';
      final yaml = DshModelSync.removeProviderYaml(existing, 'shiyi_home');
      expect(yaml, contains('    shiyi_deepseek:'));
      expect(yaml, isNot(contains('    shiyi_home:')));
    });

    test('记住已注入配置时新配置追加，同名才覆盖', () async {
      final first = AppSettings(
        baseUrl: 'https://api.deepseek.com/v1',
        model: 'deepseek-chat',
      );
      final second = AppSettings(
        baseUrl: 'https://gateway.example/v1',
        model: 'local-model',
      );
      await DshModelSync.rememberInjectedConfig(first, name: 'DeepSeek');
      await DshModelSync.rememberInjectedConfig(second, name: '家里的网关');
      var listed = await DshModelSync.listInjectedConfigs();
      expect(listed.map((e) => e.name), ['DeepSeek', '家里的网关']);

      await DshModelSync.rememberInjectedConfig(
        first.copyWith(model: 'deepseek-reasoner'),
        name: 'DeepSeek',
      );
      listed = await DshModelSync.listInjectedConfigs();
      expect(listed, hasLength(2));
      expect(
        listed.firstWhere((e) => e.name == 'DeepSeek').model,
        'deepseek-reasoner',
      );
      expect(listed.firstWhere((e) => e.name == '家里的网关').model, 'local-model');
    });

    test('默认模型 mutate 切到 shiyi / 当前模型', () {
      final s = AppSettings(model: 'deepseek-v4-flash');
      final ops = DshModelSync.defaultModelOps(s);
      expect(ops, hasLength(2));
      expect(ops[0]['path'], ['provider']);
      expect(ops[0]['value'], 'shiyi');
      expect(ops[1]['path'], ['model']);
      expect(ops[1]['value'], 'deepseek-v4-flash');
    });

    test('空模型不能写手写路由', () {
      expect(DshModelSync.canWriteProvider(AppSettings(model: '')), isFalse);
    });

    test('只改主题不算模型配置变化', () {
      final a = AppSettings(model: 'm1', themeMode: 'dark');
      final b = AppSettings(model: 'm1', themeMode: 'light');
      expect(DshModelSync.isModelSettingsChange(a, b), isFalse);
      expect(
        DshModelSync.isModelSettingsChange(a, AppSettings(model: 'm2')),
        isTrue,
      );
      expect(
        DshModelSync.isModelSettingsChange(a, a.copyWith(visionEnabled: true)),
        isTrue,
      );
      expect(
        DshModelSync.isModelSettingsChange(
          a,
          a.copyWith(visionModel: 'vision-model'),
        ),
        isTrue,
      );
      expect(
        DshModelSync.isModelSettingsChange(
          a,
          AppSettings(model: 'm1', dshSearchProvider: 'ddg'),
        ),
        isTrue,
      );
    });

    test('内置搜索配置写引擎与中文区域', () {
      final config = DshModelSync.searchConfig(
        AppSettings(dshSearchProvider: 'ddg'),
      );
      expect(config, {
        'provider': 'ddg',
        'region': 'cn-zh',
        'bingMarket': 'zh-CN',
      });
    });

    test('未知搜索引擎回落自动模式', () {
      final config = DshModelSync.searchConfig(
        AppSettings(dshSearchProvider: 'unknown'),
      );
      expect(config['provider'], 'auto');
    });

    test('DeepSeek 搜索密钥优先显式配置，否则复用官方主密钥', () {
      expect(
        DshModelSync.effectiveSearchKey(
          AppSettings(
            baseUrl: 'https://api.deepseek.com/v1',
            apiKey: 'sk-main',
            dshSearchKey: 'sk-search',
          ),
        ),
        'sk-search',
      );
      expect(
        DshModelSync.effectiveSearchKey(
          AppSettings(
            baseUrl: 'https://api.deepseek.com/v1',
            apiKey: 'sk-main',
          ),
        ),
        'sk-main',
      );
    });
  });

  group('settings.yaml upsert', () {
    test('空文件写出完整 llm-pi-ai.providers.shiyi', () {
      final yaml = DshModelSync.upsertSettingsYaml(
        '',
        baseUrl: 'https://api.deepseek.com/v1',
        model: 'deepseek-chat',
        apiProtocol: 'openai',
      );
      expect(yaml, contains('llm-pi-ai:'));
      expect(yaml, contains('  providers:'));
      expect(yaml, contains('    shiyi:'));
      expect(yaml, contains('      api: openai-completions'));
      expect(yaml, contains('      baseURL: "https://api.deepseek.com/v1"'));
      expect(yaml, contains('        - id: deepseek-chat'));
      expect(yaml, contains('        - id: deepseek-v4-flash'));
      expect(yaml, contains('          reasoningEfforts:'));
      expect(yaml, contains('            off: null'));
      expect(yaml, contains('            low: low'));
      expect(yaml, contains('            high: high'));
      expect(yaml, contains('            max: max'));
      expect(yaml, isNot(contains('reasoningEfforts: [')));
    });

    test('历史发现的响应模型别名写进 settings.yaml', () {
      final yaml = DshModelSync.upsertSettingsYaml(
        '',
        baseUrl: 'https://gateway.example/v1',
        model: 'request-alias',
        apiProtocol: 'openai',
        responseModels: const {'gateway-real-model'},
      );
      expect(yaml, contains('        - id: request-alias'));
      expect(yaml, contains('        - id: gateway-real-model'));
    });

    test('已有其他命名空间时只追加 llm-pi-ai', () {
      const existing = 'credentials:\n  path: .credentials.yaml\n';
      final yaml = DshModelSync.upsertSettingsYaml(
        existing,
        baseUrl: 'https://example.com/v1',
        model: 'foo',
        apiProtocol: 'openai',
      );
      expect(yaml, startsWith('credentials:'));
      expect(yaml, contains('path: .credentials.yaml'));
      expect(yaml, contains('llm-pi-ai:'));
      expect(yaml, contains('    shiyi:'));
    });

    test('settings.yaml 追加 agent-default-model', () {
      final yaml = DshModelSync.upsertDefaultModelYaml(
        'llm-pi-ai:\n  providers: {}\n',
        'deepseek-v4-flash',
      );
      expect(yaml, contains('llm-pi-ai:'));
      expect(yaml, contains('agent-default-model:'));
      expect(yaml, contains('  provider: shiyi'));
      expect(yaml, contains('  model: deepseek-v4-flash'));
    });

    test('Cordis 补丁为 spawn/fork 指定 shiyi 默认模型', () {
      final patch = DshModelSync.upsertAgentDefaultModelPatchYaml(
        '',
        'deepseek-v4-flash',
      );
      expect(patch, contains('- id: agent-default-model'));
      expect(patch, contains('    provider: shiyi'));
      expect(patch, contains('    model: deepseek-v4-flash'));
    });

    test('Cordis 默认模型补丁更新时替换自身且保留用户条目', () {
      const existing = '''
- id: telemetry
  config:
    enabled: false
# ShiYi agent default model: begin
- id: agent-default-model
  config:
    provider: shiyi
    model: old-model
# ShiYi agent default model: end
''';
      final patch = DshModelSync.upsertAgentDefaultModelPatchYaml(
        existing,
        'new-model',
      );
      expect(patch, contains('- id: telemetry'));
      expect(patch, contains('    model: new-model'));
      expect(patch, isNot(contains('    model: old-model')));
      expect(
        '# ShiYi agent default model: begin'.allMatches(patch),
        hasLength(1),
      );
    });

    test('Cordis 默认模型补丁替换空列表模板', () {
      final patch = DshModelSync.upsertAgentDefaultModelPatchYaml(
        '# template\n[]\n',
        'deepseek-v4-flash',
      );
      expect(patch, startsWith('# template'));
      expect(patch, isNot(contains('\n[]')));
      expect(patch, contains('provider: shiyi'));
    });

    test('已有其他提供商时只替换 shiyi，不删 openai', () {
      const existing = '''
llm-pi-ai:
  providers:
    openai:
      apiKeyEnv: OPENAI_API_KEY
    shiyi:
      api: openai-completions
      baseURL: https://old.example/v1
      models:
        - id: old
''';
      final yaml = DshModelSync.upsertSettingsYaml(
        existing,
        baseUrl: 'https://new.example/v1',
        model: 'new-model',
        apiProtocol: 'anthropic',
      );
      expect(yaml, contains('    openai:'));
      expect(yaml, contains('      apiKeyEnv: OPENAI_API_KEY'));
      expect(yaml, contains('    shiyi:'));
      expect(yaml, contains('      api: anthropic-messages'));
      expect(yaml, contains('      baseURL: "https://new.example/v1"'));
      expect(yaml, contains('        - id: new-model'));
      expect(yaml, isNot(contains('https://old.example/v1')));
      expect(yaml, isNot(contains('- id: old')));
    });

    test('搜索配置迁移：清理两个旧段并保留其他命名空间', () {
      const existing = '''
llm-pi-ai:
  providers:
    shiyi:
      api: openai-completions
web-search-deepseek:
  apiKey: sk-old
shiyi-free-search:
  provider: bing
''';
      final yaml = DshModelSync.removeLegacySearchSections(existing);
      expect(yaml, contains('    shiyi:'));
      expect(yaml, isNot(contains('web-search-deepseek:')));
      expect(yaml, isNot(contains('shiyi-free-search:')));
      expect(yaml, isNot(contains('sk-old')));
    });

    test('搜索配置写入独立 JSON', () async {
      final dir = await Directory.systemTemp.createTemp('dsh-search-');
      addTearDown(() => dir.delete(recursive: true));
      await DshModelSync.writeSearchConfig(
        dir.path,
        AppSettings(dshSearchProvider: 'ddg-lite'),
      );
      final file = File('${dir.path}/${DshModelSync.searchConfigFile}');
      expect(jsonDecode(await file.readAsString()), {
        'provider': 'ddg-lite',
        'region': 'cn-zh',
        'bingMarket': 'zh-CN',
      });

      await DshModelSync.writeSearchConfig(
        dir.path,
        AppSettings(dshSearchProvider: 'bing'),
      );
      expect(jsonDecode(await file.readAsString())['provider'], 'bing');
    });

    test('运行中同步会从 settings.yaml 清掉旧搜索段', () async {
      final dir = await Directory.systemTemp.createTemp('dsh-search-yaml-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/settings.yaml');
      await file.writeAsString('''
llm-pi-ai:
  providers: {}
shiyi-free-search:
  provider: ddg
web-search-deepseek:
  apiKey: old
''');
      await DshModelSync.cleanupLegacySearchSettingsFile(dir.path);
      final yaml = await file.readAsString();
      expect(yaml, contains('llm-pi-ai:'));
      expect(yaml, isNot(contains('shiyi-free-search:')));
      expect(yaml, isNot(contains('web-search-deepseek:')));
    });
  });

  group('credentials.yaml upsert', () {
    test('新增、更新、清空密钥', () {
      final added = DshModelSync.upsertCredentialsYaml(
        'OPENAI_API_KEY: sk-old\n',
        'SHIYI_API_KEY',
        'sk-new',
      );
      expectDshCredentials(added, {
        'OPENAI_API_KEY': 'sk-old',
        'SHIYI_API_KEY': 'sk-new',
      });

      final updated = DshModelSync.upsertCredentialsYaml(
        added,
        'SHIYI_API_KEY',
        'sk-newer',
      );
      expectDshCredentials(updated, {
        'OPENAI_API_KEY': 'sk-old',
        'SHIYI_API_KEY': 'sk-newer',
      });
      expect(updated, isNot(contains('sk-new\n')));

      final cleared = DshModelSync.upsertCredentialsYaml(
        updated,
        'SHIYI_API_KEY',
        '',
      );
      expectDshCredentials(cleared, {'OPENAI_API_KEY': 'sk-old'});
      expect(cleared, isNot(contains('SHIYI_API_KEY')));
    });

    test('含换行的密钥转义为 \\n，YAML 保持单行合法', () {
      final out = DshModelSync.upsertCredentialsYaml(
        '',
        'SHIYI_API_KEY',
        'sk-line1\nsk-line2',
      );
      expect(out, contains(r'SHIYI_API_KEY: "sk-line1\nsk-line2"'));
      expectDshCredentials(out, {'SHIYI_API_KEY': 'sk-line1\nsk-line2'});
      expect(
        out.split('\n').where((l) => l.contains('SHIYI_API_KEY')),
        hasLength(1),
      );
    });

    test('含引号/反斜杠/制表符的密钥正确转义', () {
      final out = DshModelSync.upsertCredentialsYaml(
        '',
        'SHIYI_API_KEY',
        'sk-a"b\\c\td',
      );
      expect(out, contains(r'"sk-a\"b\\c\td"'));
      expectDshCredentials(out, {'SHIYI_API_KEY': 'sk-a"b\\c\td'});
    });

    test('读入已损坏文件时清洗非法行并重写', () {
      const broken = '''
SHIYI_API_KEY: "sk-part1
sk-part2"
garbage line without colon
OPENAI_API_KEY: sk-keep
''';
      final out = DshModelSync.upsertCredentialsYaml(
        broken,
        'SHIYI_API_KEY',
        'sk-good',
      );
      expectDshCredentials(out, {
        'OPENAI_API_KEY': 'sk-keep',
        'SHIYI_API_KEY': 'sk-good',
      });
      expect(out, isNot(contains('sk-part1')));
      expect(out, isNot(contains('garbage line')));
    });

    test('DSH 0.1.1 versioned 文档上 upsert 不得把密钥写回顶层', () {
      const existing = '''
version: 1
refs:
  OPENAI_API_KEY: sk-old
  SHIYI_API_KEY: sk-stale
''';
      final out = DshModelSync.upsertCredentialsYaml(
        existing,
        'SHIYI_API_KEY',
        'sk-new',
      );
      expectDshCredentials(out, {
        'OPENAI_API_KEY': 'sk-old',
        'SHIYI_API_KEY': 'sk-new',
      });
    });

    test('versioned 文档夹杂顶层 SHIYI_API_KEY 时收进 refs', () {
      // DSH 0.1.1-rc.2 会先把旧扁平文件迁成 version:1；拾忆旧写入器再把
      // SHIYI_API_KEY 追加到顶层，启动即 unknown top-level key。
      const mixed = '''
version: 1
refs:
  OPENAI_API_KEY: sk-old
  SHIYI_DSH_SEARCH_KEY: sk-search
SHIYI_API_KEY: sk-stray
''';
      final out = DshModelSync.upsertCredentialsYaml(
        mixed,
        'SHIYI_API_KEY',
        'sk-fixed',
      );
      expectDshCredentials(out, {
        'OPENAI_API_KEY': 'sk-old',
        'SHIYI_DSH_SEARCH_KEY': 'sk-search',
        'SHIYI_API_KEY': 'sk-fixed',
      });
    });

    test('upsert 保留 records 段', () {
      const existing = '''
version: 1
refs:
  DEEPSEEK_API_KEY: sk-ds
records:
  llm-pi-ai/amazon-bedrock:
    kind: api-key
    env:
      AWS_PROFILE: prod
''';
      final out = DshModelSync.upsertCredentialsYaml(
        existing,
        'SHIYI_API_KEY',
        'sk-new',
      );
      expectDshCredentials(out, {
        'DEEPSEEK_API_KEY': 'sk-ds',
        'SHIYI_API_KEY': 'sk-new',
      });
      final doc = loadYaml(out) as YamlMap;
      expect(doc['records'], isA<YamlMap>());
      expect(
        ((doc['records'] as YamlMap)['llm-pi-ai/amazon-bedrock']
            as YamlMap)['kind'],
        'api-key',
      );
    });
  });

  group('credentials file / live fallback', () {
    test('writeCredentialsFile 写出模型与搜索凭据', () async {
      final dir = await Directory.systemTemp.createTemp('dsh-cred-');
      addTearDown(() => dir.delete(recursive: true));
      await DshModelSync.writeCredentialsFile(
        dir.path,
        'sk-file',
        searchKey: 'sk-search',
      );
      final text = await File('${dir.path}/.credentials.yaml').readAsString();
      expectDshCredentials(text, {
        'SHIYI_API_KEY': 'sk-file',
        'SHIYI_DSH_SEARCH_KEY': 'sk-search',
      });
    });

    test('credentials.set 失败时回退写文件', () async {
      final dir = await Directory.systemTemp.createTemp('dsh-live-');
      addTearDown(() => dir.delete(recursive: true));
      final mock = MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        if (body['method'] == 'credentials.set') {
          return http.Response(
            jsonEncode({
              'type': 'server-response',
              'rpcId': 'x',
              'result': {
                'ok': false,
                'error': {
                  'code': 'bad-request',
                  'message': 'invalid payload for credentials.set',
                },
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode({
            'type': 'server-response',
            'rpcId': 'x',
            'result': {'ok': true, 'value': {}},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final api = DshApiClient(baseUrl: 'http://test.local', client: mock);
      await DshModelSync.syncLive(
        AppSettings(
          baseUrl: 'https://opencode.ai/zen/go/v1',
          apiKey: 'sk-live',
          model: 'deepseek-v4-flash',
        ),
        api,
        homeDir: () async => dir.path,
      );
      final text = await File('${dir.path}/.credentials.yaml').readAsString();
      expectDshCredentials(text, {'SHIYI_API_KEY': 'sk-live'});
    });

    test('llm-pi-ai 未注册时回退修复 settings.yaml', () async {
      final dir = await Directory.systemTemp.createTemp('dsh-live-repair-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/settings.yaml');
      await file.writeAsString('''
llm-pi-ai:
  providers:
    shiyi:
      models:
        - id: deepseek-v4-flash
          reasoningEfforts: [off, low, high, max]
''');
      final mock = MockClient((req) async {
        return http.Response(
          jsonEncode({
            'type': 'server-response',
            'rpcId': 'x',
            'result': {
              'ok': false,
              'error': {
                'code': 'settings-rejected',
                'message': 'settings namespace "llm-pi-ai" is not registered',
              },
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final api = DshApiClient(baseUrl: 'http://test.local', client: mock);

      await DshModelSync.syncFromShiyi(
        AppSettings(
          baseUrl: 'https://api.deepseek.com/v1',
          apiKey: 'sk-live',
          model: 'deepseek-v4-flash',
        ),
        api: api,
        isRunning: () async => true,
        homeDir: () async => dir.path,
      );

      final text = await file.readAsString();
      expect(text, contains('          reasoningEfforts:'));
      expect(text, contains('            off: null'));
      expect(text, contains('            high: high'));
      expect(text, isNot(contains('reasoningEfforts: [')));
    });
  });

  group('injectNow 同步已有会话模型', () {
    Map<String, dynamic> okValue(Map<String, dynamic> value) => {
      'type': 'server-response',
      'rpcId': 'x',
      'result': {'ok': true, 'value': value},
    };

    http.Response ok(Map<String, dynamic> value) => http.Response(
      jsonEncode(okValue(value)),
      200,
      headers: {'content-type': 'application/json'},
    );

    test('旧 provider / 旧模型会话全部切到新模型', () async {
      final dir = await Directory.systemTemp.createTemp('dsh-inject-');
      addTearDown(() => dir.delete(recursive: true));
      final calls = <String>[];
      final mock = MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final method = body['method'] as String? ?? '';
        final payload =
            (body['payload'] as Map?)?.cast<String, dynamic>() ?? {};
        if (method == 'session.list') {
          return ok({
            'items': [
              {'sessionId': 's1'},
              {'sessionId': 's2'},
            ],
          });
        }
        if (method == 'session.models') {
          final id = payload['sessionId'];
          return ok({
            'current': id == 's1'
                ? {'provider': 'deepseek-official', 'model': 'deepseek-chat'}
                : {'provider': 'shiyi', 'model': 'deepseek-chat'},
            'groups': [],
          });
        }
        if (method == 'session.selectModel') {
          calls.add(
            '${payload['sessionId']}:${payload['provider']}:${payload['model']}',
          );
          return ok({
            'selected': {
              'provider': payload['provider'],
              'model': payload['model'],
            },
          });
        }
        return ok({});
      });
      final api = DshApiClient(baseUrl: 'http://test.local', client: mock);
      await DshModelSync.injectNow(
        AppSettings(
          baseUrl: 'https://api.test/v1',
          apiKey: 'sk-test',
          model: 'deepseek-v4-flash',
          apiProtocol: 'openai',
        ),
        api: api,
        isRunning: () async => true,
        homeDir: () async => dir.path,
      );
      expect(
        calls,
        containsAll([
          's1:shiyi:deepseek-v4-flash',
          's2:shiyi:deepseek-v4-flash',
        ]),
      );
    });

    test('已经是拾忆当前模型的会话不重复 selectModel', () async {
      final dir = await Directory.systemTemp.createTemp('dsh-inject-');
      addTearDown(() => dir.delete(recursive: true));
      final calls = <String>[];
      final mock = MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final method = body['method'] as String? ?? '';
        if (method == 'session.list') {
          return ok({
            'items': [
              {'sessionId': 's1'},
            ],
          });
        }
        if (method == 'session.models') {
          return ok({
            'current': {'provider': 'shiyi', 'model': 'deepseek-v4-flash'},
            'groups': [],
          });
        }
        if (method == 'session.selectModel') calls.add('unexpected');
        return ok({});
      });
      final api = DshApiClient(baseUrl: 'http://test.local', client: mock);
      await DshModelSync.injectNow(
        AppSettings(
          baseUrl: 'https://api.test/v1',
          apiKey: 'sk-test',
          model: 'deepseek-v4-flash',
          apiProtocol: 'openai',
        ),
        api: api,
        isRunning: () async => true,
        homeDir: () async => dir.path,
      );
      expect(calls, isEmpty);
    });
  });

  group('会话级模型同步不覆盖已有选择', () {
    Map<String, dynamic> okValue(Map<String, dynamic> value) => {
      'type': 'server-response',
      'rpcId': 'x',
      'result': {'ok': true, 'value': value},
    };

    http.Response ok(Map<String, dynamic> value) => http.Response(
      jsonEncode(okValue(value)),
      200,
      headers: {'content-type': 'application/json'},
    );

    test('syncSessionToAppModel 已有模型时不 selectModel', () async {
      final calls = <String>[];
      final mock = MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final method = body['method'] as String? ?? '';
        if (method == 'session.models') {
          return ok({
            'current': {'provider': 'shiyi', 'model': 'user-chosen-model'},
            'groups': [],
          });
        }
        if (method == 'session.selectModel') {
          calls.add('unexpected');
        }
        return ok({});
      });
      final api = DshApiClient(baseUrl: 'http://test.local', client: mock);
      await DshModelSync.syncSessionToAppModel(
        api,
        's1',
        AppSettings(
          baseUrl: 'https://api.test/v1',
          apiKey: 'sk-test',
          model: 'deepseek-v4-flash',
        ),
      );
      expect(calls, isEmpty);
    });

    test('syncSessionToAppModel 空模型时补上当前全局模型', () async {
      final calls = <String>[];
      final mock = MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final method = body['method'] as String? ?? '';
        final payload =
            (body['payload'] as Map?)?.cast<String, dynamic>() ?? {};
        if (method == 'session.models') {
          return ok({
            'current': {'provider': 'shiyi', 'model': ''},
            'groups': [],
          });
        }
        if (method == 'session.selectModel') {
          calls.add('${payload['provider']}:${payload['model']}');
          return ok({
            'selected': {
              'provider': payload['provider'],
              'model': payload['model'],
            },
          });
        }
        return ok({});
      });
      final api = DshApiClient(baseUrl: 'http://test.local', client: mock);
      await DshModelSync.syncSessionToAppModel(
        api,
        's1',
        AppSettings(
          baseUrl: 'https://api.test/v1',
          apiKey: 'sk-test',
          model: 'deepseek-v4-flash',
        ),
      );
      expect(calls, ['shiyi:deepseek-v4-flash']);
    });
  });
}

/// DSH 0.1.1-rc.2 `parseCredentialsDocument`：顶层只认 version / refs / records。
void expectDshCredentials(String text, Map<String, String> refs) {
  final doc = loadYaml(text);
  expect(doc, isA<YamlMap>());
  final root = doc as YamlMap;
  expect(root['version'], 1, reason: 'DSH 0.1.1 拒绝无 version 的扁平文档');
  for (final key in root.keys) {
    expect(
      const {'version', 'refs', 'records'},
      contains(key.toString()),
      reason: 'DSH 0.1.1 会 unknown top-level key "$key"',
    );
  }
  final stored = <String, String>{};
  final refsNode = root['refs'];
  if (refsNode is YamlMap) {
    for (final e in refsNode.entries) {
      stored[e.key.toString()] = e.value.toString();
    }
  }
  expect(stored, refs);
}
