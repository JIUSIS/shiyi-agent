import 'group_chat.dart';

const groupMindmapSectionNames = <String>{
  '总体架构',
  'agent角色',
  'agent 角色',
  '角色',
  '成员',
  '流程主线',
  '流程',
  '对接规则',
  '对接',
  '汇报',
  '汇报关系',
  '沟通',
  '质量门禁',
  '工程要点',
  '起步路线',
  '起步',
  '最小',
  '人员',
  '人',
};

const _agentStartMarker = '\u{1F}';
const _agentEndMarker = '\u{1E}';

/// 内置「最小结构模板」：主编 + 写手。
/// 可粘贴到“从思维导图导入”识别，也可复制后发给 Agent 作为组织参考。
const groupMindmapMinimalTemplate = '''
mindmap
  root((写作流水线))
    Agent角色
      主编/负责人
        唯一入口
        调度与仲裁
        最终放行
      写手A/卷写手
        卷一写作
        忠于大纲
    对接规则
      用户只对接主编
      写手A只对接主编
    起步路线
      最小可用2个
      主编+写手
''';

class GroupMindmapAgentDraft {
  final String name;
  final String title;
  final List<String> duties;
  String reportsToName;

  GroupMindmapAgentDraft({
    required this.name,
    this.title = '',
    List<String>? duties,
    this.reportsToName = '',
  }) : duties = duties ?? [];

  String get persona {
    final lines = [
      for (final item in duties)
        if (item.trim().isNotEmpty) item.trim(),
    ];
    return lines.join('\n');
  }
}

class GroupMindmapParse {
  final String title;
  final List<GroupMindmapAgentDraft> agents;
  final List<String> minimalNames;
  final List<String> rules;
  final String sharedContext;
  final String note;

  const GroupMindmapParse({
    this.title = '',
    this.agents = const [],
    this.minimalNames = const [],
    this.rules = const [],
    this.sharedContext = '',
    this.note = '',
  });

  bool get isEmpty => agents.isEmpty;

  List<GroupMindmapAgentDraft> agentsFor({required bool minimal}) {
    if (!minimal || minimalNames.isEmpty) return agents;
    final used = <int>{};
    final out = <GroupMindmapAgentDraft>[];
    for (final needle in minimalNames) {
      var index = -1;
      for (var i = 0; i < agents.length; i++) {
        if (used.contains(i)) continue;
        if (!_nameMatches(agents[i].name, needle)) continue;
        index = i;
        break;
      }
      if (index < 0) continue;
      used.add(index);
      out.add(agents[index]);
    }
    return out.isEmpty ? agents : out;
  }

  List<GroupAgent> toGroupAgents({
    required String roomId,
    required String apiProfileId,
    required String model,
    bool minimal = false,
  }) {
    final drafts = agentsFor(minimal: minimal);
    if (drafts.isEmpty) return const [];
    final agents = <GroupAgent>[
      for (var i = 0; i < drafts.length; i++)
        GroupAgent(
          id: groupChatNewId('ga'),
          roomId: roomId,
          name: drafts[i].name,
          title: drafts[i].title,
          persona: _personaWithContext(drafts[i]),
          apiProfileId: apiProfileId,
          model: model,
          colorIndex: i,
          sortOrder: i,
        ),
    ];
    final leadName = _leadName(drafts) ?? drafts.first.name;
    final byName = {for (final agent in agents) agent.name: agent};
    for (var i = 0; i < drafts.length; i++) {
      final draft = drafts[i];
      final self = agents[i];
      if (_nameMatches(self.name, leadName) ||
          (draft.reportsToName.trim().isEmpty &&
              _nameMatches(self.name, leadName))) {
        continue;
      }
      var bossName = draft.reportsToName.trim();
      if (bossName.isEmpty) bossName = leadName;
      final boss = _findAgent(byName, agents, bossName);
      if (boss == null || boss.id == self.id) continue;
      agents[i] = self.copyWith(reportsToId: boss.id);
    }
    return groupChatSanitizeOrg(agents);
  }

  String _personaWithContext(GroupMindmapAgentDraft draft) {
    final parts = [
      if (draft.persona.trim().isNotEmpty) draft.persona.trim(),
      if (sharedContext.trim().isNotEmpty) sharedContext.trim(),
    ];
    return parts.join('\n\n');
  }
}

