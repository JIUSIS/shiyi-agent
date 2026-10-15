import 'dart:convert';

import 'package:flutter/material.dart';

import 'code_change.dart';
import 'models.dart';

const groupAgentPalette = <Color>[
  Color(0xFF0A84FF),
  Color(0xFF34C759),
  Color(0xFFFF9F0A),
  Color(0xFFFF375F),
  Color(0xFFAF52DE),
  Color(0xFF64D2FF),
  Color(0xFFFFD60A),
  Color(0xFF30B0C7),
];

const groupChatMaxReworksPerHandoff = 3;

/// 层级屏障：一批（wave）只装同一层「被叫到」的成员，整批全部汇报完，
/// 上一级才会被叫起来。并行度 = 这一批的人数（不再有 3 线程上限）。
/// 见 docs/fix-log.md #404。
class GroupChatFollowup {
  final GroupAgent speaker;
  final GroupAgent target;
  final bool isRework;

  /// 由 @点名 产生（派活给同级/下属）；false = 汇报给直接上级。
  final bool isMention;

  const GroupChatFollowup({
    required this.speaker,
    required this.target,
    this.isRework = false,
    this.isMention = true,
  });

  String get handoffKey => '${speaker.id}>${target.id}';
}

int _groupChatIdSeq = 0;

String groupChatNewId(String prefix) {
  _groupChatIdSeq += 1;
  return '$prefix${DateTime.now().microsecondsSinceEpoch}$_groupChatIdSeq';
}

String groupAgentInitial(String name, [String fallback = 'A']) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return fallback;
  return String.fromCharCode(trimmed.runes.first);
}

class GroupRoom {
  final String id;
  String title;
  final int createdAt;
  int updatedAt;
  int sortOrder;
  List<GroupAgent> agents;
  String lastMessage;

  /// 所属项目文件夹 id；空 = 未分类。
  String projectId;

  GroupRoom({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.sortOrder = 0,
    List<GroupAgent>? agents,
    this.lastMessage = '',
    this.projectId = '',
  }) : agents = agents ?? [];

  Map<String, dynamic> toMap() => {
    'id': id,
    'title': title,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'sort_order': sortOrder,
    'project_id': projectId,
  };

  factory GroupRoom.fromMap(Map<String, dynamic> m) => GroupRoom(
    id: (m['id'] ?? '').toString(),
    title: (m['title'] ?? '').toString(),
    createdAt: _toInt(m['created_at']),
    updatedAt: _toInt(m['updated_at']),
    sortOrder: _toInt(m['sort_order']),
    projectId: (m['project_id'] ?? '').toString(),
  );
}

class GroupAgent {
  final String id;
  final String roomId;
  String name;
  String title;
  String persona;
  String apiProfileId;
  String model;
  String reportsToId;
  int colorIndex;
  int sortOrder;

  GroupAgent({
    required this.id,
    required this.roomId,
    required this.name,
    this.title = '',
    this.persona = '',
    this.apiProfileId = '',
    this.model = '',
    this.reportsToId = '',
    this.colorIndex = 0,
    this.sortOrder = 0,
  });

  Color get color =>
      groupAgentPalette[colorIndex.abs() % groupAgentPalette.length];

  bool get talksToUser {
    final supervisor = reportsToId.trim();
    return supervisor.isEmpty;
  }

  String get displayRole {
    final role = title.trim();
    if (role.isNotEmpty) return role;
    return talksToUser ? '对接用户' : '成员';
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'room_id': roomId,
    'name': name,
    'title': title,
    'persona': persona,
    'api_profile_id': apiProfileId,
    'model': model,
    'reports_to': reportsToId,
    'color': colorIndex,
    'sort_order': sortOrder,
  };

  factory GroupAgent.fromMap(Map<String, dynamic> m) => GroupAgent(
    id: (m['id'] ?? '').toString(),
    roomId: (m['room_id'] ?? '').toString(),
    name: (m['name'] ?? '').toString(),
    title: (m['title'] ?? '').toString(),
    persona: (m['persona'] ?? '').toString(),
    apiProfileId: (m['api_profile_id'] ?? '').toString(),
    model: (m['model'] ?? '').toString(),
    reportsToId: (m['reports_to'] ?? '').toString(),
    colorIndex: _toInt(m['color']),
    sortOrder: _toInt(m['sort_order']),
  );

