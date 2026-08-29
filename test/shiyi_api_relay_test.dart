import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyi_agent_app/core/models.dart';
import 'package:shiyi_agent_app/services/dsh_api.dart';
import 'package:shiyi_agent_app/services/dsh_model_sync.dart';
import 'package:shiyi_agent_app/services/shiyi_api_relay.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  test('旧设置迁移：局域网和公网默认使用目标 DSH API', () {
    expect(
      AppSettings.fromJson({'dshConnectionMode': 'lan'}).dshApiSource,
      'dsh',
    );
    expect(
      AppSettings.fromJson({'dshConnectionMode': 'remote'}).dshApiSource,
      'dsh',
    );
    expect(AppSettings.fromJson({}).dshApiSource, 'shiyi');
  });

  test('公网 DSH 拨不进手机：injectRelayNow 拒绝并指向直接注入', () async {
    final methods = <String>[];
    final mock = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      methods.add((body['method'] ?? '').toString());
      return http.Response(
        jsonEncode({
          'type': 'server-response',
          'rpcId': 'relay-safe',
          'result': {
            'ok': true,
            'value': {'items': []},
          },
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final api = DshApiClient(baseUrl: 'http://remote.test', client: mock);
    final settings = AppSettings(
      baseUrl: 'https://secret.example/v1',
      apiKey: 'sk-never-forward',
      model: 'secret-model',
      dshConnectionMode: 'remote',
      dshRemoteUrl: 'http://remote.test',
      dshApiSource: 'shiyi',
    );

    await expectLater(
      DshModelSync.injectRelayNow(
        settings,
        api: api,
        relayBaseUrl: 'http://phone.test:43121${ShiyiApiRelay.routePrefix}',
        relayToken: 'unused-on-remote',
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('直接注入'),
        ),
      ),
    );
    expect(methods, isEmpty);
  });

  test('本机与局域网统一走手机临时中转，中转可用性不受旧 API 来源影响', () {
    expect(
      DshModelSync.canUseShiyiRelay(
        AppSettings(dshConnectionMode: 'lan', dshApiSource: 'dsh'),
      ),
      isTrue,
    );
    expect(
      DshModelSync.canUseShiyiRelay(
        AppSettings(dshConnectionMode: 'local', dshApiSource: 'dsh'),
      ),
      isTrue,
    );
    expect(
      DshModelSync.canUseShiyiRelay(
        AppSettings(dshConnectionMode: 'local', dshApiSource: 'shiyi'),
      ),
      isTrue,
    );
    expect(DshModelSync.canUseShiyiRelay(AppSettings()), isTrue);
    expect(
      DshModelSync.canUseShiyiRelay(
        AppSettings(dshConnectionMode: 'remote', dshApiSource: 'shiyi'),
      ),
      isFalse,
    );
  });

  test('安全中转不发送拾忆真实 API 地址或密钥', () async {
    final bodies = <Map<String, dynamic>>[];
    final mock = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      bodies.add(body);
      final method = body['method'];
      final value = method == 'session.list'
          ? {'items': []}
          : <String, dynamic>{};
      return http.Response(
        jsonEncode({
          'type': 'server-response',
          'rpcId': 'relay-inject',
          'result': {'ok': true, 'value': value},
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final api = DshApiClient(baseUrl: 'http://lan.test', client: mock);
    final settings = AppSettings(
      baseUrl: 'https://secret.example/v1',
      apiKey: 'sk-real-secret',
      model: 'model-a',
      dshConnectionMode: 'lan',
      dshLanHost: '192.168.2.175',
      dshLanPort: 43120,
      dshApiSource: 'shiyi',
    );

    await DshModelSync.injectRelayNow(
      settings,
      api: api,
      relayBaseUrl: 'http://phone.test:43121${ShiyiApiRelay.routePrefix}',
      relayToken: 'relay-only-token',
      isRunning: () async => true,
    );
    expect(bodies, isNotEmpty);
    expect(jsonEncode(bodies), isNot(contains('sk-real-secret')));
    expect(jsonEncode(bodies), contains(ShiyiApiRelay.routePrefix));
    expect(jsonEncode(bodies), contains('SHIYI_RELAY_TOKEN'));
    final methods = [for (final body in bodies) body['method']];
    expect(
      methods.indexOf('credentials.set'),
      lessThan(methods.indexOf('settings.mutate')),
    );
  });

  test('每份手机配置生成稳定且不同的 relay provider 与路由', () {
    const first = ApiProfile(
      id: 'profile-a',
      name: 'A',
      baseUrl: 'https://a.example/v1',
    );
    const second = ApiProfile(
      id: 'profile-b',
      name: 'B',
      baseUrl: 'https://b.example/v1',
    );
    expect(
      DshModelSync.relayProviderForProfile(first),
      DshModelSync.relayProviderForProfile(first),
    );
    expect(
      DshModelSync.relayProviderForProfile(first),
      isNot(DshModelSync.relayProviderForProfile(second)),
    );
    expect(
      ShiyiApiRelay.routeIdForProfile(first),
      isNot(ShiyiApiRelay.routeIdForProfile(second)),
    );
    expect(
      ShiyiApiRelay.routeIdForProfile(first, sessionId: 'scope-a\nsession-a'),
      isNot(
        ShiyiApiRelay.routeIdForProfile(first, sessionId: 'scope-a\nsession-b'),
      ),
    );
    expect(
      DshModelSync.isRelayProvider(DshModelSync.relayProviderForProfile(first)),
      isTrue,
    );
    final phoneA = DshModelSync.relayProviderForProfile(
      first,
      relayInstanceId: DshModelSync.relayInstanceIdForToken('phone-a-token'),
    );
    final phoneB = DshModelSync.relayProviderForProfile(
      first,
      relayInstanceId: DshModelSync.relayInstanceIdForToken('phone-b-token'),
    );
    expect(phoneA, isNot(phoneB));
    expect(
      DshModelSync.relayCredentialEnvForProvider(phoneA),
      isNot(DshModelSync.relayCredentialEnvForProvider(phoneB)),
    );
    final sessionA = DshModelSync.relayProviderForSession(
      first,
      sessionId: 'session-a',
      relayInstanceId: DshModelSync.relayInstanceIdForToken('phone-a-token'),
    );
    final sessionAAgain = DshModelSync.relayProviderForSession(
      first,
      sessionId: 'session-a',
      relayInstanceId: DshModelSync.relayInstanceIdForToken('phone-a-token'),
    );
    final sessionB = DshModelSync.relayProviderForSession(
      first,
      sessionId: 'session-b',
      relayInstanceId: DshModelSync.relayInstanceIdForToken('phone-a-token'),
    );
    expect(sessionAAgain, sessionA);
    expect(sessionB, isNot(sessionA));
    expect(
      DshModelSync.isRelayProviderForInstance(
        sessionA,
        DshModelSync.relayInstanceIdForToken('phone-a-token'),
      ),
      isTrue,
    );
  });

  test('局域网入口继续使用手机局域网 Relay 地址', () {
    expect(
      ShiyiApiRelay.reachableBaseUrl(lanIpv4: '192.168.2.161', port: 43121),
      'http://192.168.2.161:43121${ShiyiApiRelay.routePrefix}',
    );
    expect(ShiyiApiRelay.reachableBaseUrl(lanIpv4: '', port: 43121), isEmpty);
  });

  test('临时中转清理只删除指定 relay provider 与凭据', () async {
    final bodies = <Map<String, dynamic>>[];
    final mock = MockClient((request) async {
      bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
      return http.Response(
        jsonEncode({
          'type': 'server-response',
          'rpcId': 'relay-remove',
          'result': {'ok': true, 'value': <String, dynamic>{}},
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final api = DshApiClient(baseUrl: 'http://remote.test', client: mock);
    const provider = 'shiyi_relay_profile_instance_s1234';

    await DshModelSync.removeRelayNow(api: api, provider: provider);

    expect(
      [for (final body in bodies) body['method']],
      ['settings.mutate', 'credentials.unset'],
    );
    expect(bodies.first['payload']['ops'].single['path'], [
      'providers',
      provider,
    ]);
    expect(
      bodies.last['payload']['ref'],
      DshModelSync.relayCredentialEnvForProvider(provider),
    );
    await expectLater(
      DshModelSync.removeRelayNow(api: api, provider: 'deepseek-official'),
      throwsArgumentError,
    );
    expect(bodies, hasLength(2));
  });

  test('旧 Relay 默认模型覆盖会被解除并恢复 DSH 自身默认值', () async {
    final bodies = <Map<String, dynamic>>[];
    final mock = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      bodies.add(body);
      final value = body['method'] == 'settings.describe'
          ? {
              'writable': true,
              'hasDocument': true,
              'namespaces': [
                {
                  'ns': DshModelSync.defaultModelNs,
                  'user': {
                    'provider': 'shiyi_relay_old_phone',
                    'model': 'old-model',
                    'reasoningEffort': 'high',
                  },
                  'value': {
                    'provider': 'shiyi_relay_old_phone',
                    'model': 'old-model',
                  },
                  'base': {
                    'provider': DshModelSync.officialProvider,
                    'model': 'deepseek-v4-flash',
                  },
                },
              ],
            }
          : <String, dynamic>{};
      return http.Response(
        jsonEncode({
          'type': 'server-response',
          'rpcId': 'relay-default-cleanup',
          'result': {'ok': true, 'value': value},
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final api = DshApiClient(baseUrl: 'http://remote.test', client: mock);

    expect(await DshModelSync.cleanupStaleRelayDefault(api: api), isTrue);

    expect(
      [for (final body in bodies) body['method']],
      ['settings.describe', 'settings.mutate'],
    );
    final ops = (bodies.last['payload']['ops'] as List).cast<Map>();
    expect(
      [for (final op in ops) op['path']],
      [
        ['provider'],
        ['model'],
        ['reasoningEffort'],
      ],
    );
    expect(ops.every((op) => op['op'] == 'unset'), isTrue);
  });

  test('临时 Relay 前若会话已是脏 Relay，恢复到官方可用模型', () {
    final restored = DshModelSync.restorableSelection(
      DshModelSelection(
        provider: 'shiyi_relay_deleted',
        model: 'missing-model',
        reasoningEffort: 'high',
      ),
      [
        DshModelGroup(
          id: DshModelSync.officialProvider,
          name: 'DeepSeek',
          models: [
            DshModelInfo(
              id: 'deepseek-v4-flash',
              name: 'DeepSeek V4 Flash',
              providerId: DshModelSync.officialProvider,
              providerName: 'DeepSeek',
            ),
          ],
        ),
      ],
    );

    expect(restored?.provider, DshModelSync.officialProvider);
    expect(restored?.model, 'deepseek-v4-flash');
    expect(restored?.reasoningEffort, isNull);
  });

  test('临时 Relay 前的有效目标模型会原样保留用于回合后恢复', () {
    final current = DshModelSelection(
      provider: 'custom-provider',
      model: 'custom-model',
      reasoningEffort: 'max',
    );
    final restored = DshModelSync.restorableSelection(current, [
      DshModelGroup(
        id: 'custom-provider',
        name: 'Custom',
        models: [
          DshModelInfo(
            id: 'custom-model',
            name: 'Custom Model',
            providerId: 'custom-provider',
            providerName: 'Custom',
          ),
        ],
      ),
    ]);

    expect(identical(restored, current), isTrue);
  });

  test('会话级中转注入只切指定会话，不改远端默认模型', () async {
    final bodies = <Map<String, dynamic>>[];
    final mock = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      bodies.add(body);
      final method = body['method'];
      final value = method == 'session.selectModel'
          ? {
              'selected': {
                'provider': 'shiyi_relay_profile',
                'model': 'model-a',
              },
            }
          : <String, dynamic>{};
      return http.Response(
        jsonEncode({
          'type': 'server-response',
          'rpcId': 'relay-session',
          'result': {'ok': true, 'value': value},
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final api = DshApiClient(baseUrl: 'http://remote.test', client: mock);
    await DshModelSync.injectRelayNow(
      AppSettings(
        baseUrl: 'https://secret.example/v1',
        apiKey: 'real-key',
        model: 'model-a',
      ),
      api: api,
      relayBaseUrl: 'http://phone.test:43121${ShiyiApiRelay.routePrefix}/p_a',
      relayToken: 'relay-token',
      provider: 'shiyi_relay_profile',
      sessionId: 'session-a',
      isRunning: () async => true,
    );

    final methods = [for (final body in bodies) body['method']];
    expect(methods, isNot(contains('session.list')));
    expect(
      bodies.where((body) => body['method'] == 'settings.mutate'),
      hasLength(1),
    );
    final select = bodies.singleWhere(
      (body) => body['method'] == 'session.selectModel',
    );
    expect(select['payload']['sessionId'], 'session-a');
    expect(select['payload']['provider'], 'shiyi_relay_profile');
    expect(jsonEncode(bodies), isNot(contains('real-key')));
  });

  test('中转路径按协议映射到拾忆上游', () {
    final chat = ShiyiApiRelay.upstreamUri(
      AppSettings(baseUrl: 'https://api.example/v1', apiProtocol: 'openai'),
      'chat/completions',
      const {},
    );
    expect(chat.toString(), 'https://api.example/v1/chat/completions');

    final deepSeekResponses = ShiyiApiRelay.upstreamUri(
      AppSettings(
        baseUrl: 'https://api.deepseek.com/v1',
        apiProtocol: 'responses',
      ),
      'responses',
      const {},
    );
    expect(deepSeekResponses.toString(), 'https://api.deepseek.com/responses');

    final anthropic = ShiyiApiRelay.upstreamUri(
      AppSettings(
        baseUrl: 'https://api.anthropic.com',
        apiProtocol: 'anthropic',
      ),
      'v1/messages',
      const {},
    );
    expect(anthropic.toString(), 'https://api.anthropic.com/v1/messages');
  });
}