GroupMindmapParse parseGroupMindmap(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return const GroupMindmapParse();
  if (RegExp(r'[┌┐└┘├┤│─┼]').hasMatch(text)) {
    return _parseFromSections(
      _asciiSections(text),
      fallbackTitle: _asciiTitle(text),
    );
  }
  if (text.contains('\n') && _looksLikeMermaid(text)) {
    final tree = _parseMermaidTree(text);
    if (tree != null) {
      final parsed = _parseFromTree(tree);
      if (parsed.agents.isNotEmpty) return parsed;
    }
  }
  return _parseFromSections(
    _tokenSections(_tokenize(text)),
    fallbackTitle: _mermaidRootTitle(text),
  );
}

bool _looksLikeMermaid(String text) =>
    RegExp(r'^\s*mindmap\b', multiLine: true).hasMatch(text) ||
    text.contains('root((');

String _mermaidRootTitle(String text) {
  final match = RegExp(r'root\(\((.+?)\)\)').firstMatch(text);
  return (match?.group(1) ?? '').trim();
}

class _MindNode {
  final String text;
  final List<_MindNode> children;
  _MindNode(this.text, [List<_MindNode>? children]) : children = children ?? [];
}

_MindNode? _parseMermaidTree(String text) {
  final rows = <({int indent, String text})>[];
  for (final rawLine in text.split('\n')) {
    // Mermaid 缩进可能混用 Tab 和空格。行首 Tab 统一展开成 2 空格，
    // 否则 1 个 Tab 和 2 个空格会被解读成不同层级。
    final indentText = rawLine.replaceFirstMapped(
      RegExp(r'^[ \t]*'),
      (m) => m.group(0)!.replaceAll('\t', '  '),
    );
    final trimmed = indentText.trimRight();
    if (trimmed.trim().isEmpty) continue;
    if (trimmed.trim() == 'mindmap') continue;
    rows.add((
      indent: indentText.length - indentText.trimLeft().length,
      text: _stripMermaidShape(trimmed.trim()),
    ));
  }
  if (rows.isEmpty) return null;
  final root = _MindNode(rows.first.text);
  final stack = <({int indent, _MindNode node})>[
    (indent: rows.first.indent, node: root),
  ];
  for (var i = 1; i < rows.length; i++) {
    final row = rows[i];
    final node = _MindNode(row.text);
    while (stack.length > 1 && stack.last.indent >= row.indent) {
      stack.removeLast();
    }
    stack.last.node.children.add(node);
    stack.add((indent: row.indent, node: node));
  }
  return root;
}

String _stripMermaidShape(String text) {
  final patterns = [
    RegExp(r'^[A-Za-z0-9_]*\(\((.+)\)\)$'),
    RegExp(r'^[A-Za-z0-9_]*\[\[(.+)\]\]$'),
    RegExp(r'^[A-Za-z0-9_]*\[(.+)\]$'),
    RegExp(r'^[A-Za-z0-9_]*\((.+)\)$'),
  ];
  for (final pattern in patterns) {
    final match = pattern.firstMatch(text);
    if (match != null) return match.group(1)!.trim();
  }
  return text;
}

GroupMindmapParse _parseFromTree(_MindNode root) {
  final sections = <String, List<String>>{};
  if (root.children.isEmpty) {
    return _parseFromSections(
      _tokenSections(_tokenize(root.text)),
      fallbackTitle: root.text,
    );
  }
  for (final child in root.children) {
    final key = _canonicalSectionKey(child.text);
    final items = <String>[];
    void walk(_MindNode node, {required bool keepSelf}) {
      if (keepSelf && node.text.trim().isNotEmpty) items.add(node.text.trim());
      for (final next in node.children) {
        walk(next, keepSelf: true);
      }
    }

    if (key == 'agent角色') {
      void appendAgent(_MindNode agent) {
        final nestedAgents = <_MindNode>[];
        final duties = <String>[];
        for (final child in agent.children) {
          if (_looksLikeNestedAgent(child)) {
            nestedAgents.add(child);
          } else {
            duties.add(child.text);
          }
        }
        items.add(_agentStartMarker);
        items.add(agent.text);
        items.addAll(duties);
        items.add(_agentEndMarker);
        for (final nested in nestedAgents) {
          appendAgent(nested);
        }
      }

      for (final candidate in child.children) {
        if (candidate.children.any(_looksLikeNestedAgent)) {
          for (final nested in candidate.children) {
            appendAgent(nested);
          }
        } else {
          appendAgent(candidate);
        }
      }
    } else {
      walk(child, keepSelf: !_isSectionToken(child.text));
    }
    sections.putIfAbsent(key, () => []).addAll(items);
  }
  return _assemble(title: root.text, sections: sections);
}

