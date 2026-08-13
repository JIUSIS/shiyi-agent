import 'package:flutter_test/flutter_test.dart';

import 'package:shiyi_agent_app/services/llm_client.dart';
import 'package:shiyi_agent_app/services/subagent.dart';

void main() {
  final def = SubagentDefinition.byName('explore')!;

  SubagentRunner makeRunner({
    Future<TurnResult?> Function(List<Map<String, dynamic>>)? round,
    bool Function()? shouldStop,
    int contextBudgetTokens = 0,
    Future<String> Function(String name, String args)? executeTool,
  }) {
    return SubagentRunner(
      baseUrl: 'http://fake',
      apiKey: 'k',
      model: 'm',
      temperature: 0.7,
      toolsJson: const [],
      executeTool: executeTool ?? (_, _) async => 'ok',
      workingDir: '/tmp',
      shouldStop: shouldStop,
      contextBudgetTokens: contextBudgetTokens,
      roundOverride: round,
    );
  }

  group('SubagentResult 状态与展示文本', () {
    test('success 携带报告与 token', () {
      final r = SubagentResult.success('报告', totalTokens: 42);
      expect(r.isSuccess, isTrue);
      expect(r.toModelText(), '报告');
      expect(r.totalTokens, 42);
    });

    test('stopped 展示文本', () {
      expect(
        SubagentResult.stopped().toModelText(),
        '（子代理已因用户停止而中断）',
      );
    });

    test('turnLimit 展示文本', () {
      expect(
        SubagentResult.turnLimit(15).toModelText(),
        '（子代理达到轮数上限 15，未完成，请简化任务或改用主循环执行）',
      );
    });

    test('generationFailed 展示文本', () {
      expect(
        SubagentResult.generationFailed().toModelText(),
        '（子代理生成失败）',
      );
    });

    test('requestFailed 展示文本', () {
      expect(
        SubagentResult.requestFailed('网络错误').toModelText(),
        '（子代理异常：网络错误）',
      );
    });

    test('失败状态 isSuccess 均为 false', () {
      expect(SubagentResult.stopped().isSuccess, isFalse);
      expect(SubagentResult.turnLimit(5).isSuccess, isFalse);
      expect(SubagentResult.generationFailed().isSuccess, isFalse);
      expect(SubagentResult.requestFailed('x').isSuccess, isFalse);
    });
  });

  group('SubagentRunner.run 状态路径', () {
    test('无工具调用 = success（文本 trim）', () async {
      final runner = makeRunner(
        round: (_) async => TurnResult(text: '  报告内容  '),
      );
      final r = await runner.run(def, '任务');
      expect(r.isSuccess, isTrue);
      expect(r.report, '报告内容');
    });

    test('单轮返回 null = generationFailed（不再伪装成功）', () async {
      final runner = makeRunner(round: (_) async => null);
      final r = await runner.run(def, '任务');
      expect(r.status, SubagentStatus.generationFailed);
      expect(r.isSuccess, isFalse);
    });

    test('LLM 异常 = requestFailed（不再伪装成功）', () async {
      final runner = makeRunner(
        round: (_) async => throw LlmException('网关 429'),
      );
      final r = await runner.run(def, '任务');
      expect(r.status, SubagentStatus.requestFailed);
      expect(r.error, contains('网关 429'));
    });

    test('用户停止 = stopped', () async {
      final runner = makeRunner(
        round: (_) async => TurnResult(text: 'x'),
        shouldStop: () => true,
      );
      final r = await runner.run(def, '任务');
      expect(r.status, SubagentStatus.stopped);
    });

    test('持续工具调用到轮数上限 = turnLimit', () async {
      final runner = makeRunner(
        round: (_) async => TurnResult(
          text: '',
          toolCalls: [
            {'id': 'c', 'name': 'file_read', 'arguments': '{}'},
          ],
        ),
      );
      final r = await runner.run(def, '任务'); // explore 默认 maxTurns 15
      expect(r.status, SubagentStatus.turnLimit);
      expect(r.error, contains('15'));
    });

    test('白名单外工具：返回跳过说明并继续下一轮', () async {
      var calls = 0;
      final runner = makeRunner(
        round: (_) async {
          calls++;
          if (calls == 1) {
            return TurnResult(
              text: '',
              toolCalls: [
                {'id': 'c1', 'name': 'file_write', 'arguments': '{}'},
              ],
            );
          }
          return TurnResult(text: '完成');
        },
      );
      final r = await runner.run(def, '任务');
      expect(r.isSuccess, isTrue);
      expect(r.report, '完成');
    });

    test('工具执行异常：作为工具结果返回，子代理可继续', () async {
      var calls = 0;
      final runner = makeRunner(
        round: (_) async {
          calls++;
          if (calls == 1) {
            return TurnResult(
              text: '',
              toolCalls: [
                {'id': 'c1', 'name': 'file_read', 'arguments': '{}'},
              ],
            );
          }
          return TurnResult(text: '已根据错误调整');
        },
        executeTool: (_, _) async => throw Exception('文件不存在'),
      );
      final r = await runner.run(def, '任务');
      expect(r.isSuccess, isTrue);
      expect(r.report, '已根据错误调整');
    });
  });

  group('上下文预算裁剪（⑦）', () {
    test('超预算：早期工具轮被成组删除，保留 system + user', () async {
      final seen = <List<Map<String, dynamic>>>[];
      var round = 0;
      final runner = makeRunner(
        round: (msgs) async {
          seen.add(List.of(msgs));
          round++;
          if (round >= 5) return TurnResult(text: '完成');
          return TurnResult(
            text: '',
            toolCalls: [
              {'id': 'c$round', 'name': 'file_read', 'arguments': '{}'},
            ],
          );
        },
        contextBudgetTokens: 50, // 极小预算，任何工具轮加入后必超
        executeTool: (_, _) async => '结果' * 200,
      );
      final r = await runner.run(def, '任务');
      expect(r.isSuccess, isTrue);
      // 裁剪生效：第一轮之后，每轮看到的消息都只剩 system + user。
      for (final msgs in seen.skip(1)) {
        expect(msgs.length, 2, reason: '早期工具轮应被上下文预算裁剪');
        expect(msgs[0]['role'], 'system');
        expect(msgs[1]['role'], 'user');
      }
    });

    test('预算 0（默认）：不裁剪，消息逐轮累积', () async {
      final seen = <int>[];
      var round = 0;
      final runner = makeRunner(
        round: (msgs) async {
          seen.add(msgs.length);
          round++;
          if (round >= 5) return TurnResult(text: '完成');
          return TurnResult(
            text: '',
            toolCalls: [
              {'id': 'c$round', 'name': 'file_read', 'arguments': '{}'},
            ],
          );
        },
        executeTool: (_, _) async => '结果' * 200,
      );
      final r = await runner.run(def, '任务');
      expect(r.isSuccess, isTrue);
      expect(seen, [2, 4, 6, 8, 10]); // 逐轮累积，无裁剪
    });
  });
}
