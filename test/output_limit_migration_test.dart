import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/models.dart';

/// 老配置的输出上限迁移（docs/fix-log.md #415）：
/// 真机上持久化的还是旧默认 `maxOutputTokens: 8192 / streamWaitSeconds: 600 /
/// maxContinuationRounds: 16`，那是旧版本硬塞的默认值 —— 不改的话「默认不限制」
/// 只对新安装生效，老用户照样被 8k 掐断。
void main() {
  /// 复刻 SettingsService.load() 里的迁移判定（纯逻辑，不碰 prefs）。
  Map<String, dynamic> migrate(Map<String, dynamic> raw) {
    final s = AppSettings.fromJson(raw);
    if (raw['outputLimitsV2'] != true) {
      if (s.maxOutputTokens == 8192) s.maxOutputTokens = 0;
      if (s.streamWaitSeconds == 600) s.streamWaitSeconds = 0;
      if (s.maxContinuationRounds == 16) s.maxContinuationRounds = 0;
      raw['maxOutputTokens'] = s.maxOutputTokens;
      raw['streamWaitSeconds'] = s.streamWaitSeconds;
      raw['maxContinuationRounds'] = s.maxContinuationRounds;
      raw['outputLimitsV2'] = true;
    }
    return raw;
  }

  test('真机老配置（8192/600/16）迁移成不限制', () {
    final raw = <String, dynamic>{
      'baseUrl': 'https://token-plan-cn.xiaomimimo.com/v1',
      'model': 'mimo-v2.6-flash',
      'maxOutputTokens': 8192,
      'streamWaitSeconds': 600,
      'maxContinuationRounds': 16,
    };
    final out = migrate(raw);
    expect(out['maxOutputTokens'], 0);
    expect(out['streamWaitSeconds'], 0);
    expect(out['maxContinuationRounds'], 0);
    expect(out['outputLimitsV2'], true);
    // 迁移后的配置再读一遍仍然是不限制
    final s = AppSettings.fromJson(out);
    expect(s.maxOutputTokens, 0);
    expect(s.streamWaitSeconds, 0);
    expect(s.maxContinuationRounds, 0);
  });

  test('用户显式改过的值不被迁移吃掉', () {
    final raw = <String, dynamic>{
      'maxOutputTokens': 32000,
      'streamWaitSeconds': 900,
      'maxContinuationRounds': 5,
    };
    final out = migrate(raw);
    expect(out['maxOutputTokens'], 32000);
    expect(out['streamWaitSeconds'], 900);
    expect(out['maxContinuationRounds'], 5);
  });

  test('已迁移过的配置再启动不重复迁移（用户后来手填 8192 要保留）', () {
    final raw = <String, dynamic>{
      'maxOutputTokens': 8192,
      'streamWaitSeconds': 600,
      'maxContinuationRounds': 16,
      'outputLimitsV2': true,
    };
    final out = migrate(raw);
    expect(out['maxOutputTokens'], 8192, reason: 'V2 标记已存在 → 是用户自己设的');
    expect(out['streamWaitSeconds'], 600);
    expect(out['maxContinuationRounds'], 16);
  });

  test('AppSettings.toJson 会带上 V2 标记，保存后不会退化成重复迁移', () {
    final json = AppSettings().toJson();
    expect(json['outputLimitsV2'], true);
    expect(json['maxOutputTokens'], 0);
    // 序列化—反序列化一轮后标记仍在
    final again = jsonDecode(jsonEncode(json)) as Map<String, dynamic>;
    expect(again['outputLimitsV2'], true);
    expect(migrate(again)['maxOutputTokens'], 0);
  });
}