Map<String, List<String>> _tokenSections(List<String> tokens) {
  final sections = <String, List<String>>{};
  var current = '';
  for (var i = 0; i < tokens.length; i++) {
    final token = tokens[i];
    if (token == 'mindmap') continue;
    if (token.startsWith('root((')) continue;
    final key = _canonicalSectionKey(token);
    if (_isSectionToken(token)) {
      current = key;
      sections[current] ??= [];
      continue;
    }
    if (current.isEmpty) continue;
    sections[current]!.add(token);
  }
  return sections;
}

Map<String, List<String>> _asciiSections(String text) {
  final cleaned = text.replaceAll(RegExp(r'[┌┐└┘├┤│─┼]'), ' ');
  final lines = [
    for (final line in cleaned.split('\n'))
      line.replaceAll(RegExp(r'[ ]{2,}'), '  ').trim(),
  ];
  final merged = <String>[];
  for (final line in lines) {
    if (line.isEmpty) continue;
    if (line == '角色' ||
        line.startsWith('角色 ') ||
        RegExp(r'^角色$').hasMatch(line)) {
      if (merged.isNotEmpty && _sectionKey(merged.last).startsWith('agent')) {
        merged[merged.length - 1] = '${merged.last}角色';
        if (line.length > 2) merged.add(line.substring(2).trim());
        continue;
      }
    }
    merged.add(line);
  }
  final tokens = <String>[];
  for (final line in merged) {
    tokens.addAll(_tokenize(line));
  }
  final sections = _tokenSections(tokens);
  final harvested = _harvestAgentTokens(tokens);
  if (harvested.isNotEmpty) {
    final existing = sections['agent角色'] ?? const <String>[];
    if (_agentsFromTokens(harvested).length >
        _agentsFromTokens(existing).length) {
      sections['agent角色'] = harvested;
    }
  }
  return sections;
}

List<String> _harvestAgentTokens(List<String> tokens) {
  final out = <String>[];
  for (var i = 0; i < tokens.length; i++) {
    if (!_looksLikeAgentName(tokens[i])) continue;
    out.add(tokens[i]);
    var j = i + 1;
    while (j < tokens.length &&
        !_looksLikeAgentName(tokens[j]) &&
        !_isSectionToken(tokens[j])) {
      out.add(tokens[j]);
      j += 1;
    }
    out.add(String.fromCharCode(30));
    i = j - 1;
  }
  return out;
}

String _asciiTitle(String text) {
  final match = RegExp(r'(AI[^┌┐└┘├┤│─┼\n]{0,12}写作)').firstMatch(text);
  if (match != null) return match.group(1)!.trim();
  return '';
}

List<String> _tokenize(String text) {
  final normalized = text
      .replaceAll('\r', '')
      .replaceAll(RegExp(r'[┌┐└┘├┤│─┼]'), ' ')
      .replaceAll('mindmap', 'mindmap  ')
      .replaceAllMapped(
        RegExp(r'root\(\((.+?)\)\)'),
        (m) => 'root((${m.group(1)}))',
      );
  return [
    for (final part in normalized.split(RegExp(r'\s{2,}|\n')))
      if (part.trim().isNotEmpty) part.trim(),
  ];
}

GroupMindmapParse _parseFromSections(
  Map<String, List<String>> sections, {
  String fallbackTitle = '',
}) {
  final agentTokens = [
    ...?sections['agent角色'],
    ...?sections['agent 角色'],
    ...?sections['角色'],
    ...?sections['成员'],
  ];
  final agents = _agentsFromTokens(agentTokens);
  final rules = _normalizeRules([...?sections['对接规则'], ...?sections['对接']]);
  _applyRules(agents, rules);
  final starter = [...?sections['起步路线'], ...?sections['起步']];
  final minimal = _minimalNames(starter);
  final shared = _sharedContext(sections, rules);
  var note = '';
  if (minimal.isNotEmpty && agents.length != 4 && agents.length != 8) {
    note = '角色区 ${agents.length} 人，起步路线写了最小 ${minimal.length} 人';
  }
  return GroupMindmapParse(
    title: fallbackTitle.trim(),
    agents: agents,
    minimalNames: minimal,
    rules: rules,
    sharedContext: shared,
    note: note,
  );
}

List<GroupMindmapAgentDraft> _agentsFromTokens(List<String> tokens) {
  final agents = <GroupMindmapAgentDraft>[];
  GroupMindmapAgentDraft? current;
  var forceAgent = false;
  for (final token in tokens) {
    if (token == _agentEndMarker) {
      current = null;
      continue;
    }
    if (token == _agentStartMarker) {
      forceAgent = true;
      continue;
    }
    if (forceAgent || _looksLikeAgentName(token)) {
      forceAgent = false;
      final split = _splitNameTitle(token);
      current = GroupMindmapAgentDraft(name: split.$1, title: split.$2);
      agents.add(current);
      continue;
    }
    if (current == null) continue;
    current.duties.add(token);
  }
  return agents;
}

