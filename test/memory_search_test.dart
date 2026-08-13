import 'package:flutter_test/flutter_test.dart';

import 'package:shiyi_agent_app/core/app_state.dart';

void main() {
  group('ShiyiState.memorySearchType', () {
    test('缺省返回 null，表示搜全部类型', () {
      expect(ShiyiState.memorySearchType(null), isNull);
      expect(ShiyiState.memorySearchType(''), isNull);
    });

    test('合法类型原样返回并归一化大小写', () {
      expect(ShiyiState.memorySearchType('project'), 'project');
      expect(ShiyiState.memorySearchType('  USER '), 'user');
    });

    test('无效类型返回 null，避免只搜 user 漏掉其他记忆', () {
      expect(ShiyiState.memorySearchType('foo'), isNull);
    });
  });
}