  GroupAgent copyWith({
    String? name,
    String? title,
    String? persona,
    String? apiProfileId,
    String? model,
    String? reportsToId,
    int? colorIndex,
    int? sortOrder,
  }) => GroupAgent(
    id: id,
    roomId: roomId,
    name: name ?? this.name,
    title: title ?? this.title,
    persona: persona ?? this.persona,
    apiProfileId: apiProfileId ?? this.apiProfileId,
    model: model ?? this.model,
    reportsToId: reportsToId ?? this.reportsToId,
    colorIndex: colorIndex ?? this.colorIndex,
    sortOrder: sortOrder ?? this.sortOrder,
  );
}

/// 群聊成员的一次工具调用（显示在成员气泡里，见 docs/fix-log.md #410）。
class GroupToolCall {
  final String name;
  final String argsSummary;

  /// 写入类工具放「代码改动预览」，其余放输出摘要。
  String summary;

  /// **完整**入参（JSON）与完整输出，只在调用日志里用（不截断）。
  String argsJson;
  String result;
  bool ok;
  bool done;

  GroupToolCall({
    required this.name,
    this.argsSummary = '',
    this.summary = '',
    this.argsJson = '',
    this.result = '',
    this.ok = true,
    this.done = false,
  });

  Map<String, dynamic> toMap() => {
    'name': name,
    'args': argsSummary,
    'summary': summary,
    'args_json': argsJson,
    'result': result,
    'ok': ok,
    'done': done,
  };

  factory GroupToolCall.fromMap(Map<dynamic, dynamic> m) => GroupToolCall(
    name: (m['name'] ?? '').toString(),
    argsSummary: (m['args'] ?? '').toString(),
    summary: (m['summary'] ?? '').toString(),
    argsJson: (m['args_json'] ?? '').toString(),
    result: (m['result'] ?? '').toString(),
    ok: m['ok'] != false,
    done: m['done'] == true,
  );
}

/// Result emitted for each assistant turn.
class GroupMessage {
  final String id;
  final String roomId;
  final String role; // user | agent
  final String agentId;
  String content;
  String reasoning;
  final int createdAt;
  bool streaming;

  /// 这个成员这一轮调用过的工具（含写入类工具的代码改动预览）。
  List<GroupToolCall> toolCalls;

  GroupMessage({
    required this.id,
    required this.roomId,
    required this.role,
    this.agentId = '',
    this.content = '',
    this.reasoning = '',
    required this.createdAt,
    this.streaming = false,
    List<GroupToolCall>? toolCalls,
  }) : toolCalls = toolCalls ?? [];

  bool get isUser => role == 'user';

  Map<String, dynamic> toMap() => {
    'id': id,
    'room_id': roomId,
    'role': role,
    'agent_id': agentId,
    'content': content,
    'reasoning': reasoning,
    'created_at': createdAt,
    'tool_calls': jsonEncode([
      for (final call in toolCalls) call.toMap(),
    ]),
  };

  factory GroupMessage.fromMap(Map<String, dynamic> m) => GroupMessage(
    id: (m['id'] ?? '').toString(),
    roomId: (m['room_id'] ?? '').toString(),
    role: (m['role'] ?? 'user').toString(),
    agentId: (m['agent_id'] ?? '').toString(),
    content: (m['content'] ?? '').toString(),
    reasoning: (m['reasoning'] ?? '').toString(),
    createdAt: _toInt(m['created_at']),
    toolCalls: _parseGroupToolCalls(m['tool_calls']),
  );
}

List<GroupToolCall> _parseGroupToolCalls(Object? raw) {
  final text = (raw ?? '').toString().trim();
  if (text.isEmpty) return [];
  try {
    final decoded = jsonDecode(text);
    if (decoded is! List) return [];
    return [
      for (final item in decoded)
        if (item is Map) GroupToolCall.fromMap(item),
    ];
  } catch (_) {
    return [];
  }
}

int _toInt(Object? value) {
  if (value is int) return value;
  return int.tryParse('$value') ?? 0;
}

String groupChatRoomSubtitle(GroupRoom room) {
  if (room.lastMessage.trim().isNotEmpty) return room.lastMessage.trim();
  final facing = groupChatUserFacingAgents(room.agents);
  final names = [
    for (final agent in facing)
      if (agent.name.trim().isNotEmpty) agent.name.trim(),
  ];
  if (names.isEmpty) return '${room.agents.length} 个 Agent';
  return '${names.join('、')} 对接 · ${room.agents.length} 人';
}

GroupAgent? groupChatAgentById(String id, List<GroupAgent> agents) {
  for (final agent in agents) {
    if (agent.id == id) return agent;
  }
  return null;
}

