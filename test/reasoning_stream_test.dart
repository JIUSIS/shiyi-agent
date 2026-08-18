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

    test('最终落库时，如果只有 reasoning 没有 text，应该保持原样（由 _applyTurn 处理转换）', () {
      // _normalizeMisplacedReasoning 不再做 text.isEmpty 转换
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
