import 'package:flutter_test/flutter_test.dart';

import 'package:shiyi_agent_app/services/dsh_service.dart';

/// 本机 DSH 启动等待的节流：冷启动前 20 秒 500ms，之后 2 秒。
/// 真机复盘：局域网切走后旧等待仍 2Hz 打 session.list，白烧 CPU/网络。
/// 见 docs/fix-log.md #391。
void main() {
  test('前 20 秒用 500ms，之后退到 2 秒', () {
    expect(dshStartPollDelay(Duration.zero), const Duration(milliseconds: 500));
    expect(
      dshStartPollDelay(const Duration(seconds: 19)),
      const Duration(milliseconds: 500),
    );
    expect(dshStartPollDelay(const Duration(seconds: 20)), const Duration(seconds: 2));
    expect(
      dshStartPollDelay(const Duration(minutes: 4)),
      const Duration(seconds: 2),
    );
  });

  test('5 分钟等待窗口内的请求量：旧实现 600 次，新实现 ≤ 176 次', () {
    var elapsed = Duration.zero;
    var oldTicks = 0;
    var newTicks = 0;
    const limit = Duration(minutes: 5);
    while (elapsed < limit) {
      elapsed += const Duration(milliseconds: 500);
      oldTicks++;
    }
    elapsed = Duration.zero;
    while (elapsed < limit) {
      elapsed += dshStartPollDelay(elapsed);
      newTicks++;
    }
    expect(oldTicks, 600);
    expect(newTicks, lessThan(200));
  });
}
