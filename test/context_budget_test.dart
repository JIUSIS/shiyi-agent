import 'package:flutter_test/flutter_test.dart';

import 'package:shiyi_agent_app/core/app_state.dart';

void main() {
  group('trimApiMessagesForBudget', () {
    List<Map<String, dynamic>> msgs() => [
      {'role': 'system', 'content': 'sys'},
      {'role': 'user', 'content': 'a' * 1000},
      {'role': 'assistant', 'content': 'b' * 1000},
      {'role': 'user', 'content': 'latest'},
    ];

    test('预算充足时保留全部消息', () {
      final out = ShiyiState.trimApiMessagesForBudget(msgs(), 100000);
      expect(out.length, 4);
      expect(out.first['content'], 'sys');
      expect(out.last['content'], 'latest');
    });

    test('预算不足时裁剪较早历史并保留最新', () {
      final out = ShiyiState.trimApiMessagesForBudget(msgs(), 200);
      expect(out.length, 2);
      expect(out.first['content'], contains('较早对话因上下文限制未包含'));
      expect(out.last['content'], 'latest');
    });

    test('非法预算原样返回', () {
      final m = msgs();
      expect(ShiyiState.trimApiMessagesForBudget(m, 0), same(m));
    });

    test('tool_calls 计入预算', () {
      final m = [
        {'role': 'system', 'content': 's'},
        {
          'role': 'assistant',
          'content': 'x' * 100,
          'tool_calls': [
            {
              'id': '1',
              'type': 'function',
              'function': {
                'name': 'f',
                'arguments': '{"a": "${'z' * 5000}"}',
              },
            },
          ],
        },
        {'role': 'user', 'content': 'latest'},
      ];
      final out = ShiyiState.trimApiMessagesForBudget(m, 300);
      expect(out.length, 2);
      expect(out.last['content'], 'latest');
    });
  });
}
