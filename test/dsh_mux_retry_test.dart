import 'package:flutter_test/flutter_test.dart';

import 'package:shiyi_agent_app/screens/dsh_chat_screen.dart';

/// mux 重连退避：局域网 8080 转发层不做 WebSocket 隧道（升级后静默），
/// 每 2 秒无限重连就是持续烧手机。见 docs/fix-log.md #391。
void main() {
  test('退避曲线：2s → 5s → 15s → 60s 封顶', () {
    expect(dshMuxRetryDelay(1), const Duration(seconds: 2));
    expect(dshMuxRetryDelay(2), const Duration(seconds: 5));
    expect(dshMuxRetryDelay(3), const Duration(seconds: 15));
    expect(dshMuxRetryDelay(4), const Duration(seconds: 60));
    expect(dshMuxRetryDelay(99), const Duration(seconds: 60));
  });

  test('10 分钟内重连次数：固定 2 秒是 300 次，退避后 < 20 次', () {
    var flat = 0;
    var elapsed = Duration.zero;
    while (elapsed < const Duration(minutes: 10)) {
      elapsed += const Duration(seconds: 2);
      flat++;
    }
    var backed = 0;
    var failures = 0;
    elapsed = Duration.zero;
    while (elapsed < const Duration(minutes: 10)) {
      failures++;
      elapsed += dshMuxRetryDelay(failures);
      backed++;
    }
    expect(flat, 300);
    expect(backed, lessThan(20));
  });
}