List<GroupAgent> groupChatReportsOf(String id, List<GroupAgent> agents) => [
  for (final agent in agents)
    if (agent.reportsToId.trim() == id) agent,
];

/// 去掉指向自己、不存在的上级，以及环路。
List<GroupAgent> groupChatSanitizeOrg(List<GroupAgent> agents) {
  if (agents.isEmpty) return const [];
  final ids = {for (final agent in agents) agent.id};
  final reports = <String, String>{
    for (final agent in agents)
      agent.id: () {
        final parent = agent.reportsToId.trim();
        if (parent.isEmpty || parent == agent.id || !ids.contains(parent)) {
          return '';
        }
        return parent;
      }(),
  };
  for (final id in reports.keys) {
    final seen = <String>{id};
    var parent = reports[id] ?? '';
    while (parent.isNotEmpty) {
      if (seen.contains(parent)) {
        reports[id] = '';
        break;
      }
      seen.add(parent);
      parent = reports[parent] ?? '';
    }
  }
  return [
    for (final agent in agents)
      agent.copyWith(reportsToId: reports[agent.id] ?? ''),
  ];
}

bool groupChatCanReportTo(
  GroupAgent agent,
  GroupAgent candidate,
  List<GroupAgent> agents,
) {
  if (agent.id == candidate.id) return false;
  var parent = candidate.reportsToId.trim();
  final seen = <String>{candidate.id};
  while (parent.isNotEmpty) {
    if (parent == agent.id) return false;
    if (!seen.add(parent)) break;
    parent = groupChatAgentById(parent, agents)?.reportsToId.trim() ?? '';
  }
  return true;
}

List<GroupAgent> groupChatUserFacingAgents(List<GroupAgent> agents) {
  final sanitized = groupChatSanitizeOrg(agents);
  final facing = [
    for (final agent in sanitized)
      if (agent.reportsToId.trim().isEmpty) agent,
  ];
  if (facing.isNotEmpty) return facing;
  return List<GroupAgent>.of(sanitized);
}

/// 解析 @名字。长名优先，避免 @Alice 误伤 Al。
List<GroupAgent> groupChatMentionedAgents(
  String text,
  List<GroupAgent> agents,
) {
  if (agents.isEmpty) return const [];
  final mentioned = <String>{};
  final ordered = [...agents]
    ..sort((a, b) => b.name.trim().length.compareTo(a.name.trim().length));
  var remaining = text;
  for (final agent in ordered) {
    final name = agent.name.trim();
    if (name.isEmpty) continue;
    final token = '@$name';
    if (!remaining.contains(token)) continue;
    mentioned.add(agent.id);
    remaining = remaining.replaceAll(token, '');
  }
  return [
    for (final agent in agents)
      if (mentioned.contains(agent.id)) agent,
  ];
}

/// 条件/顺序标记：出现在同一条子句里时，@ 到的名字只是「以后再说」，
/// 不是现在就启动（例：「审核通过后再让 @2 实现」）。
final _groupChatSequenceMarkers = RegExp(
  '通过后|通过之后|审核后|审批后|验收后|确认后|批准后|完成后|做完后|之后再|然后|接着|'
  '以后再|再让|再叫|再去|再次|等[^，。；\\n]{0,8}(后|再)|如果|一旦|假如|若是|待|'
  '先[^，。；\\n]{0,8}再|没问题再|后续',
);

/// 「动作对象」标记：紧挨在 @ 名字前面时，说的是「关于他/他的东西」，
/// 不是在叫他动手（例：「@1 审核 @2 的方案」）。
final _groupChatObjectMarkers = RegExp(
  r'(审核|审批|验收|检查|评估|查看|参考|针对|关于|依据|复核|校对|过一遍)'
  r'|(的方案|的报告|的代码|的结果|的需求|的结论|的产出|的意见|的设计|的文档)$',
);

const _groupChatClauseBreaks = '，。；！？、\n';

/// 文档结构标记：正文里一旦出现这种小标题/列表，后面的 @ 就是**文档内容**
/// 而不是指派（例：用户只 @了经理，后面整段是给经理看的需求文档）。
final _groupChatDocumentMarkers = RegExp(
  r'(\n\s*[-*•]\s*'
  r'|\n\s*\d+[.、)]\s*'
  r'|\*\*[^*\n]{1,16}\*\*\s*[:：]'
  r'|(需求|约束|建议|方案|步骤|计划|规范|说明|要求|背景|目标|验收|交付)\s*[:：])',
);

