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

    test('多模态 content 列表按文本 token + 每张图片 1000 token 估算', () {
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
      expect(ShiyiState.estimateApiMessageTokens(m), 1001);
    });
  });

  group('planContextBudget', () {
    test('128K 配置下约 33K Token 不触发裁剪', () {
      final plan = ShiyiState.planContextBudget(
        contextLimit: 128000,
        maxOutputTokens: 8192,
        estimatedInputTokens: 33000,
      );
      expect(plan.safetyReserve, 2560);
      expect(plan.outputReserve, 8192);
      expect(plan.usableInputTokens, 117248);
      expect(plan.shouldTrim, isFalse);
    });

    test('约 100K Token 不因 /4 误判而裁剪', () {
      final plan = ShiyiState.planContextBudget(
        contextLimit: 128000,
        maxOutputTokens: 8192,
        estimatedInputTokens: 100000,
      );
      expect(plan.shouldTrim, isFalse);
    });

    test('总输入未超过 usableInputTokens 时不裁剪', () {
      final plan = ShiyiState.planContextBudget(
        contextLimit: 128000,
        maxOutputTokens: 8192,
        estimatedInputTokens: 117248,
      );
      expect(plan.shouldTrim, isFalse);
    });

    test('总输入超过 usableInputTokens 时裁剪到合法预算', () {
      final plan = ShiyiState.planContextBudget(
        contextLimit: 128000,
        maxOutputTokens: 8192,
        estimatedInputTokens: 120000,
      );
      expect(plan.shouldTrim, isTrue);
      final msgs = [
        {'role': 'system', 'content': '系统提示'},
        {'role': 'user', 'content': '旧' * 150000},
        {'role': 'user', 'content': '最新问题'},
      ];
      final out = ShiyiState.trimApiMessagesForBudget(
        msgs,
        plan.usableInputTokens,
      );
      final trimmed = ShiyiState.estimateRequestTokens(
        out,
        tools: const [],
      ).totalEstimatedTokens;
      expect(trimmed, lessThanOrEqualTo(plan.usableInputTokens));
      expect(out.last['content'], '最新问题');
    });

    test('autoCompress=false 时 80% 不触发自动摘要', () {
      expect(
        ShiyiState.shouldAutoCompress(
          autoCompress: false,
          tokens: 102400,
          contextLimit: 128000,
          thresholdPercent: 80,
        ),
        isFalse,
      );
      expect(
        ShiyiState.shouldAutoCompress(
          autoCompress: true,
          tokens: 102401,
          contextLimit: 128000,
          thresholdPercent: 80,
        ),
        isTrue,
      );
    });
  });

  group('estimateRequestTokens', () {
    test('system/工具定义/历史/当前输入统一 Token 估算', () {
      final msgs = [
        {'role': 'system', 'content': '你好' * 100},
        {'role': 'user', 'content': '旧消息' * 100},
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
        {'role': 'tool', 'content': '结果' * 100, 'tool_call_id': 'c1'},
        {'role': 'user', 'content': '新的问题'},
      ];
      final e = ShiyiState.estimateRequestTokens(
        msgs,
        tools: [
          {
            'type': 'function',
            'function': {'name': 'run_terminal', 'description': '运行终端'},
          },
        ],
      );
      expect(e.systemTokens, greaterThan(0));
      expect(e.toolDefinitionTokens, greaterThan(0));
      expect(e.historyTokens, greaterThan(0));
      expect(e.currentInputTokens, greaterThan(0));
      expect(e.imageTokens, 0);
      expect(
        e.totalEstimatedTokens,
        e.systemTokens +
            e.toolDefinitionTokens +
            e.historyTokens +
            e.currentInputTokens +
            e.imageTokens,
      );
    });

    test('多轮工具消息全部计入，不只取最后一次请求', () {
      final single = [
        {'role': 'system', 'content': 'sys'},
        {'role': 'user', 'content': '开始'},
        {
          'role': 'assistant',
          'content': 'r1',
          'tool_calls': [
            {
              'id': 'c1',
              'type': 'function',
              'function': {
                'name': 'file_read',
                'arguments': '{"path":"/tmp/a.txt"}',
              },
            },
          ],
        },
        {'role': 'tool', 'content': 'a' * 2000, 'tool_call_id': 'c1'},
        {'role': 'user', 'content': '继续'},
      ];
      final multi = [
        ...single,
        {
          'role': 'assistant',
          'content': 'r2',
          'tool_calls': [
            {
              'id': 'c2',
              'type': 'function',
              'function': {
                'name': 'run_terminal',
                'arguments': '{"command":"grep x"}',
              },
            },
          ],
        },
        {'role': 'tool', 'content': 'b' * 2000, 'tool_call_id': 'c2'},
        {'role': 'user', 'content': '最后问题'},
      ];
      final one = ShiyiState.estimateRequestTokens(single, tools: const []);
      final all = ShiyiState.estimateRequestTokens(multi, tools: const []);
      expect(all.totalEstimatedTokens, greaterThan(one.totalEstimatedTokens));
      expect(all.historyTokens, greaterThan(one.historyTokens));
    });

    test('图片消息按每张 1000 Token 计入 imageTokens', () {
      final msgs = [
        {'role': 'system', 'content': 'sys'},
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': '看图'},
            {
              'type': 'image_url',
              'image_url': {'url': 'file://a.png'},
            },
            {
              'type': 'image_url',
              'image_url': {'url': 'file://b.png'},
            },
          ],
        },
      ];
      final e = ShiyiState.estimateRequestTokens(msgs, tools: const []);
      expect(e.imageTokens, 2000);
      expect(e.currentInputTokens, 2);
    });
  });
}
