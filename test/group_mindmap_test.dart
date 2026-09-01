import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/group_mindmap.dart';

const mermaidFlat = r'''
mindmap  root((AI小说写作流水线))    总体架构      主控模式：一切经主编      流水线：环节串行、写手并行      质量门禁：不合格打回、上限N次    Agent角色      主编/总控        唯一入口·调度·最终放行      策划        选题与可出版性评估      设定师        大纲/人物/世界观        全书唯一事实源      写手A        卷一写作      写手B        卷二写作      结构审        逻辑/伏笔/人物一致性      润色        病句/风格统一      校对        错别字/体例 硬指标      合规审        违禁/抄袭 独立终审    流程主线      用户→主编      策划选题      设定师产出大纲      写手A/B 并行      结构审→润色      校对→合规审      成稿达到出版要求    对接规则      用户只对接主编      写手只对接大纲和主编      高频对：写手↔结构审      打回意见经主编路由      合规审独立串行    质量门禁      大纲完整/主线闭合      章节忠于大纲      逻辑自洽/无烂尾      零错别字/体例规范      无违禁/无抄袭    工程要点      设定文档外部化      审查读摘要+关键章节      终止条件：打回N次交用户    起步路线      最小可用4个      主编+写手+结构审+校对      完整版8个
''';

const mermaidPretty = r'''
mindmap
  root((AI小说写作流水线))
    总体架构
      主控模式：一切经主编
      流水线：环节串行、写手并行
      质量门禁：不合格打回、上限N次
    Agent角色
      主编/总控
        唯一入口·调度·最终放行
      策划
        选题与可出版性评估
      设定师
        大纲/人物/世界观
        全书唯一事实源
      写手A
        卷一写作
      写手B
        卷二写作
      结构审
        逻辑/伏笔/人物一致性
      润色
        病句/风格统一
      校对
        错别字/体例 硬指标
      合规审
        违禁/抄袭 独立终审
    流程主线
      用户→主编
    对接规则
      用户只对接主编
      写手只对接大纲和主编
      合规审独立串行
    起步路线
      最小可用4个
      主编+写手+结构审+校对
      完整版8个
''';

const asciiMap = r'''
                    ┌─ 主控模式：一切经主编
        ┌─ 总体架构 ─┼─ 流水线：环节串行、写手并行
        │           └─ 质量门禁：不合格打回、上限N次
        │
        │           ┌─ 主编/总控 ── 唯一入口·调度·放行
        │           ├─ 策划 ── 选题/可出版性
        ├─ Agent ───┼─ 设定师 ── 大纲/人物/世界观（唯一事实源）
        │  角色      ├─ 写手A ── 卷一写作
        │           ├─ 写手B ── 卷二写作（与A并行）
        │           ├─ 结构审 ── 逻辑/伏笔/一致性
        │           ├─ 润色 ── 病句/风格统一
        │           ├─ 校对 ── 零错别字/体例（硬指标）
        │           └─ 合规审 ── 违禁/抄袭（独立终审）
        │
AI 小说写作 ── 流程主线 ── 用户 → 主编 → 策划 → 设定师
  流水线           └─ 写手A/B（并行）→ 结构审 → 润色
                  └─ 校对 → 合规审 → 成稿
        │
        │           ┌─ 用户只对接主编
        ├─ 对接规则 ─┼─ 写手只对接大纲和主编
        │           ├─ 高频对：写手 ↔ 结构审
        │           ├─ 打回意见经主编路由
        │           └─ 合规审独立串行、不可自查
        │
        └─ 起步路线 ── 最小4个（主编+写手+结构审+校对）
                     └─ 完整8个（全角色）
''';

