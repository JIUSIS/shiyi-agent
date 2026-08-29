
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/subagent_live.dart';

void main() {
  test('转写本跳过 system/tool，保留 assistant 工具调用', () {
    final msgs = subagentTranscriptToMessages('sid', [
      {'role': 'system', 'content': '你是探索子代理'},
      {'role': 'user', 'content': '找配置'},
      {
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {
            'id': 'call_1',
            'function': {'name': 'file_read', 'arguments': '{"path":"a"}'},
          },
        ],
      },
      {'role': 'tool', 'content': 'ok', 'tool_call_id': 'call_1'},
      {'role': 'assistant', 'content': '找到了 a.yaml'},
    ]);

    expect(msgs.length, 3);
    expect(msgs[0].role, 'user');
    expect(msgs[0].content, '找配置');
    expect(msgs[1].role, 'assistant');
    expect(msgs[1].toolCalls.single.name, 'file_read');
    expect(msgs[2].content, '找到了 a.yaml');
  });

  test('live run 状态行使用轮次和工具名', () {
    final run = SubagentLiveRun(
      id: '1',
      type: 'explore',
      prompt: '找配置',
      index: 1,
      total: 2,
      maxTurns: 15,
    );
    expect(run.statusLine, '第 1/15 轮 · 思考中');
    run.round = 3;
    run.lastTool = 'file_read';
    expect(run.toSnapshot().subtitle, '第 3/15 轮 · 正在调用 file_read');
    expect(run.toSnapshot().title, 'explore');
  });
}