/// 子句终点：往前找到句读/换行为止。
int _groupChatClauseEnd(String text, int index) {
  var end = index;
  while (end < text.length && !_groupChatClauseBreaks.contains(text[end])) {
    end++;
  }
  return end;
}

/// 这次发言里**真正要现在启动**的被 @ 成员。
///
/// 规则（见 docs/fix-log.md #408 / #409）：
/// 1. 子句里带条件/顺序标记（「审核通过后再让 @乙 实现」）→ 引用，不启动。
/// 2. 名字紧跟在「审核/检查…」「…的方案」这类词后面 → 动作对象，不启动。
/// 3. **文档体**：消息开头已经点了收件人，且后面出现小标题/列表（`**需求**：`、
///    `- 棒1 …`）→ 此后正文里的 @ 全是文档内容，不启动（只启动开头那个人）。
/// 4. 其余照旧：文本里 @ 到的名字都算指派（`这个 bug @开发 看一下`、
///    `请 @甲 和 @乙 一起做`、`打回：@开发 修边界` 都不受影响）。
List<GroupAgent> groupChatDirectCallMentions(
  String text,
  List<GroupAgent> agents,
) {
  if (text.isEmpty || agents.isEmpty) return const [];
  final mentioned = groupChatMentionedAgents(text, agents);
  if (mentioned.isEmpty) return const [];

  final active = <String, int>{}; // 成员 id → 第一次被指派的位置
  var firstAt = -1;

  var cursor = 0;
  while (cursor < text.length) {
    final end = _groupChatClauseEnd(text, cursor);
    final clause = text.substring(cursor, end);
    // 条件/顺序子句里的 @ 只是引用。
    if (!_groupChatSequenceMarkers.hasMatch(clause)) {
      for (final agent in mentioned) {
        final name = agent.name.trim();
        if (name.isEmpty) continue;
        final token = '@$name';
        var index = clause.indexOf(token);
        while (index >= 0) {
          final position = cursor + index;
          final before = text.substring(cursor, position);
          final tail = before.length > 8
              ? before.substring(before.length - 8)
              : before;
          // 动作对象位置的名字不算指派。
          if (!_groupChatObjectMarkers.hasMatch(tail.trim())) {
            if (firstAt < 0) firstAt = position;
            active.putIfAbsent(agent.id, () => position);
          }
          index = clause.indexOf(token, index + token.length);
        }
      }
    }
    cursor = end + 1;
  }

  // 文档体：开头点了收件人，后面又是小标题/列表 → 后面的 @ 降级为文档内容。
  if (firstAt >= 0 && active.length > 1) {
    final rest = text.substring(firstAt);
    if (_groupChatDocumentMarkers.hasMatch(rest)) {
      active.removeWhere((_, position) => position > firstAt);
    }
  }

  return [
    for (final agent in mentioned)
      if (active.containsKey(agent.id)) agent,
  ];
}

/// 用户发言：点名优先，否则只找对接用户的人。
///
/// 「@ 到名字」不等于「现在就启动」：条件/顺序子句里的名字、「文档体」里的名字、
/// 动作对象位置的名字都只是引用，该成员等被真正叫到时再动。
List<GroupAgent> groupChatInitialTargets(String text, List<GroupAgent> agents) {
  final mentioned = groupChatMentionedAgents(text, agents);
  if (mentioned.isEmpty) return groupChatUserFacingAgents(agents);
  final direct = groupChatDirectCallMentions(text, agents);
  if (direct.isNotEmpty) return direct;
  // 全是「引用」时别把所有人拉起来：交给对接用户的负责人判断怎么走。
  return groupChatUserFacingAgents(agents);
}

/// 某成员说完后：先听 @点名；没点名且有上级，则向上级汇报。
List<GroupChatFollowup> groupChatFollowupTargets({
  required GroupAgent speaker,
  required String reply,
  required List<GroupAgent> agents,
}) {
  final mentioned = [
    // 成员之间的 @ 同样区分「现在指派」和「以后再说」：条件子句里的名字
    // 不启动，等真正被叫到（见 docs/fix-log.md #408）。
    for (final agent in groupChatDirectCallMentions(reply, agents))
      if (agent.id != speaker.id)
        GroupChatFollowup(
          speaker: speaker,
          target: agent,
          isRework: groupChatIsReworkReply(reply),
        ),
  ];
  if (mentioned.isNotEmpty) return mentioned;
  final supervisorId = speaker.reportsToId.trim();
  if (supervisorId.isEmpty) return const [];
  final supervisor = groupChatAgentById(supervisorId, agents);
  if (supervisor == null || supervisor.id == speaker.id) return const [];
  return [
    for (final agent in agents)
      if (agent.id == supervisorId)
        GroupChatFollowup(
          speaker: speaker,
          target: agent,
          isMention: false,
        ),
  ];
}

