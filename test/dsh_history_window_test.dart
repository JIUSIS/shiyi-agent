import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/models.dart';
import 'package:shiyi_agent_app/services/dsh_api.dart';
import 'package:shiyi_agent_app/services/dsh_history_window.dart';

ChatMessage _message(String id) => ChatMessage(
  id: id,
  sessionId: 'session-1',
  role: id.startsWith('u') ? 'user' : 'assistant',
  content: id,
  createdAt: 0,
);

void main() {
  group('dshPrependOlderMessages', () {
    test('把更早的一页拼到已加载消息前面', () {
      final current = [_message('a2'), _message('a3')];
      final merged = dshPrependOlderMessages(
        older: [_message('u1'), _message('a1')],
        current: current,
      );
      expect(merged.map((m) => m.id).toList(), ['u1', 'a1', 'a2', 'a3']);
    });

    test('按 id 去重，边界重叠不会多出气泡', () {
      final merged = dshPrependOlderMessages(
        older: [_message('u1'), _message('a2')],
        current: [_message('a2'), _message('a3')],
      );
      expect(merged.map((m) => m.id).toList(), ['u1', 'a2', 'a3']);
    });

    test('空页原样返回当前列表', () {
      final current = [_message('a2')];
      final merged = dshPrependOlderMessages(
        older: const <ChatMessage>[],
        current: current,
      );
      expect(merged.map((m) => m.id).toList(), ['a2']);
      expect(merged, isNot(same(current)));
    });
  });

  group('dshShouldLoadOlder', () {
    test('接近最老一端才触发补页', () {
      expect(
        dshShouldLoadOlder(
          hasMoreOlder: true,
          loading: false,
          pixels: 500,
          maxScrollExtent: 2000,
        ),
        isFalse,
      );
      expect(
        dshShouldLoadOlder(
          hasMoreOlder: true,
          loading: false,
          pixels: 1600,
          maxScrollExtent: 2000,
        ),
        isTrue,
      );
    });

    test('没有更多 / 正在加载 / 列表未溢出都不触发', () {
      expect(
        dshShouldLoadOlder(
          hasMoreOlder: false,
          loading: false,
          pixels: 2000,
          maxScrollExtent: 2000,
        ),
        isFalse,
      );
      expect(
        dshShouldLoadOlder(
          hasMoreOlder: true,
          loading: true,
          pixels: 2000,
          maxScrollExtent: 2000,
        ),
        isFalse,
      );
      expect(
        dshShouldLoadOlder(
          hasMoreOlder: true,
          loading: false,
          pixels: 0,
          maxScrollExtent: 0,
        ),
        isFalse,
      );
    });
  });

  group('dshShouldPauseTailRefresh', () {
    test('离开最新位置就暂停尾部刷新', () {
      expect(dshShouldPauseTailRefresh(pixels: 0), isFalse);
      expect(dshShouldPauseTailRefresh(pixels: 40), isFalse);
      expect(dshShouldPauseTailRefresh(pixels: 400), isTrue);
      expect(dshShouldPauseTailRefresh(pixels: double.nan), isFalse);
    });
  });

  group('historyPageRequest 窗口字段（官方 session/page）', () {
    const address = {'kind': 'session', 'sessionId': 'session-1'};

    test('窗口读取带上 maxMessages 与 turnWindow', () {
      final request = DshApiClient.historyPageRequest(
        address: address,
        throughSeq: -1,
        maxMessages: DshApiClient.historyWindowMessages,
        minMessages: DshApiClient.historyWindowMinMessages,
        minTurns: DshApiClient.historyWindowTurns,
      );
      expect(request['address'], address);
      expect(request['throughSeq'], -1);
      expect(request['maxMessages'], DshApiClient.historyWindowMessages);
      expect(request['turnWindow'], {
        'minMessages': DshApiClient.historyWindowMinMessages,
        'minTurns': DshApiClient.historyWindowTurns,
      });
      expect(request.containsKey('beforeSeq'), isFalse);
      // 官方 validateHistoryWindow：minMessages 必须 ≤ maxMessages。
      expect(
        DshApiClient.historyWindowMinMessages,
        lessThanOrEqualTo(DshApiClient.historyWindowMessages),
      );
    });

    test('上翻页带 beforeSeq，并沿用固定的尾部游标', () {
      final request = DshApiClient.historyPageRequest(
        address: address,
        beforeSeq: 120,
        throughSeq: 400,
        maxMessages: DshApiClient.historyOlderMessages,
      );
      expect(request['beforeSeq'], 120);
      expect(request['throughSeq'], 400);
      expect(request['maxMessages'], DshApiClient.historyOlderMessages);
      // 没传 turnWindow 参数时不拼 turnWindow，保持纯游标语义。
      expect(request.containsKey('turnWindow'), isFalse);
    });

    test('保守调用（无 maxMessages）退回裸游标请求', () {
      final request = DshApiClient.historyPageRequest(address: address);
      expect(request['throughSeq'], -1);
      expect(request.containsKey('maxMessages'), isFalse);
      expect(request.containsKey('turnWindow'), isFalse);
    });
  });
}
