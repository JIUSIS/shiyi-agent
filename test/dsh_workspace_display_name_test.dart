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
