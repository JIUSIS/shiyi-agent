import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/models.dart';

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
}