void main() {
  test('扁平 mermaid 认出角色、人设、最小四人', () {
    final parsed = parseGroupMindmap(mermaidFlat);
    expect(parsed.title, 'AI小说写作流水线');
    expect(parsed.agents.map((a) => a.name).toList(), [
      '主编',
      '策划',
      '设定师',
      '写手A',
      '写手B',
      '结构审',
      '润色',
      '校对',
      '合规审',
    ]);
    expect(parsed.agents.first.title, '总控');
    expect(parsed.agents.first.persona, contains('唯一入口'));
    expect(
      parsed.agents.firstWhere((a) => a.name == '设定师').persona,
      contains('全书唯一事实源'),
    );
    expect(parsed.minimalNames, ['主编', '写手', '结构审', '校对']);
    expect(parsed.agentsFor(minimal: true).map((a) => a.name).toList(), [
      '主编',
      '写手A',
      '结构审',
      '校对',
    ]);
  });

  test('标准缩进 mermaid 也能认', () {
    final parsed = parseGroupMindmap(mermaidPretty);
    expect(parsed.agents, hasLength(9));
    expect(parsed.agents.first.name, '主编');
    expect(parsed.agents[2].duties, contains('全书唯一事实源'));
  });

  test('字符图认出同一批 Agent，用户只对接主编', () {
    final parsed = parseGroupMindmap(asciiMap);
    expect(
      parsed.agents.map((a) => a.name),
      containsAll(['主编', '策划', '写手A', '合规审']),
    );
    expect(parsed.agents, hasLength(9));
    final agents = parsed.toGroupAgents(
      roomId: 'g1',
      apiProfileId: 'p1',
      model: 'm1',
    );
    final lead = agents.firstWhere((a) => a.name == '主编');
    expect(lead.reportsToId, isEmpty);
    expect(lead.apiProfileId, 'p1');
    expect(lead.model, 'm1');
    final writer = agents.firstWhere((a) => a.name == '写手A');
    expect(writer.reportsToId, lead.id);
    expect(writer.persona, contains('卷一写作'));
    expect(writer.persona, contains('用户只对接主编'));
  });

  test('空文本不崩', () {
    expect(parseGroupMindmap('').isEmpty, isTrue);
    expect(parseGroupMindmap('hello world').isEmpty, isTrue);
  });

  test('5 字职位角色可识别，多级汇报不全部压给主编', () {
    const raw = r'''
mindmap
  root((写作流水线))
    Agent角色
      主编/负责人
        唯一入口
      策划/选题
        选题评估
      设定师/创作组组长
        唯一事实源
      写手A/卷写手
        卷一写作
      写手B/卷写手
        卷二写作
      结构审/质量组组长
        逻辑一致性
      润色/文字编辑
        风格统一
      校对/质量门
        零错别字
      合规审/终审
        独立终审
    对接规则
      用户只对接主编
      策划只对接主编
      设定师只对接主编
      结构审只对接主编
      合规审只对接主编
      写手A只对接设定师
      写手B只对接设定师
      润色只对接结构审
      校对只对接结构审
    起步路线
      最小可用4个
      主编+写手+结构审+校对
''';
    final parsed = parseGroupMindmap(raw);
    expect(parsed.agents, hasLength(9));
    expect(parsed.agents.firstWhere((a) => a.name == '设定师').title, '创作组组长');
    expect(parsed.agents.firstWhere((a) => a.name == '结构审').title, '质量组组长');

    final agents = parsed.toGroupAgents(
      roomId: 'g1',
      apiProfileId: 'p1',
      model: 'm1',
    );
    final byId = {for (final a in agents) a.id: a.name};
    String boss(String name) {
      final a = agents.firstWhere((x) => x.name == name);
      return byId[a.reportsToId] ?? '(root)';
    }

    expect(boss('主编'), '(root)');
    expect(boss('策划'), '主编');
    expect(boss('设定师'), '主编');
    expect(boss('结构审'), '主编');
    expect(boss('合规审'), '主编');
    expect(boss('写手A'), '设定师');
    expect(boss('写手B'), '设定师');
    expect(boss('润色'), '结构审');
    expect(boss('校对'), '结构审');
  });

  test('内置最小模板能识别主编+写手，写手上报主编', () {
    final parsed = parseGroupMindmap(groupMindmapMinimalTemplate);
    expect(parsed.agents.map((a) => a.name).toList(), ['主编', '写手A']);
    expect(parsed.agents.first.title, '负责人');
    expect(parsed.minimalNames, ['主编', '写手']);
    final agents = parsed.toGroupAgents(
      roomId: 'g1',
      apiProfileId: 'p1',
      model: 'm1',
    );
    final lead = agents.firstWhere((a) => a.name == '主编');
    final writer = agents.firstWhere((a) => a.name == '写手A');
    expect(lead.reportsToId, isEmpty);
    expect(writer.reportsToId, lead.id);
  });

  test('常见格式偏差可以容错识别', () {
    const raw = '''
mindmap
\troot((格式容错))
  成员
    主编负责人
      唯一入口
    开发组
      程序员A：专项模块开发
        1周产出3章
      前端界面
        页面开发
      后端服务
        服务开发
    超长职位负责人/一个特别长的职业名称也没有限制
        编号 [1] {重要}

  汇报
\t用户只对接主编负责人
    程序员A只对接超长职位负责人、主编负责人
      前端界面↔后端服务
  起步
    最小2个
    主编负责人+程序员A
''';
    final parsed = parseGroupMindmap(raw);

    expect(parsed.agents.map((a) => a.name).toList(), [
      '主编负责人',
      '程序员A',
      '前端界面',
      '后端服务',
      '超长职位负责人',
    ]);
    expect(parsed.agents.firstWhere((a) => a.name == '程序员A').title, '专项模块开发');
    expect(parsed.agents.firstWhere((a) => a.name == '程序员A').duties, [
      '1周产出3章',
    ]);
    expect(
      parsed.agents.firstWhere((a) => a.name == '超长职位负责人').title,
      '一个特别长的职业名称也没有限制',
    );
    expect(parsed.agents.firstWhere((a) => a.name == '超长职位负责人').duties, [
      '编号 [1] {重要}',
    ]);
    expect(
      parsed.rules,
      containsAll([
        '用户只对接主编负责人',
        '程序员A只对接超长职位负责人',
        '程序员A只对接主编负责人',
        '前端界面只对接后端服务',
        '后端服务只对接前端界面',
      ]),
    );
    expect(parsed.minimalNames, ['主编负责人', '程序员A']);
    expect(parsed.agentsFor(minimal: true).map((a) => a.name).toList(), [
      '主编负责人',
      '程序员A',
    ]);
  });
}