bool groupChatIsReworkReply(String reply) {
  final text = reply.trim();
  return text.startsWith('打回') ||
      RegExp(r'(^|\n)\s*(?:【打回】|打回)\s*[:：]?').hasMatch(text);
}

/// 一批并行回复结束后，计算去重后的下一批成员。
/// 多个下属都汇报给同一位上级时，上级只排一次。
List<GroupChatFollowup> groupChatNextFollowupTargets({
  required List<GroupAgent> speakers,
  required List<GroupMessage?> replies,
  required List<GroupAgent> agents,
}) {
  final seen = <String>{};
  final next = <GroupChatFollowup>[];
  for (var index = 0; index < speakers.length; index++) {
    final speaker = speakers[index];
    final reply = replies.length > index ? replies[index] : null;
    if (reply == null) continue;
    for (final target in groupChatFollowupTargets(
      speaker: speaker,
      reply: reply.content,
      agents: agents,
    )) {
      if (!seen.add(target.target.id)) continue;
      next.add(target);
    }
  }
  return next;
}

/// 层级行动调度器（群聊一次用户发言 = 一轮）。
///
/// 规则（用户口径）：
/// 1. 只有被叫到的人启动；用户没点名时只叫对接用户的那一层（领导）。
/// 2. **一批 = 同一层被叫到的人**，全部并行（叫 5 个人就 5 条线程，不再砍成 3）。
/// 3. **屏障**：这一批每个人汇报完，才轮到下一批；上级不会被下属的半成品提前拉起来。
/// 4. 领导派活用 @下属（可指定一个/几个/全体）；下属全部汇报完，领导才会再次被叫起来。
/// 5. 同一交接环节的打回最多 [groupChatMaxReworksPerHandoff] 次。
class GroupRoundScheduler {
  GroupRoundScheduler({
    required List<GroupAgent> agents,
    required List<GroupAgent> initialTargets,
  }) : _agents = groupChatSanitizeOrg(agents) {
    _wave = _activateAll(initialTargets);
    _finished = _wave.isEmpty;
  }

  /// 正常推进不设轮次上限；这两个只是互相 @ 死循环的安全阀。
  static const maxWaves = 40;
  static const maxActivationsPerAgent = 8;

  /// 负责人「自己把活干了」的判定线：回复超过这么多字，就认为它没派活而是
  /// 自己动手了 → 提醒一次。短回复（「收到，待命」）不提醒。
  static const delegateNudgeMinChars = 60;

  final List<GroupAgent> _agents;
  List<GroupAgent> _wave = const [];
  bool _finished = false;
  int _waves = 0;
  int _emptySpins = 0;

  /// 上级 id → 已激活、尚未汇报完的直接下属 id。
  final Map<String, Set<String>> _pending = {};

  /// 被下属汇报过、但还在等其它下属的上级 id。
  final Set<String> _requested = {};

  /// 想启动、但自己的下属还在跑，被屏障压住等着的成员 id。
  final Set<String> _deferred = {};

  final Map<String, int> _activations = {};
  final Map<String, int> _reworkCounts = {};

  /// 本轮已经派过活的负责人（之后它再直接汇报就是合法的）。
  final Set<String> _delegated = {};

  /// 本轮已经提醒过「该派活」的负责人（每人每轮最多一次）。
  final Set<String> _nudged = {};

  /// 当前这批里带「派活提醒」的成员。
  final Set<String> _nudgeWave = {};

  /// 当前这一批要并行跑的成员（可能为空）。
  List<GroupAgent> get wave => _wave;

  bool get hasWave => !_finished && _wave.isNotEmpty;
  bool get finished => _finished;
  int get waveIndex => _waves;

  /// 这一批里某个人是否是「派活提醒」轮（提示词不同）。
  bool isNudge(String agentId) => _nudgeWave.contains(agentId);

  String supervisorIdOf(GroupAgent agent) {
    final self = groupChatAgentById(agent.id, _agents) ?? agent;
    return self.reportsToId.trim();
  }

