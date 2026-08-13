import 'package:flutter_test/flutter_test.dart';

import 'package:shiyi_agent_app/services/llm_client.dart';

void main() {
  group('buildContinuationPrompt', () {
    test('plan ending with colon and tools available returns tool wake-up', () {
      final prompt = LlmClient.buildContinuationPrompt('开始测试：', hasTools: true);

      expect(prompt, contains('还没有实际执行任何工具'));
      expect(prompt, contains('直接调用需要的工具'));
      expect(prompt, isNot(contains('继续完成上述输出')));
    });

    test('real truncation without plan keeps continue-writing prompt', () {
      final prompt = LlmClient.buildContinuationPrompt(
        '这是被截断的内容',
        hasTools: true,
      );

      expect(prompt, contains('继续完成上述输出'));
      expect(prompt, isNot(contains('还没有实际执行任何工具')));
    });

    test('no tools keeps continue-writing prompt even with colon', () {
      final prompt = LlmClient.buildContinuationPrompt(
        '开始测试：',
        hasTools: false,
      );

      expect(prompt, contains('继续完成上述输出'));
      expect(prompt, isNot(contains('直接调用需要的工具')));
    });
  });
}
