import 'package:flutter_test/flutter_test.dart';

import 'package:shiyi_agent_app/screens/dsh_workspaces_tab.dart';
import 'package:shiyi_agent_app/services/dsh_api.dart';

/// workspace 接口不可用时的兜底：按会话 cwd 反推工作区列表。
/// 见 docs/fix-log.md #388。
void main() {
  DshSessionSummary session(String id, String? cwd, {int updatedAt = 0}) =>
      DshSessionSummary(
        sessionId: id,
        updatedAt: updatedAt,
        running: false,
        blank: false,
        cwd: cwd,
      );

  test('按 cwd 分组，同一目录的会话进同一工作区', () {
    final out = dshWorkspacesFromSessions([
      session('s1', '/storage/emulated/0/agent', updatedAt: 10),
      session('s2', '/storage/emulated/0/agent', updatedAt: 30),
      session('s3', '/storage/emulated/0/work', updatedAt: 20),
    ]);
    expect(out, hasLength(2));
    // 最近更新的排前面
    expect(out.first.path, '/storage/emulated/0/agent');
    expect(out.first.sessionIds, ['s1', 's2']);
    expect(out.first.updatedAt, '30');
    expect(out.last.path, '/storage/emulated/0/work');
    expect(out.last.sessionIds, ['s3']);
  });

  test('路径归一化：反斜杠/尾斜杠视为同一工作区', () {
    final out = dshWorkspacesFromSessions([
      session('a', r'C:\Users\x\agent'),
      session('b', r'C:\Users\x\agent\'),
    ]);
    expect(out, hasLength(1));
    expect(out.first.sessionIds, ['a', 'b']);
  });

  test('没有 cwd 的会话不伪造工作区', () {
    final out = dshWorkspacesFromSessions([
      session('a', null),
      session('b', '   '),
    ]);
    expect(out, isEmpty);
  });

  test('标题留空交给 dshWorkspaceDisplayName 按目录名显示', () {
    final out = dshWorkspacesFromSessions([session('a', '/sdcard/agent')]);
    expect(out.single.title, '');
    expect(
      dshWorkspaceDisplayName(out.single.title, out.single.path, '/sdcard/agent'),
      '默认',
    );
    final other = dshWorkspacesFromSessions([session('b', '/sdcard/proj-x')]);
    expect(
      dshWorkspaceDisplayName(
        other.single.title,
        other.single.path,
        '/sdcard/agent',
      ),
      'proj-x',
    );
  });
}
