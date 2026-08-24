import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/reasoning_models.dart';
import 'package:shiyi_agent_app/services/dsh_model_sync.dart';
import 'package:shiyi_agent_app/services/llm_client.dart';

void main() {
  Map<String, String?>? efforts(String model) =>
      ReasoningModels.effortsFor(model);

  test('按模型 ID 关键字识别，不绑死版本号', () {
    expect(efforts('gpt-5.6'), isNotNull);
    expect(efforts('gpt-5.6')!.containsKey('off'), isTrue);
    expect(efforts('gpt-5'), isNotNull);
    expect(efforts('openai/gpt-5-mini'), contains('xhigh'));
    expect(efforts('gpt-4.1-mini'), isNotNull);
    expect(efforts('deepseek-v4-flash'), isNotNull);
    expect(efforts('deepseek-chat'), isNotNull);
    expect(efforts('claude-sonnet-4-5'), isNotNull);
    expect(efforts('anthropic/claude-opus-4-1'), isNotNull);
    expect(efforts('claude-3-5-sonnet-20241022'), containsPair('off', null));
    expect(efforts('x-ai/grok-4'), isNotNull);
    expect(efforts('grok-3-mini'), containsPair('off', null));
    expect(efforts('gemini-2.5-flash'), isNotNull);
    expect(efforts('qwen-plus'), isNotNull);
    expect(efforts('glm-4.6'), isNotNull);
    expect(efforts('kimi-k2-thinking'), isNotNull);
    expect(efforts('moonshot-v1-8k'), isNotNull);
    expect(efforts('doubao-1-5-pro-32k-250115'), isNotNull);
  });

  test('对不上家族关键字的模型也显示通用思考档位，但不自动发思考参数', () {
    const ordinary = [
      'llama-3.3-70b-versatile',
      'text-embedding-3-small',
      'dall-e-3',
      'custom-local-7b',
    ];
    for (final id in ordinary) {
      expect(efforts(id), ReasoningModels.offLowHighMax, reason: '$id 应显示思考按钮');
      expect(ReasoningModels.defaultEffort(id), isNull);
      expect(LlmClient.defaultReasoningEffort(id), isNull);
    }
    expect(ReasoningModels.profile(''), isNull);
  });

  test('空模型 ID 不显示思考按钮；非空模型一律有档位表', () {
    expect(ReasoningModels.effortsFor(''), isNull);
    expect(LlmClient.reasoningEffortsForModel(''), isNull);
    expect(ReasoningModels.effortsFor('mimo-v2.5-pro'), isNotNull);
    expect(ReasoningModels.effortsFor('custom-local-7b'), isNotNull);
  });

  test('拾忆与 DSH 共用同一套档位表', () {
    const ids = [
      'claude-sonnet-4-5',
      'gpt-5.6',
      'grok-4',
      'o3-mini',
      'deepseek-v4-flash',
      'llama-3.3-70b-versatile',
    ];
    for (final id in ids) {
      expect(
        LlmClient.reasoningEffortsForModel(id),
        DshModelSync.reasoningEffortsForModel(id),
      );
      expect(
        LlmClient.defaultReasoningEffort(id),
        DshModelSync.defaultReasoningEffort(id),
      );
    }
  });

  test('o 系列仍无 off；GPT 关闭走 none；Claude 走 Anthropic thinking', () {
    expect(efforts('o3-mini')!.containsKey('off'), isFalse);
    expect(ReasoningModels.profile('gpt-5.6')!.usesNoneForOff, isTrue);
    expect(
      ReasoningModels.profile('claude-sonnet-4-5')!.usesAnthropicThinking,
      isTrue,
    );
    expect(
      ReasoningModels.usesDeepSeekThinkingParam('deepseek-v4-flash'),
      isTrue,
    );
    expect(ReasoningModels.usesDeepSeekThinkingParam('gpt-5.6'), isFalse);
  });

  test('gpt-4o / gpt-4.1 不是思考模型；gpt-5 才默认 high', () {
    expect(ReasoningModels.defaultEffort('gpt-4o'), isNull);
    expect(ReasoningModels.defaultEffort('openai/gpt-4o'), isNull);
    expect(ReasoningModels.defaultEffort('gpt-4.1-mini'), isNull);
    expect(ReasoningModels.defaultEffort('gpt-5'), 'high');
    expect(ReasoningModels.defaultEffort('openai/gpt-5-mini'), 'high');
    expect(ReasoningModels.profile('gpt-5.6')!.usesNoneForOff, isTrue);
  });

  test('Anthropic budget_tokens 始终小于 max_tokens', () {
    expect(ReasoningModels.anthropicBudget('high', 16384), lessThan(16384));
    expect(ReasoningModels.anthropicBudget('max', 8192), lessThan(8192));
    expect(ReasoningModels.anthropicBudget('low', 2048), lessThan(2048));
  });
}