(String, String) _splitNameTitle(String raw) {
  final text = raw.trim();
  final slash = text.split('/');
  if (slash.length >= 2) {
    return (slash.first.trim(), slash.sublist(1).join('/').trim());
  }
  final colon = RegExp(r'^([^:：]+)[:：](.+)$').firstMatch(text);
  if (colon != null) {
    return (colon.group(1)!.trim(), colon.group(2)!.trim());
  }
  return (text, '');
}

final _roleName = RegExp(
  r'^(主编|总控|策划|设定师|写手[A-Za-z0-9]{0,2}|结构审|润色|校对|合规审|经理|导演|编辑)(/[\u4e00-\u9fff]{1,6})?$',
);

bool _looksLikeAgentName(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return false;
  if (text.contains('：') || text.contains(':')) return false;
  if (text.contains('→') || text.contains('↔') || text.contains('->')) {
    return false;
  }
  if (RegExp(r'^(最小|完整|用户只|用户对接|写手只|打回|高频|终止|合规审独立)').hasMatch(text)) {
    return false;
  }
  if (_roleName.hasMatch(text)) return true;
  if (text.contains('/')) {
    final parts = [for (final part in text.split('/')) part.trim()];
    return parts.length == 2 &&
        parts.every((part) => part.length <= 3) &&
        !text.contains('（');
  }
  return false;
}

void _applyRules(List<GroupMindmapAgentDraft> agents, List<String> rules) {
  if (agents.isEmpty) return;
  final normalizedRules = _normalizeRules(rules);
  final lead = _leadFromRules(normalizedRules, agents) ?? agents.first.name;
  for (final agent in agents) {
    if (_nameMatches(agent.name, lead)) {
      agent.reportsToName = '';
    } else {
      agent.reportsToName = lead;
    }
  }
  for (final rule in normalizedRules) {
    final match = RegExp(r'^(.+?)只对接(.+)$').firstMatch(rule.trim());
    if (match == null) continue;
    final who = match.group(1)!.trim();
    if (who.startsWith('用户')) continue;
    final target = _firstAgentName(match.group(2)!.trim(), agents) ?? lead;
    for (final agent in _agentsMatching(who, agents)) {
      if (!_nameMatches(agent.name, lead)) {
        agent.reportsToName = target;
      }
    }
  }
}

List<String> _normalizeRules(List<String> rules) {
  final out = <String>[];
  for (final raw in rules) {
    final text = raw.trim();
    if (text.isEmpty) continue;
    final bidirectional = RegExp(
      r'^(.+?)\s*(?:↔|<->|<=>)\s*(.+)$',
    ).firstMatch(text);
    if (bidirectional != null) {
      final left = bidirectional.group(1)!.trim();
      final right = bidirectional.group(2)!.trim();
      out
        ..add('$left只对接$right')
        ..add('$right只对接$left');
      continue;
    }
    final directional = RegExp(
      r'^(.+?)\s*(?:→|->|=>)\s*(.+)$',
    ).firstMatch(text);
    if (directional != null) {
      out.add(
        '${directional.group(1)!.trim()}只对接${directional.group(2)!.trim()}',
      );
      continue;
    }
    final oneToMany = RegExp(r'^(.+?只对接)(.+)$').firstMatch(text);
    if (oneToMany != null) {
      final prefix = oneToMany.group(1)!;
      final targets = oneToMany
          .group(2)!
          .split(RegExp(r'\s*(?:、|，|,|;|；|\+|和|与|以及)\s*'))
          .map((part) => part.trim())
          .where((part) => part.isNotEmpty)
          .toList();
      if (targets.length <= 1) {
        out.add(text);
      } else {
        out.addAll([for (final target in targets) '$prefix$target']);
      }
      continue;
    }
    out.add(text);
  }
  return out;
}

bool _isSectionToken(String raw) {
  final text = raw.trim();
  if (RegExp(r'只对接|↔|→|->|=>').hasMatch(text)) {
    return false;
  }
  return groupMindmapSectionNames.contains(_canonicalSectionKey(text));
}

bool _looksLikeNestedAgent(_MindNode node) {
  return node.children.isNotEmpty || _looksLikeAgentName(node.text);
}

