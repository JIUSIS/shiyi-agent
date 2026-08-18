import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/app_state.dart';
import 'package:shiyi_agent_app/core/models.dart';

void main() {
  test('不同拾忆会话可以同时运行，停止一个不会影响另一个', () {
    final state = ShiyiState()..currentSessionId = 'session-b';

    state.setSessionActiveForTest('session-a', true);
    state.setSessionActiveForTest('session-b', true);

    expect(state.isBusy, isTrue);
    expect(state.isBusyForSession('session-a'), isTrue);
    expect(state.isBusyForSession('session-b'), isTrue);
    expect(state.canSendToSession('session-a'), isTrue);
    expect(state.canSendToSession('session-b'), isTrue);

    state.stopSession('session-b');

    expect(state.stopRequestedForSessionForTest('session-b'), isTrue);
    expect(state.stopRequestedForSessionForTest('session-a'), isFalse);
    expect(state.isBusyForSession('session-a'), isTrue);
  });

  test('流式内容、状态和工具事件按会话隔离', () {
    final state = ShiyiState();
    state.setSessionActiveForTest('session-a', true);
    state.setSessionActiveForTest('session-b', true);

    state.streamTextForSession('session-a').value = 'A 正文';
    state.streamReasoningForSession('session-a').value = 'A 思考';
    state.streamTextForSession('session-b').value = 'B 正文';
    state.streamReasoningForSession('session-b').value = 'B 思考';
    state.setSessionStatusForTest('session-a', 'A 正在调用工具');
    state.setSessionStatusForTest('session-b', 'B 正在思考');
    state
        .toolEventsForSession('session-a')
        .add(ToolEvent(name: 'read_file', argsSummary: 'a.txt', startedAt: 1));

    expect(state.streamTextForSession('session-a').value, 'A 正文');
    expect(state.streamReasoningForSession('session-a').value, 'A 思考');
    expect(state.streamTextForSession('session-b').value, 'B 正文');
    expect(state.streamReasoningForSession('session-b').value, 'B 思考');
    expect(state.statusForSession('session-a'), 'A 正在调用工具');
    expect(state.statusForSession('session-b'), 'B 正在思考');
    expect(state.toolEventsForSession('session-a'), hasLength(1));
    expect(state.toolEventsForSession('session-b'), isEmpty);
  });
}
