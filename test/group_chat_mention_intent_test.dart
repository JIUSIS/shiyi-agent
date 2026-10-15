import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/group_chat.dart';

/// 「@ 到名字」≠「现在就启动」（docs/fix-log.md #408）。
/// 用户报的场景：一条消息里 @1 派审核任务，同时把 @2 写进「1 通过后再叫 2」的条件里，
/// 结果两个人都启动了。
void main() {
  GroupAgent agent(String id, String name, {String reportsTo = ''}) =>
      GroupAgent(id: id, roomId: 'r', name: name, reportsToId: reportsTo);

  List<GroupAgent> org() => [
    agent('boss', '主管'),
    agent('a', '甲', reportsTo: 'boss'),
    agent('b', '乙', reportsTo: 'boss'),
    agent('c', '丙', reportsTo: 'boss'),
  ];

  List<String> ids(List<GroupAgent> agents) => [for (final a in agents) a.id];

  test('用户 @1 派活 + 条件里提到 @2：只启动 1', () {
    final agents = org();
    final text = '@甲 你接受这个审核任务，审核通过后再让 @乙 来实现';
    expect(ids(groupChatInitialTargets(text, agents)), ['a']);
  });

  test('「之后再」「然后」「等…后」等顺序说法都不启动', () {
    final agents = org();
    expect(ids(groupChatInitialTargets('@甲 先看看，之后再 @乙 动手', agents)), ['a']);
    expect(ids(groupChatInitialTargets('@甲 处理完，然后 @乙 接手', agents)), ['a']);
    expect(ids(groupChatInitialTargets('@甲 干着，等甲完成后 @乙 上', agents)), ['a']);
    expect(ids(groupChatInitialTargets('@甲 先做，如果没问题再叫 @乙', agents)), ['a']);
  });

  test('名字是「动作对象」时不启动（审核 @乙 的方案）', () {
    final agents = org();
    expect(ids(groupChatInitialTargets('@甲 审核 @乙 的方案', agents)), ['a']);
    expect(ids(groupChatInitialTargets('@甲 检查 @丙 的结果', agents)), ['a']);
  });

  test('同一子句里一起点到的人都要启动（没被削弱）', () {
    final agents = org();
    expect(ids(groupChatInitialTargets('请 @甲 和 @乙 一起做这件事', agents)), ['a', 'b']);
    expect(ids(groupChatInitialTargets('@甲 @乙 你们俩分头干活', agents)), ['a', 'b']);
    expect(ids(groupChatInitialTargets('@甲 做这个，@乙 做那个', agents)), ['a', 'b']);
  });

  test('既当对象又被直接叫到时，按直接叫处理', () {
    final agents = org();
    expect(
      ids(groupChatInitialTargets('@甲 审核 @乙 的方案，@乙 你随后自己改', agents)),
      ['a', 'b'],
    );
  });

  test('全都只是引用时，交给对接用户的负责人判断', () {
    final agents = org();
    final text = '等 @甲 完成后，再让 @乙 复核';
    expect(ids(groupChatInitialTargets(text, agents)), ['boss']);
  });

  test('「只 @了收件人，后面是给他看的需求文档」→ 只启动收件人', () {
    // 用户原话（只 @了经理，后面整段是给经理看的需求与拆棒建议）
    final agents = [
      agent('mgr', '经理'),
      agent('r1', '可行审'),
      agent('h1', '码手A', reportsTo: 'mgr'),
      agent('h2', '码手B', reportsTo: 'mgr'),
    ];
    const text = '''
@经理 可行审已放行，按这份需求与 4 条约束拆任务下发码手：

**需求**：动态 SVG 鹈鹕骑车，单 `.svg` 文件 ≤10KB，无 JS 无外链，打开即播。

**4 条硬约束（一并下达）**：
1. **腿部卡通曲柄式简化**：无 JS 不做真实膝关节 IK，整条腿绕踏板中轴旋转，两腿相位差 180°

**建议拆两棒**（你可自行调整）：
- 棒1 造型+结构：@码手A 鹈鹕造型（身体/翅膀/大嘴）+ 自行车（车架/轮/踏板）静态定稿
- 棒2 动画：@码手B 动画层（轮转/腿踩踏/身体起伏/背景流动），按约束 1、2、3 实现

集成后交回 @可行审 复核。我待命，有进展同步给我。
''';
    expect(ids(groupChatInitialTargets(text, agents)), ['mgr']);
  });

  test('文档体之外仍照旧：多人都被直接叫到时都启动', () {
    final agents = org();
    expect(
      ids(groupChatInitialTargets('@甲 做这个，@乙 做那个，做完同步我', agents)),
      ['a', 'b'],
    );
    expect(ids(groupChatInitialTargets('@甲 @乙 你们俩分头干活', agents)), ['a', 'b']);
  });

  test('成员回复里的 @ 同样区分指派与「以后再说」', () {
    final agents = org();
    final boss = agents.firstWhere((a) => a.id == 'boss');
    // 指派甲现在做，同时说明「做完后让乙验收」→ 只叫甲
    final followups = groupChatFollowupTargets(
      speaker: boss,
      reply: '@甲 你现在做这个，做完后 @乙 来验收',
      agents: agents,
    );
    expect(ids([for (final f in followups) f.target]), ['a']);
    // 明确指派两个人 → 两个都叫
    final both = groupChatFollowupTargets(
      speaker: boss,
      reply: '@甲 @乙 你们一起做',
      agents: agents,
    );
    expect(ids([for (final f in both) f.target]).toSet(), {'a', 'b'});
  });
}
