import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:shiyi_agent_app/core/app_state.dart';

import 'snapshot_helper.dart';

/// 工具目录快照：守护模型可见的工具 schema。
/// 改工具名 / 描述 / 参数 / 只读标记都会触发 diff——这些改动会影响
/// 模型的行为、请求 token 数和缓存前缀，必须显式确认。
void main() {
  test('工具目录快照：数量/描述/参数/只读标记', () {
    final tools = ShiyiState.buildToolRegistryForTest();
    final json = <String, dynamic>{
      for (final t in tools)
        t.name: {
          'readOnly': t.readOnly,
          'description': t.description,
          'parameters': t.parameters,
        },
    };
    final text = '${const JsonEncoder.withIndent('  ').convert(json)}\n';
    expectSnapshot(text, 'test/snapshots/tools.json');
  });
}
