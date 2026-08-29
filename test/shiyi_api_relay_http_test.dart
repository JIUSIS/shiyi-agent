import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/models.dart';
import 'package:shiyi_agent_app/services/shiyi_api_relay.dart';

void main() {
  test('中转服务拒绝错误令牌并使用真实 Key 请求上游', () async {
    late HttpRequest upstreamRequest;
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final upstreamDone = upstream.listen((request) async {
      upstreamRequest = request;
      await request.drain<void>();
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"ok":true}');
      await request.response.close();
    });
    final relay = ShiyiApiRelay.instance;
    await relay.start(
      settings: AppSettings(
        baseUrl: 'http://127.0.0.1:${upstream.port}/v1',
        apiKey: 'sk-local-only',
        model: 'model-a',
      ),
      token: 'relay-token',
      port: 0,
    );
    addTearDown(() async {
      await relay.stop();
      await upstreamDone.cancel();
      await upstream.close(force: true);
    });

    final bad = await HttpClient().postUrl(
      Uri.parse(
        'http://127.0.0.1:${relay.port}${ShiyiApiRelay.routePrefix}/chat/completions',
      ),
    );
    bad.headers.set('authorization', 'Bearer wrong');
    final badResponse = await bad.close();
    expect(badResponse.statusCode, HttpStatus.unauthorized);
    await badResponse.drain<void>();

    final good = await HttpClient().postUrl(
      Uri.parse(
        'http://127.0.0.1:${relay.port}${ShiyiApiRelay.routePrefix}/chat/completions',
      ),
    );
    good.headers.set('authorization', 'Bearer relay-token');
    good.write('{}');
    final goodResponse = await good.close();
    expect(goodResponse.statusCode, HttpStatus.ok);
    await goodResponse.drain<void>();
    expect(
      upstreamRequest.headers.value('authorization'),
      'Bearer sk-local-only',
    );
    expect(upstreamRequest.uri.path, '/v1/chat/completions');
  });

  test('不同拾忆配置使用独立中转路由，不会串 API Key', () async {
    final seen = <String>[];
    Future<HttpServer> upstream(String name) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        seen.add('$name:${request.headers.value('authorization')}');
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"provider":"$name"}');
        await request.response.close();
      });
      return server;
    }

    final first = await upstream('first');
    final second = await upstream('second');
    final relay = ShiyiApiRelay.instance;
    await relay.start(
      settings: AppSettings(
        baseUrl: 'http://127.0.0.1:${first.port}/v1',
        apiKey: 'fallback-key',
        model: 'fallback-model',
      ),
      token: 'relay-token',
      port: 0,
    );
    const firstProfile = ApiProfile(
      id: 'profile-first',
      name: 'First',
      baseUrl: 'unused',
      apiKey: 'first-key',
      model: 'model-first',
    );
    const secondProfile = ApiProfile(
      id: 'profile-second',
      name: 'Second',
      baseUrl: 'unused',
      apiKey: 'second-key',
      model: 'model-second',
    );
    relay.registerRoute(
      ShiyiApiRelay.routeIdForProfile(firstProfile),
      AppSettings(
        baseUrl: 'http://127.0.0.1:${first.port}/v1',
        apiKey: firstProfile.apiKey,
        model: firstProfile.model,
      ),
    );
    relay.registerRoute(
      ShiyiApiRelay.routeIdForProfile(secondProfile),
      AppSettings(
        baseUrl: 'http://127.0.0.1:${second.port}/v1',
        apiKey: secondProfile.apiKey,
        model: secondProfile.model,
      ),
    );
    addTearDown(() async {
      await relay.stop();
      await first.close(force: true);
      await second.close(force: true);
    });

    for (final profile in [firstProfile, secondProfile]) {
      final request = await HttpClient().postUrl(
        Uri.parse(
          'http://127.0.0.1:${relay.port}${ShiyiApiRelay.routePrefix}/'
          '${ShiyiApiRelay.routeIdForProfile(profile)}/chat/completions',
        ),
      );
      request.headers.set('authorization', 'Bearer relay-token');
      request.write('{}');
      final response = await request.close();
      expect(response.statusCode, HttpStatus.ok);
      await response.drain<void>();
    }

    expect(seen, contains('first:Bearer first-key'));
    expect(seen, contains('second:Bearer second-key'));
    expect(seen, isNot(contains('first:Bearer second-key')));
    expect(seen, isNot(contains('second:Bearer first-key')));
  });

  test('会话级 token 只能访问自己选中的一份手机配置', () async {
    Future<HttpServer> upstream() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        await request.drain<void>();
        request.response.write('{}');
        await request.response.close();
      });
      return server;
    }

    final first = await upstream();
    final second = await upstream();
    final relay = ShiyiApiRelay.instance;
    await relay.start(
      settings: AppSettings(
        baseUrl: 'http://127.0.0.1:${first.port}/v1',
        apiKey: 'unused',
      ),
      token: '',
      port: 0,
    );
    const profileA = ApiProfile(id: 'profile-a', name: 'A', baseUrl: 'unused');
    const profileB = ApiProfile(id: 'profile-b', name: 'B', baseUrl: 'unused');
    final routeA = ShiyiApiRelay.routeIdForProfile(
      profileA,
      sessionId: 'session-a',
    );
    final routeB = ShiyiApiRelay.routeIdForProfile(
      profileB,
      sessionId: 'session-b',
    );
    relay.registerLease(
      routeId: routeA,
      token: 'token-a',
      settings: AppSettings(
        baseUrl: 'http://127.0.0.1:${first.port}/v1',
        apiKey: 'key-a',
      ),
    );
    relay.registerLease(
      routeId: routeB,
      token: 'token-b',
      settings: AppSettings(
        baseUrl: 'http://127.0.0.1:${second.port}/v1',
        apiKey: 'key-b',
      ),
    );
    addTearDown(() async {
      await relay.stop();
      await first.close(force: true);
      await second.close(force: true);
    });

    Future<int> request(String route, String token) async {
      final outgoing = await HttpClient().postUrl(
        Uri.parse(
          'http://127.0.0.1:${relay.port}${ShiyiApiRelay.routePrefix}/'
          '$route/chat/completions',
        ),
      );
      outgoing.headers.set('authorization', 'Bearer $token');
      outgoing.write('{}');
      final response = await outgoing.close();
      final status = response.statusCode;
      await response.drain<void>();
      return status;
    }

    expect(await request(routeA, 'token-a'), HttpStatus.ok);
    expect(await request(routeB, 'token-a'), HttpStatus.unauthorized);
    expect(await request(routeB, 'token-b'), HttpStatus.ok);

    relay.revokeLease(routeA, token: 'token-a');
    expect(await request(routeA, 'token-a'), HttpStatus.unauthorized);
  });
}
