import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shiyi_agent_app/core/models.dart';
import 'package:shiyi_agent_app/services/dsh_api.dart';
import 'package:shiyi_agent_app/services/dsh_endpoint.dart';
import 'package:shiyi_agent_app/services/dsh_live.dart';
import 'package:shiyi_agent_app/services/dsh_service.dart';

void main() {
  test('连接模式非法值回落到本机', () {
    expect(DshEndpoint.modeOf(AppSettings()), 'local');
    expect(DshEndpoint.modeOf(AppSettings(dshConnectionMode: 'LAN')), 'lan');
    expect(
      DshEndpoint.modeOf(AppSettings(dshConnectionMode: 'Remote')),
      'remote',
    );
    expect(DshEndpoint.modeOf(AppSettings(dshConnectionMode: 'foo')), 'local');
    expect(DshEndpoint.isLocal(AppSettings()), isTrue);
    expect(DshEndpoint.urlOf(AppSettings()), DshEndpoint.localUrl);
  });

  test('本机保留页面缓存，局域网 / 公网强制实时加载页面数据', () {
    expect(DshEndpoint.requiresLivePageData(null), isFalse);
    expect(DshEndpoint.requiresLivePageData(AppSettings()), isFalse);
    expect(
      DshEndpoint.requiresLivePageData(AppSettings(dshConnectionMode: 'lan')),
      isTrue,
    );
    expect(
      DshEndpoint.requiresLivePageData(
        AppSettings(dshConnectionMode: 'remote'),
      ),
      isTrue,
    );
  });

  test('三种模式统一使用目标 DSH 模型目录（本机 = 局域网）', () {
    expect(
      DshEndpoint.usesTargetModelCatalog(
        AppSettings(dshConnectionMode: 'lan', dshApiSource: 'shiyi'),
      ),
      isTrue,
    );
    expect(
      DshEndpoint.usesTargetModelCatalog(
        AppSettings(dshConnectionMode: 'local', dshApiSource: 'dsh'),
      ),
      isTrue,
    );
    expect(
      DshEndpoint.usesTargetModelCatalog(
        AppSettings(dshConnectionMode: 'local', dshApiSource: 'shiyi'),
      ),
      isTrue,
    );
  });

  test('局域网 URL 规范化', () {
    expect(DshEndpoint.lanUrl('', 3080), '');
    expect(DshEndpoint.lanUrl('192.168.1.8', 3080), 'http://192.168.1.8:3080');
    expect(
      DshEndpoint.lanUrl('192.168.1.8:3090', 3080),
      'http://192.168.1.8:3090',
    );
    expect(
      DshEndpoint.lanUrl('http://192.168.1.8:3080/', 1),
      'http://192.168.1.8:3080',
    );
    expect(
      DshEndpoint.lanUrl('https://nas.local/dsh', 3080),
      'https://nas.local:3080/dsh',
    );
    expect(DshEndpoint.lanUrl('pc.local', 0), 'http://pc.local:3080');
  });

  test('公网域名缺 scheme 按 https，裸 IP 按 http，并保留路径前缀', () {
    expect(DshEndpoint.remoteUrl(''), '');
    expect(DshEndpoint.remoteUrl('dsh.example.com'), 'https://dsh.example.com');
    expect(
      DshEndpoint.remoteUrl('203.0.113.8:3080'),
      'http://203.0.113.8:3080',
    );
    expect(
      DshEndpoint.remoteUrl('[2001:db8::8]:3080'),
      'http://[2001:db8::8]:3080',
    );
    expect(
      DshEndpoint.remoteUrl('dsh.example.com:3080'),
      'https://dsh.example.com:3080',
    );
    expect(
      DshEndpoint.remoteUrl('https://dsh.example.com/app/'),
      'https://dsh.example.com/app',
    );
    expect(
      DshEndpoint.remoteUrl('http://dsh.example.com:8443'),
      'http://dsh.example.com:8443',
    );
  });

  test('urlOf 空地址不回落到本机', () {
    expect(DshEndpoint.urlOf(AppSettings(dshConnectionMode: 'lan')), '');
    expect(DshEndpoint.urlOf(AppSettings(dshConnectionMode: 'remote')), '');
    expect(
      DshEndpoint.urlOf(
        AppSettings(dshConnectionMode: 'lan', dshLanHost: '10.0.0.2'),
      ),
      'http://10.0.0.2:3080',
    );
  });

  test('识别远程 IP literal，不把域名当 IP', () {
    expect(DshEndpoint.isIpLiteralUrl('203.0.113.8:3080'), isTrue);
    expect(DshEndpoint.isIpLiteralUrl('http://203.0.113.8:3080'), isTrue);
    expect(DshEndpoint.isIpLiteralUrl('http://[2001:db8::8]:3080'), isTrue);
    expect(DshEndpoint.isIpLiteralUrl('https://dsh.example.com'), isFalse);
  });

  test('Host 扫描只在远程模式启用，且不复用局域网配置', () {
    final lanSettings = AppSettings(
      dshConnectionMode: 'lan',
      dshLanHost: '192.168.2.175',
      dshLanPort: 43120,
      dshRemoteHost: '10.0.0.8:3080',
    );
    expect(DshEndpoint.remoteCompatibilityHosts(lanSettings), isEmpty);

    final remoteSettings = AppSettings(
      dshConnectionMode: 'remote',
      dshRemoteUrl: '103.236.89.105:56646',
      dshRemoteHost: '192.168.2.175:43120',
      dshLanHost: '192.168.9.9',
      dshLanPort: 9999,
    );
    expect(
      DshEndpoint.remoteCustomCompatibilityHosts(remoteSettings),
      containsAllInOrder([
        '192.168.2.175:43120',
        '192.168.2.175:56646',
        '192.168.2.175:3080',
      ]),
    );
    expect(
      DshEndpoint.remoteCompatibilityHosts(remoteSettings),
      isNot(contains('192.168.9.9:9999')),
    );
    expect(
      DshEndpoint.remotePresetCompatibilityHosts(remoteSettings),
      containsAll(['127.0.0.1:56646', 'localhost:43120', '0.0.0.0:3080']),
    );
    expect(
      DshEndpoint.remotePresetCompatibilityHosts(
        AppSettings(
          dshConnectionMode: 'remote',
          dshRemoteUrl: 'dsh.example.com',
        ),
      ),
      contains('127.0.0.1:43120'),
    );
  });

  test('连接设置 JSON 往返，默认仍是本机', () {
    expect(AppSettings().dshConnectionMode, 'local');
    expect(AppSettings().dshLanPort, 3080);
    expect(AppSettings.fromJson({}).dshConnectionMode, 'local');
    final saved = AppSettings(
      dshConnectionMode: 'lan',
      dshLanHost: '192.168.1.8',
      dshLanPort: 3090,
      dshRemoteUrl: 'https://dsh.example.com',
      dshRemoteHost: '192.168.2.175:43120',
      dshRemoteToken: 'secret',
    ).toJson();
    final restored = AppSettings.fromJson(saved);
    expect(restored.dshConnectionMode, 'lan');
    expect(restored.dshLanHost, '192.168.1.8');
    expect(restored.dshLanPort, 3090);
    expect(restored.dshRemoteUrl, 'https://dsh.example.com');
    expect(restored.dshRemoteHost, '192.168.2.175:43120');
    expect(restored.dshRemoteToken, 'secret');
    expect(AppSettings.fromJson({'dshLanPort': 0}).dshLanPort, 3080);
    expect(
      AppSettings.fromJson({'dshConnectionMode': 'nope'}).dshConnectionMode,
      'local',
    );
  });

  test('本机、局域网、公网各自拥有独立连接 scope 和客户端', () {
    final local = AppSettings();
    final lan = AppSettings(
      dshConnectionMode: 'lan',
      dshLanHost: '127.0.0.1',
      dshLanPort: 3080,
    );
    final remote = AppSettings(
      dshConnectionMode: 'remote',
      dshRemoteUrl: 'http://127.0.0.1:3080',
    );
    expect(DshEndpoint.scopeKeyOf(local), isNot(DshEndpoint.scopeKeyOf(lan)));
    expect(DshEndpoint.scopeKeyOf(lan), isNot(DshEndpoint.scopeKeyOf(remote)));

    final service = DshService.instance;
    final localApi = service.apiFor(local);
    final lanApi = service.apiFor(lan);
    final remoteApi = service.apiFor(remote);
    expect(localApi, isNot(same(lanApi)));
    expect(lanApi, isNot(same(remoteApi)));
    expect(localApi.baseUrl, DshEndpoint.localUrl);
    expect(lanApi.baseUrl, 'http://127.0.0.1:3080');
    expect(remoteApi.baseUrl, 'http://127.0.0.1:3080');
    expect(localApi.debugWebSocketHeaders(), isEmpty);
    expect(lanApi.debugWebSocketHeaders(), {
      'Host': '127.0.0.1:3080',
      'Origin': 'http://127.0.0.1:3080',
    });
    expect(remoteApi.debugWebSocketHeaders(), isEmpty);

    service.applyConnection(lan);
    expect(service.api, same(lanApi));
    service.applyConnection(remote);
    expect(service.api, same(remoteApi));
    service.applyConnection(local);
    expect(service.api, same(localApi));
  });

  test('WS uriFor 保留路径前缀', () {
    expect(
      DshWsDownlink.uriFor('http://127.0.0.1:3080', 'events.mux').toString(),
      'ws://127.0.0.1:3080/api/events.mux',
    );
    expect(
      DshWsDownlink.uriFor(
        'https://dsh.example.com/app',
        'events.host',
      ).toString(),
      'wss://dsh.example.com/app/api/events.host',
    );
  });

  test('configure 后 RPC 打到新地址并带 Bearer', () async {
    http.BaseRequest? captured;
    final mock = MockClient((req) async {
      captured = req;
      return http.Response(
        jsonEncode({
          'type': 'server-response',
          'rpcId': 'test-rpc',
          'result': {
            'ok': true,
            'value': {'items': []},
          },
        }),
        200,
      );
    });
    final client = DshApiClient(baseUrl: 'http://old.local', client: mock);
    client.configure(baseUrl: 'https://dsh.example.com/app', token: 'abc');
    expect(await client.rpcPing(), isTrue);
    expect(captured, isNotNull);
    expect(
      captured!.url.toString(),
      'https://dsh.example.com/app/api/session.list',
    );
    expect(captured!.headers['authorization'], 'Bearer abc');
  });
}
