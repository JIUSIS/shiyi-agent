import 'package:flutter/material.dart';

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

const groupChatMaxParallelAgents = 3;
const groupChatMaxReworksPerHandoff = 3;

class GroupChatFollowup {
  final GroupAgent speaker;
  final GroupAgent target;
  final bool isRework;

  const GroupChatFollowup({
    required this.speaker,
    required this.target,
    this.isRework = false,
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

class GroupMessage {
  final String id;
  final String roomId;
  final String role; // user | agent
  final String agentId;
  String content;
  String reasoning;
  final int createdAt;
  bool streaming;

  GroupMessage({
    required this.id,
    required this.roomId,
    required this.role,
    this.agentId = '',
    this.content = '',
    this.reasoning = '',
    required this.createdAt,
    this.streaming = false,
  });

  bool get isUser => role == 'user';

  Map<String, dynamic> toMap() => {
    'id': id,
    'room_id': roomId,
    'role': role,
    'agent_id': agentId,
    'content': content,
    'reasoning': reasoning,
    'created_at': createdAt,
  };

  factory GroupMessage.fromMap(Map<String, dynamic> m) => GroupMessage(
    id: (m['id'] ?? '').toString(),
    roomId: (m['room_id'] ?? '').toString(),
    role: (m['role'] ?? 'user').toString(),
    agentId: (m['agent_id'] ?? '').toString(),
    content: (m['content'] ?? '').toString(),
    reasoning: (m['reasoning'] ?? '').toString(),
    createdAt: _toInt(m['created_at']),
  );
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

/// 用户发言：点名优先，否则只找对接用户的人。
List<GroupAgent> groupChatInitialTargets(String text, List<GroupAgent> agents) {
  final mentioned = groupChatMentionedAgents(text, agents);
  if (mentioned.isNotEmpty) return mentioned;
  return groupChatUserFacingAgents(agents);
}

/// 某成员说完后：先听 @点名；没点名且有上级，则向上级汇报。
List<GroupChatFollowup> groupChatFollowupTargets({
  required GroupAgent speaker,
  required String reply,
  required List<GroupAgent> agents,
}) {
  final mentioned = [
    for (final agent in groupChatMentionedAgents(reply, agents))
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
        GroupChatFollowup(speaker: speaker, target: agent),
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
  return '你是拾忆群聊里的独立成员「${self.name.trim()}」。\n'
      '职位：${role.isEmpty ? '未指定' : role}\n'
      '$desk\n'
      '你的下属：$reportsBlock\n'
      '群里其他成员：$othersBlock\n'
      '只用自己的身份说话，不要扮演其他成员，不要替用户说话。\n'
      '需要别人处理时用 @名字 点名，等对方回复；不要替下属写结论。\n'
      '多步任务必须用 @名字 把下一步交给具体成员；没有可接力的成员就直接给用户完整结果。\n'
      '正常推进没有固定发言上限；需要返工时，第一行写「打回」并 @责任成员，同一交接环节最多打回 3 次。\n'
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
}) {
  final names = {for (final agent in agents) agent.id: agent.name};
  final speakerName = speaker.name.trim().toLowerCase();
  final supervisorId = speaker.reportsToId.trim();
  final directReportIds = [
    for (final a in agents)
      if (a.reportsToId.trim() == speaker.id) a.id,
  ].toSet();
  final system = groupChatSystemPrompt(speaker, agents);
  final summary = contextSummary.trim();
  final out = <Map<String, dynamic>>[
    {
      'role': 'system',
      'content': summary.isEmpty ? system : '$system\n\n【你的早期历史摘要】\n$summary',
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