  /// 这一批全部跑完后调用，算下一批。
  void complete({required List<GroupMessage?> replies}) {
    if (_finished) return;
    final speakers = _wave;
    var progressed = false;
    for (var index = 0; index < speakers.length; index++) {
      final reply = index < replies.length ? replies[index] : null;
      if (reply == null) continue;
      if (reply.content.trim().isNotEmpty ||
          reply.reasoning.trim().isNotEmpty) {
        progressed = true;
      }
    }

    // 1) 结算本批：从上级 pending 里划掉；没有 @别人 = 在向上汇报。
    final followups = groupChatNextFollowupTargets(
      speakers: speakers,
      replies: replies,
      agents: _agents,
    );
    // 1) 结算本批。关键：**派了活的人还算「在飞」** —— 它的子树没汇报完，
    //    它的上级就不许启动（否则会重现「组员和组长同批」）。只有真正向上
    //    汇报（没有 @ 派活）的人，才从上级 pending 划掉并请求上级。
    final assigningSpeakers = <String>{};
    for (final followup in followups) {
      if (!followup.isMention) continue;
      // @自己的上级 = 汇报，不算派活。
      if (followup.target.id == supervisorIdOf(followup.speaker)) continue;
      assigningSpeakers.add(followup.speaker.id);
    }
    _delegated.addAll(assigningSpeakers);
    final nudgeNext = <GroupAgent>[];
    for (var index = 0; index < speakers.length; index++) {
      final speaker = speakers[index];
      if (assigningSpeakers.contains(speaker.id)) continue;
      final reply = index < replies.length ? replies[index] : null;
      final wrote =
          (reply?.content.trim().length ?? 0) >= delegateNudgeMinChars;
      final hasReports = groupChatReportsOf(speaker.id, _agents).isNotEmpty;
      // 有下属、本轮还没派过活、也没提醒过，却自己把活写了 → 提醒一次。
      if (hasReports &&
          wrote &&
          !_delegated.contains(speaker.id) &&
          !_nudged.contains(speaker.id)) {
        _nudged.add(speaker.id);
        nudgeNext.add(speaker);
        continue; // 仍在飞：不许把它的上级拉起来
      }
      final supervisorId = supervisorIdOf(speaker);
      if (supervisorId.isEmpty) continue;
      _pending[supervisorId]?.remove(speaker.id);
      _requested.add(supervisorId);
    }

    // 2) 收集候选：派活提醒优先，其次 @点名的人（派活），最后是被汇报过、
    //    且下属已清空的上级。
    final candidates = <String, GroupAgent>{};
    final nudgeIds = {for (final agent in nudgeNext) agent.id};
    for (final agent in nudgeNext) {
      candidates[agent.id] = agent;
    }
    for (final followup in followups) {
      if (!followup.isMention) continue;
      if (followup.isRework) {
        final count =
            (_reworkCounts[followup.handoffKey] ?? 0) + 1;
        _reworkCounts[followup.handoffKey] = count;
        if (count > groupChatMaxReworksPerHandoff) continue;
      }
      candidates[followup.target.id] = followup.target;
    }
    for (final supervisorId in {..._requested, ..._deferred}) {
      if ((_pending[supervisorId] ?? const <String>{}).isNotEmpty) continue;
      final supervisor = groupChatAgentById(supervisorId, _agents);
      if (supervisor == null) continue;
      candidates[supervisor.id] = supervisor;
      _requested.remove(supervisorId);
      _deferred.remove(supervisorId);
    }

    _waves++;
    if (!progressed) {
      _emptySpins++;
    } else {
      _emptySpins = 0;
    }
    if (_emptySpins >= 3 || _waves >= maxWaves) {
      _finished = true;
      _wave = const [];
      return;
    }

    final next = _activateAll(candidates.values.toList());
    _wave = next;
    if (next.isEmpty) {
      // 没算出下一批：把「下属已清空但还没被请求」的等待者放行，彻底没得跑就收尾。
      final stuck = [
        for (final id in {..._requested, ..._deferred})
          if ((_pending[id] ?? const <String>{}).isEmpty)
            if (_canActivate(id)) groupChatAgentById(id, _agents),
      ].whereType<GroupAgent>().toList();
      if (stuck.isNotEmpty) {
        for (final agent in stuck) {
          _requested.remove(agent.id);
          _deferred.remove(agent.id);
        }
        _wave = _activateAll(stuck);
      }
    }
    _finished = _wave.isEmpty;
    _nudgeWave
      ..clear()
      ..addAll([
        for (final agent in _wave)
          if (nudgeIds.contains(agent.id)) agent.id,
      ]);
  }

  bool _canActivate(String agentId) =>
      (_activations[agentId] ?? 0) < maxActivationsPerAgent;

