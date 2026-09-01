import 'package:flutter/material.dart';

import 'models.dart';

String groupChatNewId(String prefix) {
  final now = DateTime.now();
  final timestamp = now.microsecondsSinceEpoch;
  final random = now.hashCode ^ (Object().hashCode);
  return '$prefix${timestamp}_$random';
}

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
const groupChatStreamEmitMinIntervalMs = 50;

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

  /// 回复目标。当用户发消息时为空；当 Agent 回复时，
  /// 指向触发这条消息的"根消息"（用户消息或被 @ 的 Agent 消息）。
  /// 用于确定消息的可见范围。
  String replyToId;

  GroupMessage({
    required this.id,
    required this.roomId,
    required this.role,
    this.agentId = '',
    this.content = '',
    this.reasoning = '',
    required this.createdAt,
    this.streaming = false,
    this.replyToId = '',
  });

  bool get isUser => role == 'user';

  Map<String, dynamic> toMap() => {
    'id': id,
    'room_id': roomId,
    'role': role,
    'agent_id': agentId,
    'content': content,
    'reasoning': reasoning,
    'reply_to': replyToId,
    'created_at': createdAt,
  };

  factory GroupMessage.fromMap(Map<String, dynamic> m) => GroupMessage(
    id: (m['id'] ?? '').toString(),
    roomId: (m['room_id'] ?? '').toString(),
    role: (m['role'] ?? 'user').toString(),
    agentId: (m['agent_id'] ?? '').toString(),
    content: (m['content'] ?? '').toString(),
    reasoning: (m['reasoning'] ?? '').toString(),
    replyToId: (m['reply_to'] ?? '').toString(),
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
}) {
  final names = {for (final agent in agents) agent.id: agent.name};
  final out = <Map<String, dynamic>>[
    {'role': 'system', 'content': groupChatSystemPrompt(speaker, agents)},
  ];
  // 只取对该 Agent 可见的消息，实现真正的多 Agent 隔离
  final visible = groupChatAgentHistory(history, speaker, agents);
  for (final message in visible) {
    if (message.streaming && message.content.trim().isEmpty) continue;
    final text = message.content.trim();
    if (text.isEmpty) continue;
    if (message.isUser) {
      out.add({'role': 'user', 'content': text});
      continue;
    }
    if (message.agentId == speaker.id) {
      out.add({'role': 'assistant', 'content': text});
      continue;
    }
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

/// 判断某条消息是否对某 Agent 可见。
///
/// 可见规则：
/// - 用户消息 → 所有人可见
/// - 自己发的 → 可见
/// - 自己下属发的 → 主编可见（通过 reportsToId 判断上下级）
bool groupChatMessageVisibleTo({
  required GroupMessage message,
  required GroupAgent agent,
  required List<GroupAgent> agents,
}) {
  // 1. 用户消息 → 所有人可见
  if (message.isUser) return true;

  // 2. 自己发的 → 可见
  if (message.agentId == agent.id) return true;

  // 3. 自己的下属发的 → 主编可见
  //    检查消息发送者是否是 agent 的下属
  final speaker = groupChatAgentById(message.agentId, agents);
  if (speaker != null && speaker.reportsToId.trim() == agent.id) return true;

  return false;
}

/// 为某个 Agent 过滤消息历史：只保留他可见的消息。
/// 这是实现真正独立 Agent 的核心——每个 Agent 只能看到与自己相关的消息。
List<GroupMessage> groupChatAgentHistory(
  List<GroupMessage> allMessages,
  GroupAgent agent,
  List<GroupAgent> agents,
) {
  return [
    for (final message in allMessages)
      if (groupChatMessageVisibleTo(
        message: message,
        agent: agent,
        agents: agents,
      ))
        message,
  ];
}
