import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:shiyi_agent_app/core/app_state.dart';
import 'package:shiyi_agent_app/core/models.dart';

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
      expect(out.length, 3);
      expect(out.first['content'], 'sys');
      expect(out[1]['role'], 'user');
      expect(out[1]['content'], contains('较早对话因上下文限制未包含'));
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
      expect(out.first['content'], 's');
      expect(out.last['content'], 'latest');
      expect(out.any((e) => (e['content'] ?? '').toString().contains('较早对话')), isTrue);
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
      expect(out.first['role'], 'system');
      expect(out.first['content'], 'sys');
      expect(out.map((e) => e['role']).toList(), [
        'system',
        'user',
        'assistant',
        'tool',
        'user',
      ]);
      expect(out[2]['tool_calls'], isNotEmpty);
      expect(out[3]['tool_call_id'], 'c1');
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
      expect(out.first['content'], 'sys');
      expect(out.map((e) => e['role']).toList(), ['system', 'user', 'user']);
      expect(out[1]['content'], contains('较早对话因上下文限制未包含'));
    });

    test('工具定义占用预算，裁剪后总请求 Token 不超过总预算', () {
      final m = [
        {'role': 'system', 'content': '系统提示'},
        {'role': 'user', 'content': '旧' * 90000},
        {'role': 'user', 'content': '最新问题'},
      ];
      final bigTool = [
        {
          'type': 'function',
          'function': {'name': 'big_tool', 'description': 'x' * 120000},
        },
      ];
      const budget = 117248;
      final out = ShiyiState.trimApiMessagesForBudget(
        m,
        budget,
        tools: bigTool,
      );
      final total = ShiyiState.estimateRequestTokens(
        out,
        tools: bigTool,
      ).totalEstimatedTokens;
      expect(total, lessThanOrEqualTo(budget));
      expect(out.last['content'], '最新问题');
      expect(out.first['content'], '系统提示');
    });

    test('动尾 system 不改字节，裁剪说明插在冻头之后', () {
      final m = [
        {'role': 'system', 'content': 'frozen-prefix'},
        {'role': 'user', 'content': 'old' * 2000},
        {'role': 'assistant', 'content': 'old-ans' * 200},
        {'role': 'user', 'content': 'latest'},
        {'role': 'system', 'content': 'tail-time'},
      ];
      final out = ShiyiState.trimApiMessagesForBudget(m, 250);
      expect(out.first['content'], 'frozen-prefix');
      expect(out.last['content'], 'tail-time');
      expect(out[1]['content'], contains('较早对话因上下文限制未包含'));
      expect(out[out.length - 2]['content'], 'latest');
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

  group('compressionKeepStart', () {
    var seq = 0;
    ChatMessage msg(
      String role, {
      String content = '',
      List<ToolCall>? toolCalls,
      String toolCallId = '',
    }) => ChatMessage(
      id: 'm${DateTime.now().microsecondsSinceEpoch}_${seq++}',
      sessionId: 's1',
      role: role,
      content: content,
      toolCalls: toolCalls,
      toolCallId: toolCallId,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );

    test('大上下文时至少归档早期 60% 条数', () {
      final msgs = [
        for (var i = 0; i < 10; i++) msg('user', content: '第$i条消息'),
      ];
      final start = ShiyiState.compressionKeepStart(msgs, contextLimit: 128000);
      expect(start, 6);
    });

    test('小预算按 Token 归档更多旧消息', () {
      final msgs = [
        for (var i = 0; i < 10; i++) msg('user', content: '中文内容' * 200),
      ];
      final start = ShiyiState.compressionKeepStart(msgs, contextLimit: 1200);
      expect(start, greaterThan(6));
    });

    test('边界不拆散 assistant tool_calls 与 tool 结果', () {
      final msgs = [
        msg('user', content: '开始任务'),
        msg(
          'assistant',
          content: '我来读取',
          toolCalls: [
            ToolCall(
              id: 'c1',
              name: 'file_read',
              arguments: '{"path":"/tmp/a.txt"}',
            ),
          ],
        ),
        msg('tool', content: '文件内容' * 500, toolCallId: 'c1'),
        msg('user', content: '继续' * 500),
        msg('user', content: '最新问题'),
      ];
      final start = ShiyiState.compressionKeepStart(msgs, contextLimit: 600);
      expect(
        start == 3 || start >= 5,
        isTrue,
        reason: '工具回合要么整组保留，要么整组归档，不能停在 tool_calls 和 tool 结果中间',
      );
    });

    test('minKeepStart 落在工具轮中间时对齐到单元起点（历史孤儿 tool 消息场景）', () {
      final msgs = [
        msg('user', content: '开始'),
        msg(
          'assistant',
          content: '',
          toolCalls: [ToolCall(id: 'c1', name: 'file_read', arguments: '{}')],
        ),
        msg('tool', content: '结果1', toolCallId: 'c1'),
        msg(
          'assistant',
          content: '',
          toolCalls: [ToolCall(id: 'c2', name: 'file_read', arguments: '{}')],
        ),
        msg('tool', content: '结果2', toolCallId: 'c2'),
        msg('user', content: '继续'),
        msg('user', content: '最新'),
      ];
      // n=7，minKeepStart=4 恰好落在 tool2（index 4）上：必须对齐回 index 3。
      final start = ShiyiState.compressionKeepStart(msgs, contextLimit: 0);
      expect(start, 3);
      expect(msgs[start].role, 'assistant');
    });

    test('对齐后保留侧第一条不能是孤儿 tool 消息（token 预算分支同样生效）', () {
      final msgs = [
        msg('user', content: '开始'),
        msg(
          'assistant',
          content: '',
          toolCalls: [ToolCall(id: 'c1', name: 'file_read', arguments: '{}')],
        ),
        msg('tool', content: '结果' * 300, toolCallId: 'c1'),
        msg('user', content: '最新'),
      ];
      final start = ShiyiState.compressionKeepStart(msgs, contextLimit: 300);
      expect(start, 1, reason: '工具单元必须整组保留（asst1+tool1）');
      expect(msgs[start].role, 'assistant');
    });
  });

  group('compactOldTools 原地截断', () {
    var seq = 0;
    ChatMessage asst(String callId, String content) => ChatMessage(
      id: 'a${seq++}',
      sessionId: 's1',
      role: 'assistant',
      content: content,
      toolCalls: [ToolCall(id: callId, name: 'run_terminal', arguments: '{}')],
      createdAt: seq,
    );
    ChatMessage tool(String callId, String output) => ChatMessage(
      id: 't$seq${seq++}',
      sessionId: 's1',
      role: 'tool',
      content: output,
      toolCallId: callId,
      createdAt: seq,
    );

    test('超过 3 个完整工具轮时保留全部成对，只截断较早输出', () {
      final long = 'x' * 4000;
      final msgs = <ChatMessage>[
        ChatMessage(
          id: 'u0',
          sessionId: 's1',
          role: 'user',
          content: '开始',
          createdAt: 0,
        ),
        for (var i = 1; i <= 5; i++) ...[
          asst('c$i', 'ok$i'),
          tool('c$i', long),
        ],
      ];
      final out = ShiyiState.historyToApiForTest(
        msgs,
        compactOldTools: true,
      );
      final tools = out.where((m) => m['role'] == 'tool').toList();
      expect(tools.length, 5);
      expect(out.where((m) => m['role'] == 'assistant').length, 5);
      expect((tools[0]['content'] as String).length, lessThan(long.length));
      expect((tools[0]['content'] as String), contains('已裁剪中间内容'));
      expect(tools[4]['content'], long);
    });

    test('压缩请求冻头不变，压缩指令在动尾，不是摘要助手', () {
      final msgs = ShiyiState.buildCompactRequestMessages(
        frozen: 'FROZEN_PREFIX',
        history: [
          {'role': 'user', 'content': 'hello'},
          {'role': 'assistant', 'content': 'hi'},
        ],
      );
      expect(msgs.first['role'], 'system');
      expect(msgs.first['content'], 'FROZEN_PREFIX');
      expect(msgs.last['role'], 'system');
      expect(msgs.last['content'], ShiyiState.compactInstruction);
      expect(jsonEncode(msgs), isNot(contains('对话摘要助手')));
    });
  });

  group('主请求冻头/归档/动尾', () {
    test('滚动任务摘要进动尾，不插在历史前面', () {
      final msgs = ShiyiState.buildMainRequestMessages(
        frozen: 'FROZEN_PREFIX',
        history: [
          {'role': 'user', 'content': 'hello'},
          {'role': 'assistant', 'content': 'hi'},
        ],
        tail: 'TAIL_TIME',
        rollingSummary: '早先做了登录',
        contextSummaries: '【滚动任务摘要】\n目标：改缓存',
      );
      expect(msgs.first['content'], 'FROZEN_PREFIX');
      expect(msgs[1]['role'], 'user');
      expect(msgs[1]['content'], contains('【历史任务摘要】'));
      expect(msgs[1]['content'], contains('早先做了登录'));
      expect(msgs[1]['content'], isNot(contains('【滚动任务摘要】')));
      expect(msgs[2]['role'], 'assistant');
      expect(msgs[3]['content'], 'hello');
      expect(msgs[4]['content'], 'hi');
      expect(msgs.last['role'], 'system');
      expect(msgs.last['content'], contains('TAIL_TIME'));
      expect(msgs.last['content'], contains('【滚动任务摘要】'));
      expect(msgs.last['content'], contains('目标：改缓存'));
    });

    test('没有压缩归档时历史紧跟冻头', () {
      final msgs = ShiyiState.buildMainRequestMessages(
        frozen: 'FROZEN_PREFIX',
        history: [
          {'role': 'user', 'content': 'hello'},
        ],
        tail: 'TAIL_TIME',
      );
      expect(msgs.map((m) => m['role']).toList(), ['system', 'user', 'system']);
      expect(msgs[1]['content'], 'hello');
    });
  });

  group('内嵌终端探活', () {
    test('已经探活成功就不再跑 true 自检', () {
      expect(
        ShiyiState.shouldProbeEmbeddedTerminal(alreadyReady: true),
        isFalse,
      );
      expect(
        ShiyiState.shouldProbeEmbeddedTerminal(alreadyReady: false),
        isTrue,
      );
    });
  });

  group('tools 表缓存前缀', () {
    test('顺序固定，计划模式与普通模式 JSON 完全相同', () {
      final names = ShiyiState.toolRegistry.map((t) => t.name).toList();
      expect(names, [
        'save_memory',
        'search_sessions',
        'read_session',
        'inspect_runtime',
        'search_memory',
        'run_skill',
        'web_search',
        'web_extract',
        'run_terminal',
        'file_write',
        'file_read',
        'question',
        'create_skill',
        'enter_plan_mode',
        'exit_plan_mode',
        'spawn_agent',
      ]);
      expect(
        jsonEncode(ShiyiState.toolsJsonForRequest(planMode: true)),
        jsonEncode(ShiyiState.toolsJsonForRequest(planMode: false)),
      );
    });
  });
}