String? _leadFromRules(
  List<String> rules,
  List<GroupMindmapAgentDraft> agents,
) {
  for (final rule in rules) {
    final match = RegExp(r'用户只?对接(.+)').firstMatch(rule);
    if (match == null) continue;
    return _firstAgentName(match.group(1)!.trim(), agents);
  }
  return null;
}

String? _leadName(List<GroupMindmapAgentDraft> drafts) {
  for (final draft in drafts) {
    if (draft.reportsToName.trim().isEmpty) return draft.name;
  }
  return drafts.isEmpty ? null : drafts.first.name;
}

List<GroupMindmapAgentDraft> _agentsMatching(
  String rawWho,
  List<GroupMindmapAgentDraft> agents,
) {
  final who = _cleanName(rawWho);
  final base = who
      .replaceFirst(RegExp(r'^(?:全体|所有|全部|每个|各位)'), '')
      .replaceFirst(RegExp(r'们$'), '');
  return [
    for (final agent in agents)
      if (_nameMatches(agent.name, who) ||
          (base.isNotEmpty && _nameMatches(agent.name, base)))
        agent,
  ];
}

String _cleanName(String raw) {
  return raw.trim().replaceAll('"', '').replaceAll('“', '').replaceAll('”', '');
}

String? _firstAgentName(String haystack, List<GroupMindmapAgentDraft> agents) {
  final cleaned = haystack
      .replaceAll('"', '')
      .replaceAll('“', '')
      .replaceAll('”', '');
  GroupMindmapAgentDraft? found;
  var bestPosition = -1;
  for (final agent in agents) {
    final at = cleaned.indexOf(agent.name);
    final short = agent.name.split('/').first;
    final atShort = cleaned.indexOf(short);
    final hit = at >= 0 ? at : atShort;
    if (hit >= 0 && (bestPosition < 0 || hit < bestPosition)) {
      bestPosition = hit;
      found = agent;
    }
  }
  return found?.name;
}

List<String> _minimalNames(List<String> starter) {
  final joined = starter.join(' ');
  final match = RegExp(
    r'([\u4e00-\u9fffA-Za-z0-9]+(?:\+[\u4e00-\u9fffA-Za-z0-9]+)+)',
  ).firstMatch(joined);
  if (match == null) return const [];
  return [
    for (final part in match.group(1)!.split('+'))
      if (part.trim().isNotEmpty) part.trim(),
  ];
}

String _sharedContext(Map<String, List<String>> sections, List<String> rules) {
  final chunks = <String>[];
  void add(String title, List<String>? items) {
    if (items == null || items.isEmpty) return;
    chunks.add('【$title】\n${items.join('\n')}');
  }

  add('对接规则', rules);
  add('流程主线', sections['流程主线'] ?? sections['流程']);
  add('质量门禁', sections['质量门禁']);
  add('工程要点', sections['工程要点']);
  add('总体架构', sections['总体架构']);
  return chunks.join('\n\n');
}

GroupAgent? _findAgent(
  Map<String, GroupAgent> byName,
  List<GroupAgent> agents,
  String name,
) {
  final exact = byName[name];
  if (exact != null) return exact;
  for (final agent in agents) {
    if (_nameMatches(agent.name, name)) return agent;
  }
  return null;
}

bool _nameMatches(String name, String needle) {
  final a = name.trim();
  final b = needle.trim();
  if (a.isEmpty || b.isEmpty) return false;
  if (a == b) return true;
  final aHead = a.split('/').first;
  final bHead = b.split('/').first;
  return a.contains(b) || b.contains(a) || aHead == bHead;
}

String _sectionKey(String raw) {
  return raw.trim().replaceAll(RegExp(r'[\s:：]+'), '').toLowerCase();
}

String _canonicalSectionKey(String raw) {
  final key = _sectionKey(raw);
  if (key.contains('agent') ||
      key == '角色' ||
      key == '成员' ||
      key == '人员' ||
      key == '人') {
    return 'agent角色';
  }
  if (key.contains('对接') || key.contains('汇报') || key.contains('沟通')) {
    return '对接规则';
  }
  if (key.contains('起步') ||
      key.contains('最小') ||
      key.contains('落地') ||
      key.contains('启动')) {
    return '起步路线';
  }
  if (key.contains('流程')) return '流程主线';
  if (key.contains('质量') || key.contains('门禁')) return '质量门禁';
  if (key.contains('工程')) return '工程要点';
  if (key.contains('总体') || key.contains('架构')) return '总体架构';
  return key;
}

GroupMindmapParse _assemble({
  required String title,
  required Map<String, List<String>> sections,
}) {
  return _parseFromSections(sections, fallbackTitle: title);
}
