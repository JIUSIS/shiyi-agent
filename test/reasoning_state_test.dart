import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/app_state.dart';

void main() {
  test('拾忆思考强度按会话隔离，空值恢复提供商默认', () {
    final state = ShiyiState();

    state.setReasoningEffortForSession('session-a', 'high');
    state.setReasoningEffortForSession('session-b', 'low');

    expect(state.reasoningEffortForSession('session-a'), 'high');
    expect(state.reasoningEffortForSession('session-b'), 'low');
    expect(state.reasoningEffortForSession('session-c'), isNull);

    state.setReasoningEffortForSession('session-a', '');
    expect(state.reasoningEffortForSession('session-a'), isNull);
    expect(state.reasoningEffortForSession('session-b'), 'low');
  });

  test('拾忆思考开关与档位分离，关闭不丢上一档', () {
    final state = ShiyiState();

    state.setReasoningEffortForSession('session-a', 'low');
    expect(state.thinkingOnForSession('session-a'), isTrue);
    expect(state.reasoningEffortForSession('session-a'), 'low');

    state.setThinkingOnForSession('session-a', false);
    expect(state.thinkingOnForSession('session-a'), isFalse);
    expect(state.reasoningEffortForSession('session-a'), 'low');

    state.setThinkingOnForSession('session-a', true);
    expect(state.thinkingOnForSession('session-a'), isTrue);
    expect(state.reasoningEffortForSession('session-a'), 'low');

    state.setReasoningEffortForSession('session-a', 'off');
    expect(state.thinkingOnForSession('session-a'), isFalse);
    expect(state.reasoningEffortForSession('session-a'), 'low');

    state.setReasoningEffortForSession('session-b', 'max');
    expect(state.thinkingOnForSession('session-a'), isFalse);
    expect(state.thinkingOnForSession('session-b'), isTrue);
    expect(state.thinkingOnForSession('session-c'), isTrue);
  });
}
