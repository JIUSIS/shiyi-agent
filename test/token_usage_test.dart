import 'package:flutter_test/flutter_test.dart';

import 'package:shiyi_agent_app/core/app_state.dart';
import 'package:shiyi_agent_app/core/models.dart';
import 'package:shiyi_agent_app/services/llm_client.dart';

void main() {
  group('LlmClient.applyUsage', () {
    LlmClient client() => LlmClient(
      baseUrl: 'https://example.com/v1',
      apiKey: 'k',
      model: 'm',
      temperature: 0.7,
      tools: const [],
    );

    test('兼容 Chat Completions usage 字段', () {
      final c = client();
      c.applyUsage({
        'prompt_tokens': 100,
        'completion_tokens': 20,
        'total_tokens': 120,
        'prompt_tokens_details': {'cached_tokens': 60},
      });
      expect(c.lastTotalTokens, 120);
      expect(c.lastPromptTokens, 100);
      expect(c.lastInputTokens, 100);
      expect(c.lastOutputTokens, 20);
      expect(c.lastCachedTokens, 60);
    });

    test('兼容 Responses API usage 字段', () {
      final c = client();
      c.applyUsage({
        'input_tokens': 300,
        'output_tokens': 30,
        'total_tokens': 330,
        'input_tokens_details': {'cached_tokens': 150},
      });
      expect(c.lastTotalTokens, 330);
      expect(c.lastPromptTokens, 300);
      expect(c.lastInputTokens, 300);
      expect(c.lastOutputTokens, 30);
      expect(c.lastCachedTokens, 150);
    });

    test('input+output 可以推导 total_tokens', () {
      final c = client();
      c.applyUsage({'input_tokens': 10, 'output_tokens': 2});
      expect(c.lastTotalTokens, 12);
      expect(c.lastPromptTokens, 10);
      expect(c.lastOutputTokens, 2);
    });

    test('兼容常见缓存字段别名', () {
      final c = client();
      c.applyUsage({
        'prompt_tokens': 10,
        'completion_tokens': 2,
        'total_tokens': 12,
        'cache_read_input_tokens': 5,
      });
      expect(c.lastCachedTokens, 5);

      final d = client();
      d.applyUsage({
        'input_tokens': 10,
        'output_tokens': 2,
        'total_tokens': 12,
        'cached_input_tokens': 4,
      });
      expect(d.lastCachedTokens, 4);
    });

    test('usage 没有缓存字段时保持未知，不沿用上次值', () {
      final c = client();
      c.applyUsage({
        'prompt_tokens': 10,
        'completion_tokens': 2,
        'total_tokens': 12,
        'prompt_tokens_details': {'cached_tokens': 8},
      });
      c.applyUsage({
        'prompt_tokens': 9,
        'completion_tokens': 1,
        'total_tokens': 10,
      });
      expect(c.lastCachedTokens, isNull);
    });
  });

  group('computeActiveContextTokens', () {
    var seq = 0;
    ChatMessage msg(
      String role, {
      String content = '',
      List<ToolCall>? toolCalls,
      bool streaming = false,
      bool archived = false,
    }) => ChatMessage(
      id: 'm${DateTime.now().microsecondsSinceEpoch}_${seq++}',
      sessionId: 's1',
      role: role,
      content: content,
      toolCalls: toolCalls,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      streaming: streaming,
      archived: archived,
    );

    test('没有真实 usage 基线时返回 null', () {
      final r = ShiyiState.computeActiveContextTokens(
        lastUsageTotalTokens: null,
        messages: [msg('user', content: '你好')],
      );
      expect(r, isNull);
    });

    test('真实基线 + 最后模型项之后新增用户消息', () {
      final r = ShiyiState.computeActiveContextTokens(
        lastUsageTotalTokens: 1000,
        messages: [
          msg('assistant', content: '旧回复'),
          msg('user', content: '新问题'),
        ],
      );
      expect(r, 1003);
    });

    test('纯工具轮后新增 tool 结果计入估算', () {
      final r = ShiyiState.computeActiveContextTokens(
        lastUsageTotalTokens: 2000,
        messages: [
          msg(
            'assistant',
            toolCalls: [
              ToolCall(
                id: 'c1',
                name: 'run_terminal',
                arguments: '{"command":"ls"}',
              ),
            ],
          ),
          msg('tool', content: '结果'),
        ],
      );
      expect(r, 2002);
    });

    test('空流式占位不算模型项，新增用户消息仍计入', () {
      final r = ShiyiState.computeActiveContextTokens(
        lastUsageTotalTokens: 1000,
        messages: [
          msg('assistant', content: '旧回复'),
          msg('user', content: '新问题'),
          msg('assistant', streaming: true),
        ],
      );
      expect(r, 1003);
    });

    test('新增 streaming 消息跳过估算', () {
      final r = ShiyiState.computeActiveContextTokens(
        lastUsageTotalTokens: 500,
        messages: [
          msg('assistant', content: '回复'),
          msg('user', content: '还没发送', streaming: true),
        ],
      );
      expect(r, 500);
    });

    test('图片消息按每张 1000 Token 估算', () {
      final tokens = ShiyiState.estimateChatMessageTokens(
        msg('user', content: '看图![图片](/data/a.png)'),
      );
      expect(tokens, greaterThan(1000));
    });

    test('已归档消息不计入真实 usage 基线后的新增估算', () {
      final r = ShiyiState.computeActiveContextTokens(
        lastUsageTotalTokens: 1000,
        messages: [
          msg('assistant', content: '旧回复'),
          msg('user', content: '归档内容' * 1000, archived: true),
          msg('user', content: '最新问题'),
        ],
      );
      expect(r, 1004);
    });

    test('ChatMessage 归档标记落库往返不丢失', () {
      final m = msg('user', content: '历史', archived: true);
      final restored = ChatMessage.fromMap(m.toMap());
      expect(restored.archived, isTrue);
      expect(restored.content, '历史');
    });
  });
}
