import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/group_chat.dart';

/// 层级行动调度（docs/fix-log.md #404）：
/// 一批 = 同一层被叫到的人 → 全员并行 → 整批汇报完才轮到上一级。
void main() {
  GroupAgent agent(String id, String name, {String reportsTo = ''}) =>
      GroupAgent(id: id, roomId: 'r', name: name, reportsToId: reportsTo);

  GroupMessage reply(String text) => GroupMessage(
    id: 'm${text.hashCode}',
    roomId: 'r',
    role: 'agent',
    content: text,
    createdAt: 0,
  );

  /// 用户 → 主管 → 两组长（一组 4 人 / 二组 5 人）
  List<GroupAgent> org() => [
    agent('boss', '主管'),
    agent('l1', '一组长', reportsTo: 'boss'),
    agent('l2', '二组长', reportsTo: 'boss'),
    for (var i = 1; i <= 4; i++)
      agent('a1$i', '一组员$i', reportsTo: 'l1'),
    for (var i = 1; i <= 5; i++)
      agent('a2$i', '二组员$i', reportsTo: 'l2'),
  ];

  test('用户叫两个组长：两线程并行，且不夹带任何其他层', () {
    final agents = org();
    final s = GroupRoundScheduler(
      agents: agents,
      initialTargets: groupChatMentionedAgents('@一组长 @二组长 开始', agents),
    );
    expect(s.wave.map((a) => a.id), ['l1', 'l2']);
  });

  test('一组全员 4 人 = 4 条线程（不再砍成 3），且组长不与组员同批', () {
    final agents = org();
    final s = GroupRoundScheduler(
      agents: agents,
      initialTargets: groupChatMentionedAgents('@一组长 干活 @二组长 待命', agents),
    );
    // 第一批：两个组长（用户点名的都启动）
    expect(s.wave.map((a) => a.id), ['l1', 'l2']);
    s.complete(
      replies: [
        reply('@一组员1 @一组员2 @一组员3 @一组员4 你们四个并行做这件事'),
        reply('收到，我这组待命。'),
      ],
    );
    // 第二批：一组长派的 4 个人，全员并行；组长/主管都不许出现
    expect(s.wave.map((a) => a.id), ['a11', 'a12', 'a13', 'a14']);
    // 组员全部汇报完
    s.complete(
      replies: [
        reply('一组员1 完成'),
        reply('一组员2 完成'),
        reply('一组员3 完成'),
        reply('一组员4 完成'),
      ],
    );
    // 第三批：只有一组长（屏障：不是「组员4 + 一组长」同批）
    expect(s.wave.map((a) => a.id), ['l1']);
    s.complete(replies: [reply('汇总：四项都完成了。')]);
    // 第四批：一组长汇报完 + 二组长早就说完 → 主管才起来
    expect(s.wave.map((a) => a.id), ['boss']);
    s.complete(replies: [reply('给用户的结论。')]);
    expect(s.finished, isTrue);
  });

  test('组员先跑完不会把组长提前拉起来（同批屏障）', () {
    final agents = org();
    final s = GroupRoundScheduler(
      agents: agents,
      initialTargets: groupChatMentionedAgents('@一组长 派活', agents),
    );
    expect(s.wave.map((a) => a.id), ['l1']);
    s.complete(replies: [reply('@一组员1 @一组员2 @一组员3 @一组员4 开工')]);
    expect(s.wave.map((a) => a.id), ['a11', 'a12', 'a13', 'a14']);
    // 只完成整批之后才算下一批：这一批里不可能出现 l1
    expect(s.wave.any((a) => a.id == 'l1'), isFalse);
    s.complete(
      replies: [
        reply('一完成'),
        reply('二完成'),
        reply('三完成'),
        reply('四完成'),
      ],
    );
    expect(s.wave.map((a) => a.id), ['l1']);
  });

  test('可以指定组员，也可以全员：点名谁就只启动谁', () {
    final agents = org();
    final s = GroupRoundScheduler(
      agents: agents,
      initialTargets: groupChatMentionedAgents('@一组长 派活', agents),
    );
    s.complete(replies: [reply('@一组员2 这件事你来做')]);
    expect(s.wave.map((a) => a.id), ['a12']);
  });

  test('同级接力：组员 @ 另一个组员，不越级', () {
    final agents = org();
    final s = GroupRoundScheduler(
      agents: agents,
      initialTargets: groupChatMentionedAgents('@一组员1 起个头', agents),
    );
    s.complete(replies: [reply('@一组员3 这部分你来补')]);
    expect(s.wave.map((a) => a.id), ['a13']);
  });

  test('@自己的上级算汇报，不算派活（主管能被正常拉起）', () {
    final agents = org();
    final s = GroupRoundScheduler(
      agents: agents,
      initialTargets: groupChatMentionedAgents('@一组长 干活', agents),
    );
    s.complete(replies: [reply('@主管 我这组的三项都做完了。')]);
    // 一组长已汇报 → 主管起来
    expect(s.wave.map((a) => a.id), ['boss']);
  });

  test('两个组长分别派活：两组同时跑，组长等各自全员汇报完', () {
    final agents = org();
    final s = GroupRoundScheduler(
      agents: agents,
      initialTargets: groupChatMentionedAgents('@一组长 @二组长 各自开工', agents),
    );
    expect(s.wave.map((a) => a.id), ['l1', 'l2']);
    s.complete(
      replies: [
        reply('@一组员1 @一组员2 做甲'),
        reply('@二组员1 做乙'),
      ],
    );
    expect(s.wave.map((a) => a.id), ['a11', 'a12', 'a21']);
    s.complete(replies: [reply('甲1 完成'), reply('甲2 完成'), reply('乙1 完成')]);
    // 两位组长同时起来（同层并行），主管仍不出现
    expect(s.wave.map((a) => a.id), ['l1', 'l2']);
  });

  test('同一交接环节打回最多 3 次', () {
    final agents = org();
    final s = GroupRoundScheduler(
      agents: agents,
      initialTargets: groupChatMentionedAgents('@一组长 派活', agents),
    );
    s.complete(replies: [reply('@一组员1 去做')]);
    var memberWaves = 0;
    var leadWaves = 0;
    while (s.hasWave && leadWaves < 10) {
      final ids = s.wave.map((a) => a.id).toList();
      if (ids.length == 1 && ids.first == 'a11') {
        memberWaves++;
        s.complete(replies: [reply('做完了')]);
      } else if (ids.length == 1 && ids.first == 'l1') {
        leadWaves++;
        s.complete(replies: [reply('打回 @一组员1 重做')]);
      } else {
        break;
      }
    }
    // 组员被拉起 1（首次派活）+ 3（三次打回）次；第 4 次打回不再拉起
    expect(memberWaves, 4);
    expect(leadWaves, 4);
    expect(s.hasWave, isFalse);
  });

  test('互相 @ 的死循环有安全阀，不会无限跑', () {
    final agents = [
      agent('x', '甲'),
      agent('y', '乙'),
      agent('z', '丙'),
    ];
    final s = GroupRoundScheduler(
      agents: agents,
      initialTargets: groupChatMentionedAgents('@甲 开始', agents),
    );
    var waves = 0;
    while (s.hasWave && waves < 100) {
      waves++;
      s.complete(replies: [for (final _ in s.wave) reply('@乙 继续')]);
    }
    expect(waves, lessThanOrEqualTo(GroupRoundScheduler.maxWaves));
  });
}
