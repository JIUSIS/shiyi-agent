import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/app_state.dart';
import 'package:shiyi_agent_app/services/llm_client.dart';

void main() {
  group('思考内容流式显示修复', () {
    test('流式期间有 reasoning 但无 text 时，不应把 reasoning 移到 text', () {
      // 模拟流式初期：只有思考内容，正文还是空的
      final result = TurnResult(
        text: '',
        reasoning: '我先分析一下这个问题...',
        toolCalls: [],
      );

      final normalized = ShiyiState.normalizeMisplacedReasoningForTest(result);

      // 关键验证：reasoning 应该保持在 reasoning 字段，不应被移到 text
      expect(normalized.reasoning, '我先分析一下这个问题...');
      expect(normalized.text, '');
    });

    test('流式期间 reasoning 和 text 都有内容时，应该分别保留', () {
      final result = TurnResult(
        text: '根据分析，答案是：',
        reasoning: '我先分析一下这个问题...',
        toolCalls: [],
      );

      final normalized = ShiyiState.normalizeMisplacedReasoningForTest(result);

      expect(normalized.reasoning, '我先分析一下这个问题...');
      expect(normalized.text, '根据分析，答案是：');
    });

    test('最终落库时，如果只有 reasoning 没有 text，应该保持原样', () {
      // 空正文不得把思考升成正文。
      final result = TurnResult(
        text: '',
        reasoning: '这是一个只有思考没有正文的回复',
        toolCalls: [],
      );

      final normalized = ShiyiState.normalizeMisplacedReasoningForTest(result);

      // 保持原样，转换逻辑由 _applyTurn 负责
      expect(normalized.reasoning, '这是一个只有思考没有正文的回复');
      expect(normalized.text, '');
    });

    test('落库时空正文的思考不得升成正文', () {
      final stored = ShiyiState.finalizeAssistantTurnForTest(
        TurnResult(text: '', reasoning: '用户想要一张内容比较多的表格。'),
      );
      expect(stored.text, isEmpty);
      expect(stored.reasoning, '用户想要一张内容比较多的表格。');
    });

    test('落库时工具轮空正文也保留思考，不把思考写进正文', () {
      final stored = ShiyiState.finalizeAssistantTurnForTest(
        TurnResult(
          text: '',
          reasoning: '先调研两件事：模型怎么下载、Rust 里怎么跑推理。',
          toolCalls: [
            {'id': 'c1', 'name': 'web_search', 'arguments': '{}'},
          ],
        ),
      );
      expect(stored.text, isEmpty);
      expect(stored.reasoning, '先调研两件事：模型怎么下载、Rust 里怎么跑推理。');
    });

    test('落库时正文和思考都有则分别保留', () {
      final stored = ShiyiState.finalizeAssistantTurnForTest(
        TurnResult(text: '好的，来个信息量足一点的。', reasoning: '用户想要内容比较多的表格。'),
      );
      expect(stored.text, '好的，来个信息量足一点的。');
      expect(stored.reasoning, '用户想要内容比较多的表格。');
    });

    test('思考增量立即推送，不跟正文布局一起节流', () {
      expect(
        ShiyiState.shouldThrottleReasoningStream(
          lastEmit: DateTime(2026, 8, 24, 14, 33, 3, 100),
          now: DateTime(2026, 8, 24, 14, 33, 3, 140),
          lastLen: 4,
          totalLen: 6,
        ),
        isFalse,
      );
      expect(
        ShiyiState.shouldThrottleContentStream(
          lastEmit: DateTime(2026, 8, 24, 14, 33, 3, 100),
          now: DateTime(2026, 8, 24, 14, 33, 3, 140),
          lastLen: 4,
          totalLen: 6,
        ),
        isTrue,
      );
    });

    test('reasoning 和 text 内容相同时，应该清空 reasoning（去重）', () {
      final result = TurnResult(
        text: '这是回复内容',
        reasoning: '这是回复内容',
        toolCalls: [],
      );

      final normalized = ShiyiState.normalizeMisplacedReasoningForTest(result);

      expect(normalized.reasoning, '');
      expect(normalized.text, '这是回复内容');
    });

    test('正文带 <thinking> 标签时，应该拆分到 reasoning', () {
      final result = TurnResult(
        text: '<thinking>让我想想...</thinking>实际回复内容',
        reasoning: '',
        toolCalls: [],
      );

      final normalized = ShiyiState.normalizeMisplacedReasoningForTest(result);

      expect(normalized.reasoning, '让我想想...');
      expect(normalized.text, '实际回复内容');
    });

    test('有工具调用时，不做任何转换', () {
      final result = TurnResult(
        text: '',
        reasoning: '需要调用工具',
        toolCalls: [
          {'id': 'call_1', 'name': 'test_tool', 'arguments': '{}'}
        ],
      );

      final normalized = ShiyiState.normalizeMisplacedReasoningForTest(result);

      // 有工具调用时原样返回
      expect(normalized.reasoning, '需要调用工具');
      expect(normalized.text, '');
    });
  });
}
