import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:shiyi_agent_app/core/models.dart';

/// `dshConnectionMode` 缺失（设置丢失 / 尚未落盘）时，
/// `AppSettings.dshConnectionModeConfigured` 必须为 false —— 冷启动不得据此
/// 自动拉起手机里的 Alpine DSH。见 docs/fix-log.md #391。
void main() {
  test('缺省构造不算「用户选过本机」', () {
    expect(AppSettings().dshConnectionMode, 'local');
    expect(AppSettings().dshConnectionModeConfigured, isFalse);
  });

  test('落盘过的设置才算配置过（三种模式都认）', () {
    for (final mode in ['local', 'lan', 'remote']) {
      final s = AppSettings.fromJson({'dshConnectionMode': mode});
      expect(s.dshConnectionMode, mode, reason: mode);
      expect(s.dshConnectionModeConfigured, isTrue, reason: mode);
    }
  });

  test('旧设置缺这个键（含空 JSON）视为未配置', () {
    expect(AppSettings.fromJson(const {}).dshConnectionModeConfigured, isFalse);
    expect(
      AppSettings.fromJson({'agentEngine': 'dsh'}).dshConnectionModeConfigured,
      isFalse,
    );
  });

  test('copyWith 保留该标记', () {
    final s = AppSettings.fromJson(const {'dshConnectionMode': 'lan'});
    expect(s.copyWith(dshLanHost: '192.168.77.15').dshConnectionModeConfigured, isTrue);
    expect(
      s.copyWith(dshConnectionModeConfigured: false).dshConnectionModeConfigured,
      isFalse,
    );
  });

  test('JSON round-trip 后仍然算已配置', () {
    final s = AppSettings.fromJson(const {'dshConnectionMode': 'lan'});
    final back = AppSettings.fromJson(
      jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>,
    );
    expect(back.dshConnectionMode, 'lan');
    expect(back.dshConnectionModeConfigured, isTrue);
  });
}
