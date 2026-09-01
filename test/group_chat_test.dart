import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/group_chat.dart';
import 'package:shiyi_agent_app/core/models.dart';

GroupAgent agent({
  required String id,
  required String name,
  String title = '',
  String persona = '',
  String apiProfileId = '',
  String model = '',
  String reportsToId = '',
}) => GroupAgent(
  id: id,
  roomId: 'g1',
  name: name,
  title: title,
  persona: persona,
  apiProfileId: apiProfileId,
  model: model,
  reportsToId: reportsToId,
);

GroupMessage user(String content, {String id = 'u1'}) => GroupMessage(
  id: id,
  roomId: 'g1',
  role: 'user',
  content: content,
  createdAt: 1,
);

GroupMessage agentMsg(String agentId, String content, {String id = 'a1'}) =>
    GroupMessage(
      id: id,
      roomId: 'g1',
      role: 'agent',
      agentId: agentId,
      content: content,
      createdAt: 2,
    );

void main() {
  final lead = agent(id: 'lead', name: '主管', title: '项目经理', persona: '直接、短句');
  final dev = agent(id: 'dev', name: '开发', title: '工程师', reportsToId: 'lead');
  final design = agent(id: 'design', name: '设计', reportsToId: 'lead');
  final al = agent(id: 'al', name: 'Al', reportsToId: 'lead');
  final alice = agent(id: 'alice', name: 'Alice', reportsToId: 'lead');
  final org = [lead, dev, design];

  test('用户没点名时只找对接人，不是全员抢答', () {
    expect(groupChatInitialTargets('帮我做个方案', org).map((a) => a.id), ['lead']);
  });

  test('用户 @名字 可以越级点到具体的人', () {
    expect(groupChatInitialTargets('这个 bug @开发 看一下', org).map((a) => a.id), [
      'dev',
    ]);
  });

  test('长名优先，@Alice 不会误伤 Al', () {
    final mixed = [al, alice, lead];
    expect(groupChatMentionedAgents('@Alice 来一下', mixed).map((a) => a.id), [
      'alice',
    ]);
    expect(groupChatMentionedAgents('@Al 来一下', mixed).map((a) => a.id), ['al']);
  });

  test('负责人 @下属 后，下属接着说', () {
    expect(
      groupChatFollowupTargets(
        speaker: lead,
        reply: '先让开发看实现。@开发',
        agents: org,
      ).map((item) => item.target.id),
      ['dev'],
    );
  });

  test('下属说完没点名，则向直接上级汇报', () {
    expect(
      groupChatFollowupTargets(
        speaker: dev,
        reply: '接口可以今天下午给。',
        agents: org,
      ).map((item) => item.target.id),
      ['lead'],
    );
  });

  test('对接人说完没点名就结束，不会全员接话', () {
    expect(
      groupChatFollowupTargets(speaker: lead, reply: '这个我直接回用户。', agents: org),
      isEmpty,
    );
  });

  test('并行批次里的多目标会去重排队', () {
    final next = groupChatNextFollowupTargets(
      speakers: [lead, lead],
      replies: [agentMsg('lead', '@开发 先看'), agentMsg('lead', '@开发 @设计 出稿')],
      agents: org,
    );
    expect(next.map((item) => item.target.id), ['dev', 'design']);
  });

  test('多个下属汇报同一上级，不会重复排队', () {
    final next = groupChatNextFollowupTargets(
      speakers: [dev, design],
      replies: [agentMsg('dev', '完成'), agentMsg('design', '也完成')],
      agents: org,
    );
    expect(next.map((item) => item.target.id), ['lead']);
  });

  test('正常点名不算打回', () {
    final next = groupChatFollowupTargets(
      speaker: lead,
      reply: '@开发 继续下一步',
      agents: org,
    );
    expect(next.single.target.id, 'dev');
    expect(next.single.isRework, isFalse);
  });

  test('明确打回会被标记', () {
    for (final reply in ['打回：@开发 修边界', '【打回】@开发 修边界']) {
      final next = groupChatFollowupTargets(
        speaker: lead,
        reply: reply,
        agents: org,
      );
      expect(next.single.target.id, 'dev');
      expect(next.single.isRework, isTrue);
    }
  });

  test('组织环路会被拆掉', () {
    final cyclic = groupChatSanitizeOrg([
      agent(id: 'a', name: 'A', reportsToId: 'b'),
      agent(id: 'b', name: 'B', reportsToId: 'a'),
    ]);
    final reports = {for (final item in cyclic) item.id: item.reportsToId};
    expect(reports['a'] == 'b' && reports['b'] == 'a', isFalse);
    expect(groupChatUserFacingAgents(cyclic), isNotEmpty);
  });

  test('不能把自己的下属设成上级', () {
    expect(groupChatCanReportTo(lead, dev, org), isFalse);
    expect(groupChatCanReportTo(dev, lead, org), isTrue);
    expect(groupChatCanReportTo(dev, design, org), isTrue);
  });

  test('人设和架构都写进自己的 system', () {
    final prompt = groupChatSystemPrompt(lead, org);
    expect(prompt, contains('主管'));
    expect(prompt, contains('项目经理'));
    expect(prompt, contains('直接对接用户'));
    expect(prompt, contains('开发'));
    expect(prompt, contains('直接、短句'));
    final worker = groupChatSystemPrompt(dev, org);
    expect(worker, contains('上级是「主管」'));
    expect(worker, isNot(contains('直接、短句')));
  });

  test('多步任务要求明确点名接力', () {
    expect(groupChatSystemPrompt(lead, org), contains('多步任务必须用 @名字'));
  });

  test('组织树从用户开始往下画', () {
    final lines = groupChatOrgLines(org).join('\n');
    expect(lines, contains('用户'));
    expect(lines, contains('主管'));
    expect(lines, contains('对接用户'));
    expect(lines, contains('开发'));
    expect(lines, contains('设计'));
  });

  test('自己的历史是 assistant，别人是 [Name]: user', () {
    final history = [
      user('今天讨论标题'),
      agentMsg('lead', '我让开发看', id: 'm1'),
      agentMsg('dev', '可以做', id: 'm2'),
    ];
    final messages = groupChatApiMessages(
      speaker: lead,
      agents: org,
      history: history,
    );
    expect(messages.first['role'], 'system');
    expect(messages[1], {'role': 'user', 'content': '今天讨论标题'});
    expect(messages[2], {'role': 'assistant', 'content': '我让开发看'});
    expect(messages[3], {'role': 'user', 'content': '[开发]: 可以做'});
  });

  test('空的流式草稿不进请求', () {
    final history = [
      user('hi'),
      GroupMessage(
        id: 'draft',
        roomId: 'g1',
        role: 'agent',
        agentId: 'lead',
        streaming: true,
        createdAt: 3,
      ),
    ];
    final messages = groupChatApiMessages(
      speaker: lead,
      agents: org,
      history: history,
    );
    expect(messages.length, 2);
    expect(messages.last['content'], 'hi');
  });

  test('按配置 ID 选 API，找不到才回退', () {
    final profiles = [
      const ApiProfile(
        id: 'p1',
        name: 'DeepSeek',
        baseUrl: 'https://api.deepseek.com',
        model: 'deepseek-chat',
      ),
      const ApiProfile(
        id: 'p2',
        name: 'OpenRouter',
        baseUrl: 'https://openrouter.ai/api/v1',
        model: 'openrouter/auto',
      ),
    ];
    expect(
      groupChatProfileFor(
        agent(id: 'a', name: 'A', apiProfileId: 'p2'),
        profiles,
      )?.name,
      'OpenRouter',
    );
    expect(
      groupChatProfileFor(
        agent(id: 'a', name: 'A', apiProfileId: 'missing'),
        profiles,
        fallback: profiles.first,
      )?.name,
      'DeepSeek',
    );
  });

  test('群聊头像取名字第一个字', () {
    expect(groupAgentInitial('拾忆'), '拾');
    expect(groupAgentInitial('  Bob'), 'B');
    expect(groupAgentInitial('   ', '1'), '1');
  });
}
