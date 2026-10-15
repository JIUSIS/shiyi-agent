import 'package:flutter_test/flutter_test.dart';

import 'package:shiyi_agent_app/services/dsh_api.dart';

/// 会话 Cookie 落盘键：必须按连接 scope 隔离。
/// 真机实测（docs/fix-log.md #395）：Cookie 只在内存里，应用一重启就丢；
/// 启动 Token 又会随 activation 轮换，重换失败 → 局域网 401 再也连不上。
void main() {
  test('不同连接 scope 用不同落盘键（Cookie 不会串主机）', () {
    final a = DshApiClient.authCookieStorageKey(
      'lan\u0000http://192.168.0.103:8080',
    );
    final b = DshApiClient.authCookieStorageKey(
      'lan\u0000http://192.168.0.104:8080',
    );
    final c = DshApiClient.authCookieStorageKey(
      'local\u0000http://127.0.0.1:3080',
    );
    expect(a, isNot(b));
    expect(a, isNot(c));
    expect(b, isNot(c));
  });

  test('同一个 scope 稳定（重启后能读回同一条）', () {
    const scope = 'lan\u0000http://192.168.0.103:8080';
    expect(
      DshApiClient.authCookieStorageKey(scope),
      DshApiClient.authCookieStorageKey(scope),
    );
    expect(DshApiClient.authCookieStorageKey(scope), contains(scope));
  });

  test('Set-Cookie 解析只认 dsh-auth-*', () {
    expect(
      DshApiClient.parseDshAuthCookie(
        'dsh-auth-abc123=payload.sig; Path=/; HttpOnly; Max-Age=2592000',
      ),
      'dsh-auth-abc123=payload.sig',
    );
    expect(DshApiClient.parseDshAuthCookie('other=x; Path=/'), isNull);
    expect(DshApiClient.parseDshAuthCookie(''), isNull);
  });
}
