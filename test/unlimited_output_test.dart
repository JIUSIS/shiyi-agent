import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/models.dart';

/// 解除人为输出上限（docs/fix-log.md #412）：
/// 默认「不限制」，设置页可自行收紧 —— 0 一律表示不限，负数回落到默认。
void main() {
  test('默认设置 = 全部不限制', () {
    final s = AppSettings();
    expect(s.maxOutputTokens, 0, reason: '默认不发 max_tokens，用模型自身上限');
    expect(s.maxContinuationRounds, 0, reason: '默认一直续写到模型自然结束');
    expect(s.streamWaitSeconds, 0, reason: '默认不设等待上限');
    expect(s.maxToolRounds, 0, reason: '默认不限工具轮数');
  });

  test('0 = 不限制，负数回落默认，超限夹到上限', () {
    expect(sanitizeMaxOutputTokens(0), 0);
    expect(sanitizeMaxOutputTokens(-5), kDefaultMaxOutputTokens);
    expect(sanitizeMaxOutputTokens(1 << 30), kMaxOutputTokensLimit);

    expect(sanitizeStreamWaitSeconds(0), 0);
    expect(sanitizeStreamWaitSeconds(-1), kDefaultStreamWaitSeconds);
    expect(sanitizeStreamWaitSeconds(999999999), kMaxStreamWaitSeconds);

    expect(sanitizeContinuationRounds(0), 0);
    expect(sanitizeToolRounds(0), 0);
    expect(sanitizeToolRounds(-3), kDefaultToolRounds);
  });

  test('用户显式设置的值被保留（能自己收紧）', () {
    expect(sanitizeMaxOutputTokens(8192), 8192);
    expect(sanitizeStreamWaitSeconds(600), 600);
    expect(sanitizeContinuationRounds(16), 16);
    expect(sanitizeToolRounds(20), 20);
  });

  test('老配置读盘：0/缺失都变成不限制，显式值不动', () {
    final unlimited = AppSettings.fromJson(const <String, dynamic>{});
    expect(unlimited.maxOutputTokens, 0);
    expect(unlimited.maxContinuationRounds, 0);
    expect(unlimited.streamWaitSeconds, 0);
    expect(unlimited.maxToolRounds, 0);

    final tightened = AppSettings.fromJson(const <String, dynamic>{
      'maxOutputTokens': 4096,
      'maxContinuationRounds': 8,
      'streamWaitSeconds': 300,
      'maxToolRounds': 12,
    });
    expect(tightened.maxOutputTokens, 4096);
    expect(tightened.maxContinuationRounds, 8);
    expect(tightened.streamWaitSeconds, 300);
    expect(tightened.maxToolRounds, 12);
    // 存盘一轮后仍然一致
    final roundTrip = AppSettings.fromJson(tightened.toJson());
    expect(roundTrip.maxToolRounds, 12);
    expect(roundTrip.maxOutputTokens, 4096);
  });
}
