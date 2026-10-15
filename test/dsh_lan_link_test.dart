import 'package:flutter_test/flutter_test.dart';

import 'package:shiyi_agent_app/services/dsh_endpoint.dart';

/// 局域网「一条链接」解析 / 合成回归。
/// 见 docs/fix-log.md #387。
void main() {
  group('parseLanInput', () {
    test('裸 IP 用默认端口', () {
      final r = DshEndpoint.parseLanInput('192.168.1.8');
      expect(r.host, '192.168.1.8');
      expect(r.port, 3080);
      expect(r.token, '');
    });

    test('host:port 取到端口', () {
      final r = DshEndpoint.parseLanInput('192.168.1.8:3081');
      expect(r.host, '192.168.1.8:3081');
      expect(r.port, 3081);
      expect(r.token, '');
    });

    test('完整链接 + ?token= 一并取出，并从主机串里删掉 Token', () {
      final r = DshEndpoint.parseLanInput(
        'http://192.168.1.8:3080/?token=abc123XYZ',
      );
      expect(r.token, 'abc123XYZ');
      expect(r.host, 'http://192.168.1.8:3080');
      expect(r.host.contains('abc123XYZ'), isFalse);
      expect(r.port, 3080);
    });

    test('access_token / 片段形式都认', () {
      final a = DshEndpoint.parseLanInput('192.168.1.8:3080?access_token=tk1');
      expect(a.token, 'tk1');
      expect(a.host, '192.168.1.8:3080');
      final b = DshEndpoint.parseLanInput('192.168.1.8:3080#token=tk2');
      expect(b.token, 'tk2');
      expect(b.host, '192.168.1.8:3080');
    });

    test('带路径的链接保留路径', () {
      final r = DshEndpoint.parseLanInput('http://pc.local:3080/app/?token=tk');
      expect(r.host, 'http://pc.local:3080/app');
      expect(r.token, 'tk');
    });

    test('空串安全', () {
      final r = DshEndpoint.parseLanInput('   ');
      expect(r.host, '');
      expect(r.port, 3080);
      expect(r.token, '');
    });
  });

  group('lanLink', () {
    test('无 Token 就是 host:port', () {
      expect(
        DshEndpoint.lanLink(host: '192.168.1.8', port: 3080),
        'http://192.168.1.8:3080',
      );
    });

    test('带 Token 拼成一条可复制链接', () {
      expect(
        DshEndpoint.lanLink(
          host: '192.168.1.8',
          port: 3081,
          token: 'tk9',
        ),
        'http://192.168.1.8:3081?token=tk9',
      );
    });

    test('合成 → 解析 往返一致（Token 不丢、不串进主机串）', () {
      final link = DshEndpoint.lanLink(
        host: '192.168.1.8',
        port: 3080,
        token: 'roundTripToken',
      );
      final r = DshEndpoint.parseLanInput(link);
      expect(r.port, 3080);
      expect(r.token, 'roundTripToken');
      expect(r.host.contains('roundTripToken'), isFalse);
      expect(DshEndpoint.lanUrl(r.host, r.port), 'http://192.168.1.8:3080');
    });
  });
}
