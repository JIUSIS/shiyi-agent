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
              'function': {'name': 'f', 'arguments': '{"a": "${'z' * 5000}"}'},
            },
          ],
        },
        {'role': 'user', 'content': 'latest'},
      ];
      final out = ShiyiState.trimApiMessagesForBudget(m, 300);
      expect(out.length, 2);
      expect(out.last['content'], 'latest');
    });

    test('裁剪时保留完整工具轮，不拆散 tool_calls 与 tool 结果', () {
      final m = [
        {'role': 'system', 'content': 'sys'},
        {'role': 'user', 'content': 'old' * 1000},
        {
          'role': 'assistant',
          'content': 'ok',
          'tool_calls': [
            {
              'id': 'c1',
              'type': 'function',
              'function': {
                'name': 'run_terminal',
                'arguments': '{"command":"ls"}',
              },
            },
          ],
        },
        {'role': 'tool', 'content': 'done', 'tool_call_id': 'c1'},
        {'role': 'user', 'content': 'latest'},
      ];
      final out = ShiyiState.trimApiMessagesForBudget(m, 300);
      expect(out.map((e) => e['role']).toList(), [
        'system',
        'assistant',
        'tool',
        'user',
      ]);
      expect(out[1]['tool_calls'], isNotEmpty);
      expect(out[2]['tool_call_id'], 'c1');
    });

    test('预算不足时整组裁掉工具轮，不留下孤儿 tool 结果', () {
      final m = [
        {'role': 'system', 'content': 'sys'},
        {
          'role': 'assistant',
          'content': 'ok',
          'tool_calls': [
            {
              'id': 'c1',
              'type': 'function',
              'function': {
                'name': 'run_terminal',
                'arguments': '{"command":"${'z' * 2000}"}',
              },
            },
          ],
        },
        {'role': 'tool', 'content': 'r' * 2000, 'tool_call_id': 'c1'},
        {'role': 'user', 'content': 'latest'},
      ];
      final out = ShiyiState.trimApiMessagesForBudget(m, 300);
      expect(out.map((e) => e['role']).toList(), ['system', 'user']);
    });
  });

  group('estimateApiMessageTokens', () {
    test('中文按 1 token/字、其他按 4 字符/token 估算', () {
      final m = {'role': 'user', 'content': '你好世界abcd'};
      expect(ShiyiState.estimateApiMessageTokens(m), 5);
    });

    test('tool_calls 计入估算', () {
      final m = {
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {
            'id': '1',
            'type': 'function',
            'function': {
              'name': 'file_read',
              'arguments': '{"path":"/tmp/a.txt"}',
            },
          },
        ],
      };
      final withTc = ShiyiState.estimateApiMessageTokens(m);
      final without = ShiyiState.estimateApiMessageTokens({
        'role': 'assistant',
        'content': '',
      });
      expect(withTc, greaterThan(without));
    });

    test('多模态 content 列表按 400 估算', () {
      final m = {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'hi'},
          {
            'type': 'image_url',
            'image_url': {'url': 'data:image/...'},
          },
        ],
      };
      expect(ShiyiState.estimateApiMessageTokens(m), 400);
    });
  });
}