  /// 激活一批：自己的直接下属还在跑的人先压进 [_deferred]，等下属清空。
  List<GroupAgent> _activateAll(List<GroupAgent> targets) {
    final out = <GroupAgent>[];
    final seen = <String>{};
    for (final agent in targets) {
      final self = groupChatAgentById(agent.id, _agents) ?? agent;
      if (!seen.add(self.id)) continue;
      if (!_canActivate(self.id)) continue;
      if ((_pending[self.id] ?? const <String>{}).isNotEmpty) {
        _deferred.add(self.id);
        continue;
      }
      final supervisorId = self.reportsToId.trim();
      if (supervisorId.isNotEmpty) {
        (_pending[supervisorId] ??= <String>{}).add(self.id);
      }
      _activations[self.id] = (_activations[self.id] ?? 0) + 1;
      _deferred.remove(self.id);
      out.add(self);
    }
    return out;
  }
}

/// 负责人「自己开干、不派活」时的提醒词。
///
/// 只进这一次请求的动尾，不写进库里（聊天记录看不到这条系统提醒）。
String groupChatDelegateNudge(GroupAgent agent, List<GroupAgent> agents) {
  final reports = groupChatReportsOf(agent.id, groupChatSanitizeOrg(agents));
  final names = [
    for (final item in reports)
      if (item.name.trim().isNotEmpty) '@${item.name.trim()}',
  ];
  return '【系统提醒】你是这条线的负责人，你的下属：${names.isEmpty ? '（无）' : names.join('、')}。'
      '你刚才没有派活，直接自己动手了。请立刻把这件事拆成可执行的子任务，用 @名字 派给具体下属'
      '（可以只点一个、点几个，或拆成几份同时点所有下属，他们会各自并行处理）。'
      '如果你判断这件事确实不需要派人，就直接给出结论，并一句话说明为什么不用派人。';
}

String groupChatSystemPrompt(GroupAgent agent, List<GroupAgent> all) {
  final sanitized = groupChatSanitizeOrg(all);
  final self = groupChatAgentById(agent.id, sanitized) ?? agent;
  final persona = self.persona.trim();
  final personaBlock = persona.isEmpty ? '没有额外人设，按自己的名字和职位自然交流。' : persona;
  final supervisor = groupChatAgentById(self.reportsToId.trim(), sanitized);
  final reports = [
    for (final item in groupChatReportsOf(self.id, sanitized))
      if (item.name.trim().isNotEmpty)
        item.title.trim().isEmpty
            ? item.name.trim()
            : '${item.name.trim()}（${item.title.trim()}）',
  ];
  final role = self.title.trim();
  final others = [
    for (final item in sanitized)
      if (item.id != self.id && item.name.trim().isNotEmpty)
        item.title.trim().isEmpty
            ? item.name.trim()
            : '${item.name.trim()}（${item.title.trim()}）',
  ];
  final desk = supervisor == null
      ? '你直接对接用户。用户没点名时，默认只把话交给你，不要让全员抢答。'
      : '你的上级是「${supervisor.name.trim()}」。用户默认不直接找你；被 @ 或上级安排后再发言，说完向直接上级汇报。';
  final reportsBlock = reports.isEmpty ? '无' : reports.join('、');
  final othersBlock = others.isEmpty ? '目前只有你和用户。' : others.join('、');
  final isLead = reports.isNotEmpty;
  final dutyBlock = isLead
      ? '你的职责是**指挥**，不是执行：拆解任务 → @下属 分工 → 验收 → 汇总。\n'
            '只要这件事需要动手，就必须先 @名字 把可执行的子任务派下去，**不要自己把活干完再汇报**；'
            '一个人扛完全部工作视为失职。\n'
            '你可以只点一个、点几个，也可以拆成几份同时点所有下属（他们各自并行处理）；'
            '被点到的下属才会启动，没点到的保持待命。\n'
            '下属**全部**汇报完系统才会再次叫到你：收到全体汇报后做验收，需要返工就写「打回」并 @责任成员'
            '（同一交接环节最多 3 次），没问题再汇总给你的上级（或用户）。\n'
      : '你没有下属：这件事由你自己完成，然后把结果交给你的上级（或用户）。';
  return '你是拾忆群聊里的独立成员「${self.name.trim()}」。\n'
      '职位：${role.isEmpty ? '未指定' : role}\n'
      '$desk\n'
      '你的下属：$reportsBlock\n'
      '群里其他成员：$othersBlock\n'
      '只用自己的身份说话，不要扮演其他成员，不要替用户说话。\n'
      '$dutyBlock\n'
      '需要同级协作或向上汇报时也是 @名字；@自己的上级 = 汇报。\n'
      '多步任务必须用 @名字 把下一步交给具体成员。\n'
      '正常推进没有固定发言上限。\n'
      '**汇报必须给实质内容**（团队里只有正文会被别人看到，思考过程不算汇报）：\n'
      '用 2-5 句写清 ① 结论/完成到哪一步 ② 具体产出（文件路径、命令、关键数据、行数/字节数）'
      '③ 遇到的问题或不确定点 ④ 下一步要谁接。\n'
      '禁止只回「收到」「已完成」「好的」「我马上处理」这类空话；'
      '也禁止把大段原始输出粘进正文（把路径和结论写出来即可）。\n'
      '人设：\n$personaBlock';
}

