import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/app_state.dart';
import 'package:shiyi_agent_app/core/models.dart';
import 'package:shiyi_agent_app/services/llm_client.dart';

void main() {
  test('正文为空且只有 reasoning 时仍作为思考过程，不升成正文', () {
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
    expect(msg.content, isEmpty);
    expect(msg.reasoning, '选了「骂一句」——完全理解！');
  });

  test('拾忆 fromMap 不拆正文里的 think 标签', () {
    final msg = ChatMessage.fromMap({
      'id': 'm1b',
      'session_id': 's1',
      'role': 'assistant',
      'content': '<think>先分析问题</think>这是最终回答',
      'reasoning': '',
      'tool_calls': '',
      'tool_call_id': '',
      'created_at': 1,
    });
    expect(msg.content, '<think>先分析问题</think>这是最终回答');
    expect(msg.reasoning, isEmpty);
  });

  test('splitThinkTags 处理未闭合与半截标签', () {
    expect(splitThinkTags('hello').text, 'hello');
    expect(splitThinkTags('hello').reasoning, isEmpty);
    expect(splitThinkTags('<think>foo').text, isEmpty);
    expect(splitThinkTags('<think>foo').reasoning, 'foo');
    expect(splitThinkTags('pre<think>foo</think>post').text, 'prepost');
    expect(splitThinkTags('pre<think>foo</think>post').reasoning, 'foo');
    expect(splitThinkTags('hello <th').text, 'hello ');
    expect(splitThinkTags('<thinking>a</thinking>b').reasoning, 'a');
    expect(splitThinkTags('<thinking>a</thinking>b').text, 'b');
  });

  test('mergeReasoning 不重复追加已包含片段', () {
    expect(mergeReasoning('foo', 'foobar'), 'foobar');
    expect(mergeReasoning('foobar', 'bar'), 'foobar');
    expect(mergeReasoning('foo', 'bar'), 'foobar');
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

  test('reasoning 空且正文带 think 标签时拆进思考面板', () {
    final n1 = ShiyiState.normalizeMisplacedReasoningForTest(
      TurnResult(text: '<thinking>先分析问题</thinking>这是最终回答', reasoning: ''),
    );
    expect(n1.text, '这是最终回答');
    expect(n1.reasoning, '先分析问题');
  });

  test('think 标签未闭合时整段按思考处理', () {
    final n = ShiyiState.normalizeMisplacedReasoningForTest(
      TurnResult(text: '<thinking>只有思考没有正文', reasoning: ''),
    );
    expect(n.text, isEmpty);
    expect(n.reasoning, '只有思考没有正文');
  });

  test('正文无 think 标签时不误拆', () {
    const raw = '你好呀！有什么我能帮你的吗？😊';
    final n = ShiyiState.normalizeMisplacedReasoningForTest(
      TurnResult(text: raw, reasoning: ''),
    );
    expect(n.text, raw);
    expect(n.reasoning, isEmpty);
  });

  test('reasoning 非空时优先字段流，不拆正文标签', () {
    final n = ShiyiState.normalizeMisplacedReasoningForTest(
      TurnResult(text: '<thinking>正文里的标签</thinking>', reasoning: '字段流思考'),
    );
    expect(n.text, '<thinking>正文里的标签</thinking>');
    expect(n.reasoning, '字段流思考');
  });

  test('有工具调用时不拆 think 标签', () {
    final n = ShiyiState.normalizeMisplacedReasoningForTest(
      TurnResult(
        text: '<thinking>先想</thinking>调用工具',
        reasoning: '',
        toolCalls: [
          {'id': 'c1', 'name': 'run_terminal', 'arguments': '{}'},
        ],
      ),
    );
    expect(n.text, '<thinking>先想</thinking>调用工具');
    expect(n.reasoning, isEmpty);
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
