import 'package:flutter_test/flutter_test.dart';

import 'package:shiyi_agent_app/services/dsh_api.dart';

/// rc.2 没有 `subagents/list`：子代理列表由 `session/list` 派生
/// （父会话的 `projections.values.subagentCatalog` + 子会话的
/// `origin:'subagent'` / `parentSessionId`）。见 docs/fix-log.md #396。
void main() {
  DshSessionSummary parent({
    required String id,
    bool agentAvailable = true,
    List<Map<String, dynamic>> catalog = const [],
  }) => DshSessionSummary(
    sessionId: id,
    updatedAt: 100,
    running: false,
    blank: false,
    agentAvailable: agentAvailable,
    subagentCatalog: catalog,
  );

  DshSessionSummary child({
    required String id,
    required String parentId,
    bool running = false,
    int updatedAt = 0,
    int turns = 0,
    String? title,
  }) => DshSessionSummary(
    sessionId: id,
    title: title,
    updatedAt: updatedAt,
    running: running,
    blank: false,
    isSubagent: true,
    parentSessionId: parentId,
    turnCount: turns,
  );

  test('目录优先：用 subagentCatalog 的顺序信息 + 子会话的运行态', () {
    final r = DshApiClient.deriveSubagents(
      parentSessionId: 'p',
      sessions: [
        parent(
          id: 'p',
          agentAvailable: true,
          catalog: [
            {'id': 'c1', 'createdAt': 10, 'mode': 'continuable', 'label': '探索'},
            {'id': 'c2', 'createdAt': 20, 'mode': 'one-shot'},
          ],
        ),
        child(id: 'c1', parentId: 'p', running: true, updatedAt: 30, turns: 2),
        child(id: 'c2', parentId: 'p', updatedAt: 40, turns: 5, title: '干活'),
      ],
    );
    expect(r.parentAvailable, isTrue);
    expect(r.entries.map((e) => e.sessionId), ['c2', 'c1']); // 按 updatedAt 倒序
    final c1 = r.entries.firstWhere((e) => e.sessionId == 'c1');
    expect(c1.running, isTrue);
    expect(c1.mode, 'continuable');
    expect(c1.title, '探索');
    expect(c1.turnCount, 2);
    final c2 = r.entries.firstWhere((e) => e.sessionId == 'c2');
    expect(c2.mode, 'one-shot');
    expect(c2.title, '干活');
  });

  test('目录缺失时退回按 parentSessionId 找子会话', () {
    final r = DshApiClient.deriveSubagents(
      parentSessionId: 'p',
      sessions: [
        parent(id: 'p'),
        child(id: 'c1', parentId: 'p', updatedAt: 5),
        child(id: 'other', parentId: 'x', updatedAt: 9),
        DshSessionSummary(
          sessionId: 's',
          updatedAt: 1,
          running: false,
          blank: false,
        ),
      ],
    );
    expect(r.entries.map((e) => e.sessionId), ['c1']);
  });

  test('别的父会话的子代理不会串进来；父会话不在列表时 parentAvailable=false', () {
    final r = DshApiClient.deriveSubagents(
      parentSessionId: 'p',
      sessions: [child(id: 'c1', parentId: 'x', updatedAt: 1)],
    );
    expect(r.entries, isEmpty);
    expect(r.parentAvailable, isFalse);
  });

  test('孙代理由 hasChildren 标出，父会话不可用时如实返回', () {
    final r = DshApiClient.deriveSubagents(
      parentSessionId: 'p',
      sessions: [
        parent(
          id: 'p',
          agentAvailable: false,
          catalog: [
            {'id': 'c1', 'createdAt': 1, 'mode': 'one-shot'},
          ],
        ),
        child(id: 'c1', parentId: 'p', updatedAt: 2),
        child(id: 'g1', parentId: 'c1', updatedAt: 3),
      ],
    );
    expect(r.parentAvailable, isFalse);
    expect(r.entries.single.hasChildren, isTrue);
  });

  test('session/list 里 agentPreset 在 projections.values 下也能读到', () {
    final s = DshSessionSummary.fromJson({
      'sessionId': 's1',
      'updatedAt': 1,
      'running': false,
      'blank': false,
      'projections': {
        'values': {
          'agentPreset': 'default',
          'title': 't',
        },
      },
    });
    expect(s.agentPreset, 'default');
  });
}
