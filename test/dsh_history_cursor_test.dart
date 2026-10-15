import 'package:flutter_test/flutter_test.dart';

import 'package:shiyi_agent_app/services/dsh_api.dart';

/// rc.2 的 `throughSeq` 是**包含式上界**：官方客户端的尾部游标来自
/// `session/follow` 首帧 snapshot，下行流拿不到帧时用越界探测学一次
/// （服务端会回 `... is past cursor N`）。见 docs/fix-log.md #389。
void main() {
  test('从越界报错里取出当前游标', () {
    expect(
      DshApiClient.parsePastCursor(
        'session page through seq 1099511627776 is past cursor 4374 '
        '(code: gateway/bad-request)',
      ),
      4374,
    );
    expect(
      DshApiClient.parsePastCursor(
        'DeepSeek Harness HTTP 400 (code: gateway/bad-request)\n'
        'session page through seq 5 is past cursor 0',
      ),
      0,
    );
  });

  test('没有游标信息时返回 null（不瞎猜）', () {
    expect(DshApiClient.parsePastCursor('HTTP 404'), isNull);
    expect(DshApiClient.parsePastCursor('gateway/bad-request'), isNull);
    expect(DshApiClient.parsePastCursor('past cursor maybe'), isNull);
  });
}
