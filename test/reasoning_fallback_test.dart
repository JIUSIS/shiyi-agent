import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/models.dart';
import 'package:shiyi_agent_app/services/llm_client.dart';

void main() {
  test('content 为空时把 reasoning 当正文读取', () {
    final msg = ChatMessage.fromMap({
      'id': 'm1',
      'session_id': 's1',
      'role': 'assistant',
      'content': '',
      'reasoning': '选了「骂一句」——完全理解！',
      'tool_calls': '',
      'tool_call_id': '',
      'created_at': 1,
    });
    expect(msg.content, '选了「骂一句」——完全理解！');
    expect(msg.reasoning, isEmpty);
  });

  test('有工具调用时 reasoning 仍保留为思考内容', () {
    final msg = ChatMessage.fromMap({
      'id': 'm2',
      'session_id': 's1',
      'role': 'assistant',
      'content': '',
      'reasoning': '需要先调用工具',
      'tool_calls': '[{"id":"c1","name":"run_terminal","arguments":"{}"}]',
      'tool_call_id': '',
      'created_at': 2,
    });
    expect(msg.content, isEmpty);
    expect(msg.reasoning, '需要先调用工具');
    expect(msg.hasToolCalls, isTrue);
  });

  test('reasoning 与正文重复时不再当作思考', () {
    final msg = ChatMessage.fromMap({
      'id': 'm3',
      'session_id': 's1',
      'role': 'assistant',
      'content': 'hello! 很高兴见到你~\n\n有什么我可以帮你的吗？😊',
      'reasoning': 'hello!很高兴见到你~有什么我可以帮你的吗？😊',
      'tool_calls': '',
      'tool_call_id': '',
      'created_at': 3,
    });
    expect(msg.content, 'hello! 很高兴见到你~\n\n有什么我可以帮你的吗？😊');
    expect(msg.reasoning, isEmpty);
  });

  test('发送 API 时 assistant 消息回传 reasoning_content', () {
    final msg = ChatMessage.fromMap({
      'id': 'm4',
      'session_id': 's1',
      'role': 'assistant',
      'content': '正文',
      'reasoning': '先分析再回答',
      'tool_calls': '',
      'tool_call_id': '',
      'created_at': 4,
    });
    final api = msg.toApiMap();
    expect(api['content'], '正文');
    expect(api['reasoning_content'], '先分析再回答');
  });

  test('带工具调用时同样回传 reasoning_content', () {
    final msg = ChatMessage.fromMap({
      'id': 'm5',
      'session_id': 's1',
      'role': 'assistant',
      'content': '',
      'reasoning': '需要调用工具',
      'tool_calls': '[{"id":"c1","name":"run_terminal","arguments":"{}"}]',
      'tool_call_id': '',
      'created_at': 5,
    });
    final api = msg.toApiMap();
    expect(api['reasoning_content'], '需要调用工具');
    expect(api['tool_calls'], isNotEmpty);
  });

  test('无思考内容时不添加 reasoning_content 字段', () {
    final msg = ChatMessage.fromMap({
      'id': 'm6',
      'session_id': 's1',
      'role': 'assistant',
      'content': '直接回答',
      'reasoning': '',
      'tool_calls': '',
      'tool_call_id': '',
      'created_at': 6,
    });
    expect(msg.toApiMap().containsKey('reasoning_content'), isFalse);
  });

  test('提取 reasoning_summary 对象与嵌套 summary 数组', () {
    expect(
      LlmClient.extractReasoningValue({
        'summary': [
          {'text': '先拆解问题'},
          {'text': '再决定方案'},
        ],
      }),
      '先拆解问题再决定方案',
    );
    expect(LlmClient.extractReasoningValue({'summary': '整体思考'}), '整体思考');
  });

  test('提取 Responses API 的 delta 与字符串片段', () {
    expect(
      LlmClient.extractReasoningValue({
        'delta': {'text': '逐步验证'},
      }),
      '逐步验证',
    );
    expect(LlmClient.extractReasoningValue('直接思考'), '直接思考');
  });

  test('reasoning 数组按顺序拼接', () {
    expect(
      LlmClient.extractReasoningValue([
        {
          'summary': [
            {'text': '第一步'},
          ],
        },
        '第二步',
      ]),
      '第一步第二步',
    );
  });

  test('空值/空字符串不返回思考', () {
    expect(LlmClient.extractReasoningValue(null), isNull);
    expect(LlmClient.extractReasoningValue('  '), isNull);
    expect(LlmClient.extractReasoningValue([]), isNull);
  });
}