List<String> groupChatOrgLines(List<GroupAgent> agents) {
  final sanitized = groupChatSanitizeOrg(agents);
  if (sanitized.isEmpty) return const ['还没有成员'];
  final roots = groupChatUserFacingAgents(sanitized);
  final lines = <String>['用户'];
  void walk(GroupAgent agent, String prefix, bool last) {
    final branch = last ? '└ ' : '├ ';
    final role = agent.title.trim();
    final desk = agent.reportsToId.trim().isEmpty ? ' · 对接用户' : '';
    final roleBit = role.isEmpty ? '' : '（$role）';
    lines.add('$prefix$branch${agent.name.trim()}$roleBit$desk');
    final kids = groupChatReportsOf(agent.id, sanitized);
    final nextPrefix = '$prefix${last ? '   ' : '│  '}';
    for (var i = 0; i < kids.length; i++) {
      walk(kids[i], nextPrefix, i == kids.length - 1);
    }
  }

  for (var i = 0; i < roots.length; i++) {
    walk(roots[i], '', i == roots.length - 1);
  }
  return lines;
}

List<Map<String, dynamic>> groupChatApiMessages({
  required GroupAgent speaker,
  required List<GroupAgent> agents,
  required List<GroupMessage> history,
  String contextSummary = '',
  String presencePrompt = '',
}) {
  final names = {for (final agent in agents) agent.id: agent.name};
  final speakerName = speaker.name.trim().toLowerCase();
  final supervisorId = speaker.reportsToId.trim();
  final directReportIds = {
    for (final a in agents)
      if (a.reportsToId.trim() == speaker.id) a.id,
  };
  final system = groupChatSystemPrompt(speaker, agents);
  final summary = contextSummary.trim();
  final presence = presencePrompt.trim();
  final systemContent = [
    summary.isEmpty ? system : '$system\n\n【你的早期历史摘要】\n$summary',
    if (presence.isNotEmpty) presence,
  ].join('\n\n');
  final out = <Map<String, dynamic>>[
    {
      'role': 'system',
      'content': systemContent,
    },
  ];
  for (final message in history) {
    if (message.streaming && message.content.trim().isEmpty) continue;
    final text = message.content.trim();
    if (text.isEmpty) continue;
    if (message.isUser) {
      out.add({'role': 'user', 'content': text});
      continue;
    }
    if (message.agentId == speaker.id) {
      out.add({
        'role': 'assistant',
        'content': text,
        if (message.reasoning.trim().isNotEmpty)
          'reasoning_content': message.reasoning.trim(),
      });
      continue;
    }
    // Independent context: only include messages relevant to this speaker.
    final senderId = message.agentId;
    final isMentioned = text.toLowerCase().contains('@$speakerName');
    final isFromSupervisor = senderId == supervisorId;
    final isFromReport = directReportIds.contains(senderId);
    if (!isMentioned && !isFromSupervisor && !isFromReport) continue;
    final name = names[message.agentId] ?? '成员';
    out.add({'role': 'user', 'content': '[$name]: $text'});
  }
  return out;
}

ApiProfile? groupChatProfileFor(
  GroupAgent agent,
  List<ApiProfile> profiles, {
  ApiProfile? fallback,
}) {
  final id = agent.apiProfileId.trim();
  if (id.isNotEmpty) {
    for (final profile in profiles) {
      if (profile.profileId == id) return profile;
    }
  }
  return fallback ?? (profiles.isEmpty ? null : profiles.first);
}

/// 群聊里显示用的工具入参摘要（写入类给路径）。
String groupChatToolArgsSummary(String name, String argsJson) =>
    toolArgsSummary(name, argsJson, maxRunes: 48);