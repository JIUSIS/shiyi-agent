import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyi_agent_app/screens/dsh_workspaces_tab.dart';
import 'package:shiyi_agent_app/services/dsh_api.dart';

void main() {
  const def = '/storage/emulated/0/agent';

  test('默认 agent 目录显示为默认', () {
    expect(dshWorkspaceDisplayName('agent', def, def), '默认');
    expect(dshWorkspaceDisplayName('', def, def), '默认');
    expect(dshWorkspaceDisplayName('agent', '$def/', def), '默认');
  });

  test('用户改过名则保留', () {
    expect(dshWorkspaceDisplayName('小说项目', def, def), '小说项目');
  });

  test('非默认目录用标题或文件夹名', () {
    expect(
      dshWorkspaceDisplayName('docs', '/storage/emulated/0/docs', def),
      'docs',
    );
    expect(
      dshWorkspaceDisplayName('', '/storage/emulated/0/work', def),
      'work',
    );
  });

  test('已归档会话不出现在活动列表', () {
    DshSessionSummary s(String id) => DshSessionSummary(
      sessionId: id,
      updatedAt: 0,
      running: false,
      blank: true,
    );
    final active = dshActiveSessions([s('a'), s('b'), s('c')], ['b']);
    expect(active.map((e) => e.sessionId), ['a', 'c']);
  });

  test('默认工作区按路径识别，带尾斜杠也算', () {
    expect(dshIsDefaultWorkspacePath(def, def), isTrue);
    expect(dshIsDefaultWorkspacePath('$def/', def), isTrue);
    expect(dshIsDefaultWorkspacePath('/storage/emulated/0/docs', def), isFalse);
  });

  test('展开偏好只在首次恢复，后续刷新不能把收起的工作区再打开', () {
    expect(
      dshRestoreExpandedWorkspaceIds(
        saved: null,
        knownIds: const ['def', 'docs'],
        defaultWorkspaceId: 'def',
      ),
      {'def'},
    );
    expect(
      dshRestoreExpandedWorkspaceIds(
        saved: const ['docs'],
        knownIds: const ['def', 'docs'],
        defaultWorkspaceId: 'def',
      ),
      {'docs'},
    );
    expect(
      dshRestoreExpandedWorkspaceIds(
        saved: const ['gone', 'docs'],
        knownIds: const ['def', 'docs'],
        defaultWorkspaceId: 'def',
      ),
      {'docs'},
    );
  });

  test('cwd 一致才算已入账，对不上的 sessionIds 不当成该工作区', () {
    DshWorkspace w(String id, String path, List<String> ids) => DshWorkspace(
      workspaceId: id,
      path: path,
      title: id,
      sessionIds: ids,
      createdAt: '',
      updatedAt: '',
    );
    final defW = w('def', def, const ['s-old']);
    final docs = w('docs', '/storage/emulated/0/docs', const []);
    expect(
      dshWorkspaceIdsForSession(
        sessionId: 's-old',
        cwd: '/storage/emulated/0/docs',
        workspaces: [defW, docs],
        defaultWorkspaceId: 'def',
      ),
      ['docs'],
    );
    expect(
      dshSessionMoveCwd(
        sessionCwd: '/storage/emulated/0/agent',
        workspacePath: '/storage/emulated/0/docs',
      ),
      '/storage/emulated/0/docs',
    );
    expect(
      dshSessionMoveCwd(
        sessionCwd: '/storage/emulated/0/docs/',
        workspacePath: '/storage/emulated/0/docs',
      ),
      isNull,
    );
  });

  test('未写入 sessionIds 时按会话 cwd 归到对应工作区', () {
    DshWorkspace w(String id, String path, List<String> ids) => DshWorkspace(
      workspaceId: id,
      path: path,
      title: id,
      sessionIds: ids,
      createdAt: '',
      updatedAt: '',
    );
    final defW = w('def', def, const []);
    final docs = w('docs', '/storage/emulated/0/docs', const []);
    expect(
      dshWorkspaceIdsForSession(
        sessionId: 's1',
        cwd: '/storage/emulated/0/docs/',
        workspaces: [defW, docs],
        defaultWorkspaceId: 'def',
      ),
      ['docs'],
    );
    expect(
      dshWorkspaceIdsForSession(
        sessionId: 's2',
        cwd: null,
        workspaces: [defW, docs],
        defaultWorkspaceId: 'def',
      ),
      ['def'],
    );
  });

  test('只改 sessionIds 不改 cwd 时，会话会按路径掉回原工作区', () {
    DshWorkspace w(String id, String path, List<String> ids) => DshWorkspace(
      workspaceId: id,
      path: path,
      title: id,
      sessionIds: ids,
      createdAt: '',
      updatedAt: '',
    );
    final src = w('src', '/ws/src', const ['a', 'b', 'c', 'd']);
    final dst = w('dst', '/ws/dst', const []);
    expect(
      dshWorkspaceIdsForSession(
        sessionId: 'a',
        cwd: '/ws/src',
        workspaces: [
          src.copyWith(sessionIds: const ['b', 'c', 'd']),
          dst.copyWith(sessionIds: const ['a']),
        ],
        defaultWorkspaceId: 'src',
      ),
      ['src'],
    );
  });

  test('乐观搬家同时改 sessionIds 和 cwd，源工作区只剩 BCD', () {
    DshWorkspace w(String id, String path, List<String> ids) => DshWorkspace(
      workspaceId: id,
      path: path,
      title: id,
      sessionIds: ids,
      createdAt: '',
      updatedAt: '',
    );
    DshSessionSummary s(String id, String cwd) => DshSessionSummary(
      sessionId: id,
      updatedAt: 0,
      running: false,
      blank: true,
      cwd: cwd,
    );
    final src = w('src', '/ws/src', const ['a', 'b', 'c', 'd']);
    final dst = w('dst', '/ws/dst', const ['x']);
    final moved = dshOptimisticMoveSession(
      workspaces: [src, dst],
      sessions: [s('a', '/ws/src'), s('b', '/ws/src'), s('x', '/ws/dst')],
      sessionId: 'a',
      toWorkspaceId: 'dst',
      toIndex: 1,
    );
    expect(moved.workspaces[0].sessionIds, ['b', 'c', 'd']);
    expect(moved.workspaces[1].sessionIds, ['x', 'a']);
    expect(moved.sessions.firstWhere((e) => e.sessionId == 'a').cwd, '/ws/dst');
    expect(
      dshWorkspaceIdsForSession(
        sessionId: 'a',
        cwd: moved.sessions.firstWhere((e) => e.sessionId == 'a').cwd,
        workspaces: moved.workspaces,
        defaultWorkspaceId: 'src',
      ),
      ['dst'],
    );
  });

  test('工作区会话按 sessionIds 排，cwd 兜底项接到末尾', () {
    DshSessionSummary s(String id) => DshSessionSummary(
      sessionId: id,
      updatedAt: 0,
      running: false,
      blank: true,
    );
    expect(
      dshOrderedWorkspaceSessions(
        assigned: [s('c'), s('a'), s('b'), s('d')],
        sessionIds: const ['b', 'a'],
      ).map((e) => e.sessionId),
      ['b', 'a', 'c', 'd'],
    );
  });

  group('工作区展开状态持久化', () {
    test('保存后能按工作区 id 原样读回（排序去重）', () async {
      SharedPreferences.setMockInitialValues({});
      await dshSaveExpandedWorkspaceIds(['w2', 'w1', 'w2']);
      expect(await dshLoadExpandedWorkspaceIds(), ['w1', 'w2']);
    });

    test('首次启动没有偏好时返回 null（默认展开默认工作区）', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await dshLoadExpandedWorkspaceIds(), isNull);
    });

    test('保存空列表表示全部收起，不回到默认展开', () async {
      SharedPreferences.setMockInitialValues({});
      await dshSaveExpandedWorkspaceIds(const []);
      expect(await dshLoadExpandedWorkspaceIds(), isEmpty);
    });
  });
}
