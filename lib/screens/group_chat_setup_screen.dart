import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../core/group_chat.dart';
import '../core/group_mindmap.dart';
import '../core/mac_page_route.dart';
import '../core/models.dart';
import '../core/model_presets.dart';
import '../services/group_chat_store.dart';
import '../widgets/agent_swipe_delete.dart';
import '../widgets/bagua_icon.dart';
import '../widgets/group_project_picker.dart';
import '../widgets/home_group_header.dart';
import '../widgets/ios_style.dart';
import '../widgets/mac_action_button.dart';
import '../widgets/traffic_lights_button.dart';

class GroupChatSetupScreen extends StatefulWidget {
  final ShiyiState shiyi;
  final GroupRoom? room;
  const GroupChatSetupScreen({super.key, required this.shiyi, this.room});

  @override
  State<GroupChatSetupScreen> createState() => _GroupChatSetupScreenState();
}

class _GroupChatSetupScreenState extends State<GroupChatSetupScreen> {
  late final TextEditingController _title;
  late final TextEditingController _mindmap;
  final ValueNotifier<String?> _openSwipeKey = ValueNotifier<String?>(null);
  Rect? _openSwipeRect;
  late String _roomId;
  late int _createdAt;
  List<GroupAgent> _agents = [];
  bool _saving = false;
  GroupMindmapParse? _parsed;
  bool _useMinimal = false;
  late String _projectId;
  String _unifiedProfileId = '';
  String _unifiedModel = '';

  bool get _isEdit => widget.room != null;

  ApiProfile? get _defaultProfile {
    final profiles = widget.shiyi.apiProfiles;
    if (profiles.isEmpty) return null;
    final id = widget.shiyi.settings.apiProfileId.trim();
    if (id.isNotEmpty) {
      for (final profile in profiles) {
        if (profile.profileId == id) return profile;
      }
    }
    return profileMatchingSettings(widget.shiyi.settings, profiles) ??
        profiles.first;
  }

  String get _defaultModel {
    final fromProfile = _defaultProfile?.model.trim() ?? '';
    if (fromProfile.isNotEmpty) return fromProfile;
    return widget.shiyi.settings.model;
  }

  @override
  void initState() {
    super.initState();
    final room = widget.room;
    _roomId = room?.id ?? groupChatNewId('g');
    _createdAt = room?.createdAt ?? DateTime.now().millisecondsSinceEpoch;
    _projectId = room?.projectId ?? '';
    _title = TextEditingController(text: room?.title ?? '');
    _mindmap = TextEditingController();
    _agents = groupChatSanitizeOrg([
      for (final agent in room?.agents ?? const <GroupAgent>[])
        agent.copyWith(),
    ]);
    if (_agents.isEmpty) {
      final lead = _newAgent('主管', 0, reportsToId: '');
      _agents = [lead, _newAgent('成员', 1, reportsToId: lead.id)];
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _mindmap.dispose();
    _openSwipeKey.dispose();
    super.dispose();
  }

  void _showAlert(String title, String message) {
    if (!mounted) return;
    showCupertinoDialog<void>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          CupertinoDialogAction(
            child: const Text('好'),
            onPressed: () => Navigator.pop(ctx),
          ),
        ],
      ),
    );
  }

  GroupAgent _newAgent(String name, int colorIndex, {String? reportsToId}) {
    final profile = _defaultProfile;
    final facing = groupChatUserFacingAgents(_agents);
    final fallbackBoss = facing.isNotEmpty
        ? facing.first.id
        : (_agents.isEmpty ? '' : _agents.first.id);
    return GroupAgent(
      id: groupChatNewId('ga'),
      roomId: _roomId,
      name: name,
      title: reportsToId == '' ? '负责人' : '成员',
      apiProfileId: profile?.profileId ?? '',
      model: _defaultModel,
      reportsToId: reportsToId ?? fallbackBoss,
      colorIndex: colorIndex,
      sortOrder: _agents.length,
    );
  }

  List<GroupAgent> _agentsFromParse(GroupMindmapParse parsed) {
    return parsed.toGroupAgents(
      roomId: _roomId,
      apiProfileId: _defaultProfile?.profileId ?? '',
      model: _defaultModel,
      minimal: _useMinimal,
    );
  }

  void _recognizeMindmap() {
    final parsed = parseGroupMindmap(_mindmap.text);
    setState(() {
      _parsed = parsed;
      if (parsed.minimalNames.isEmpty) _useMinimal = false;
    });
    if (!mounted) return;
    if (parsed.isEmpty) {
      _showAlert('没认出 Agent', '检查一下角色区，确保有成员或角色分组。');
    }
  }

  void _fillMinTemplate() {
    _mindmap.text = groupMindmapMinimalTemplate;
    _mindmap.selection = TextSelection(
      baseOffset: 0,
      extentOffset: groupMindmapMinimalTemplate.length,
    );
    _recognizeMindmap();
  }

  Future<void> _copyMinTemplate() async {
    await Clipboard.setData(
      const ClipboardData(text: groupMindmapMinimalTemplate),
    );
    if (!mounted) return;
    showCupertinoDialog<void>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('已复制'),
        content: const Text('最小模板已复制，可粘贴给 Agent 或编辑框。'),
        actions: [
          CupertinoDialogAction(
            child: const Text('好'),
            onPressed: () => Navigator.pop(ctx),
          ),
        ],
      ),
    );
  }

  Future<void> _applyUnifiedApi() async {
    final profiles = widget.shiyi.apiProfiles;
    if (profiles.isEmpty) {
      if (!mounted) return;
      showCupertinoDialog(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: const Text('没有可用配置'),
          content: const Text('请先在设置页添加至少一个 API 配置。'),
          actions: [
            CupertinoDialogAction(
              child: const Text('好'),
              onPressed: () => Navigator.pop(ctx),
            ),
          ],
        ),
      );
      return;
    }
    if (!mounted) return;
    final selected = await showCupertinoModalPopup<ApiProfile>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('选择 API 配置'),
        actions: [
          for (final p in profiles)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(ctx, p),
              child: Text('${p.name} · ${p.model}'),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    var model = selected.model;
    final models = widget.shiyi.cachedModelsForProfile(selected);
    if (models.isNotEmpty) {
      final chosen = await showIosFadeModalPopup<String>(
        context: context,
        builder: (ctx) => CupertinoActionSheet(
          title: Text('选择模型 · ${selected.name}'),
          actions: [
            for (final item in models)
              CupertinoActionSheetAction(
                onPressed: () => Navigator.pop(ctx, item),
                child: Text(item),
              ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ),
      );
      if (chosen == null || !mounted) return;
      model = chosen;
    }
    setState(() {
      _unifiedProfileId = selected.profileId;
      _unifiedModel = model;
      for (var i = 0; i < _agents.length; i++) {
        _agents[i] = _agents[i].copyWith(
          apiProfileId: selected.profileId,
          model: model,
        );
      }
    });
  }

  void _fillFromMindmap() {
    var parsed = _parsed;
    if (parsed == null || parsed.isEmpty) {
      parsed = parseGroupMindmap(_mindmap.text);
      setState(() => _parsed = parsed);
    }
    if (parsed.isEmpty) {
      _showAlert('没认出 Agent', '检查一下角色区，确保有成员或角色分组。');
      return;
    }
    final agents = _agentsFromParse(parsed);
    if (agents.isEmpty) {
      _showAlert('没有可填入的 Agent', '先正确识别角色，再点击填入。');
      return;
    }
    setState(() {
      _agents = agents;
      if (parsed!.title.trim().isNotEmpty) {
        _title.text = parsed.title.trim();
      }
    });
    if (!mounted) return;
    final profileHint = _defaultProfile == null
        ? '还没有默认 API，保存前可给每个人补接口。'
        : '每人先用 ${_defaultProfile!.name} · $_defaultModel，之后可单独改。';
    _showAlert('已填入 ${agents.length} 个 Agent', profileHint);
  }

  Future<void> _editAgent(GroupAgent agent, int index) async {
    _closeAgentSwipe();
    final next = await Navigator.push<GroupAgent>(
      context,
      MacPageRoute(
        builder: (_) => _GroupAgentEditScreen(
          shiyi: widget.shiyi,
          agent: agent,
          teammates: _agents,
        ),
      ),
    );
    if (next == null || !mounted) return;
    setState(() {
      _agents[index] = next;
      _agents = groupChatSanitizeOrg(_agents);
    });
  }

  void _closeAgentSwipe() {
    _openSwipeKey.value = null;
    if (mounted) setState(() => _openSwipeRect = null);
  }

  void _onOpenSwipeRectChanged(Rect? rect) {
    if (mounted) setState(() => _openSwipeRect = rect);
  }

  Future<void> _removeAgent(int index) async {
    if (_agents.length <= 1) return;
    final removed = _agents[index];
    setState(() {
      _agents = groupChatSanitizeOrg([
        for (final agent in _agents)
          if (agent.id != removed.id)
            agent.reportsToId == removed.id
                ? agent.copyWith(reportsToId: removed.reportsToId)
                : agent,
      ]);
    });
    await GroupChatStore.instance.saveAgents(_roomId, _agents);
  }

  String get _projectLabel {
    final id = _projectId;
    if (id.isEmpty) return '未分类';
    for (final p in widget.shiyi.projects) {
      if (p.id == id) return p.name;
    }
    return '未分类';
  }

  Future<void> _pickProject() async {
    final selected = await showGroupProjectPicker(
      context,
      widget.shiyi,
      currentProjectId: _projectId.isEmpty ? null : _projectId,
    );
    if (selected == null || !mounted) return;
    setState(() => _projectId = selected);
  }

  Future<void> _save() async {
    final title = _title.text.trim().isEmpty
        ? _agents.map((a) => a.name.trim()).where((n) => n.isNotEmpty).join('、')
        : _title.text.trim();
    if (_agents.isEmpty) {
      _showAlert('至少加一个 Agent', '请先添加成员后再保存。');
      return;
    }
    for (final agent in _agents) {
      if (agent.name.trim().isEmpty) {
        _showAlert('每个 Agent 都要有名字', '请补齐成员名字后再保存。');
        return;
      }
    }
    setState(() => _saving = true);
    final now = DateTime.now().millisecondsSinceEpoch;
    final agents = groupChatSanitizeOrg(_agents);
    final room = GroupRoom(
      id: _roomId,
      title: title.isEmpty ? '群聊' : title,
      createdAt: _createdAt,
      updatedAt: now,
      agents: agents,
      projectId: _projectId,
    );
    await GroupChatStore.instance.upsertRoom(room);
    await GroupChatStore.instance.saveAgents(_roomId, agents);
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MacBackFade(
      child: CupertinoTheme(
        data: iosCupertinoTheme(context),
        child: Scaffold(
          backgroundColor: iosGroupedBackground(context),
          appBar: AppBar(
            leadingWidth: 72,
            leading: Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Platform.isWindows
                  ? MacActionButton(
                      icon: CupertinoIcons.chevron_left,
                      tooltip: '返回',
                      onTap: () => Navigator.pop(context),
                    )
                  : TrafficLightsButton(
                      busy: false,
                      tooltip: '返回',
                      onTap: () => Navigator.pop(context),
                    ),
            ),
            toolbarHeight: 64,
            centerTitle: true,
            backgroundColor: theme.scaffoldBackgroundColor,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            clipBehavior: Clip.none,
            title: Text(
              _isEdit ? '编辑群聊' : '新建群聊',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const CupertinoActivityIndicator()
                      : const Text(
                          '保存',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),
            ],
          ),
          body: Stack(
            children: [
              ListView(
                padding: const EdgeInsets.only(top: 8, bottom: 28),
                children: [
                  CupertinoListSection.insetGrouped(
                    margin: iosSectionMargin,
                    decoration: iosSectionDecoration(context),
                    header: const Text('群聊'),
                    children: [
                      IosLabeledField(
                        icon: CupertinoIcons.textformat,
                        color: const Color(0xFF0A84FF),
                        title: '名称',
                        controller: _title,
                        placeholder: '群聊名称',
                      ),
                      CupertinoListTile(
                        leading: const IosIconTile(
                          icon: CupertinoIcons.folder,
                          color: Color(0xFF5856D6),
                        ),
                        title: const Text('项目文件夹'),
                        subtitle: Text(_projectLabel),
                        trailing: const CupertinoListTileChevron(),
                        onTap: _pickProject,
                      ),
                    ],
                  ),
                  CupertinoListSection.insetGrouped(
                    margin: iosSectionMargin,
                    decoration: iosSectionDecoration(context),
                    header: const Text('从思维导图导入'),
                    children: [
                      IosLabeledField(
                        icon: CupertinoIcons.map_fill,
                        color: const Color(0xFF30B0C7),
                        title: '思维导图',
                        controller: _mindmap,
                        placeholder: '粘贴 mermaid 或字符图…',
                        minLines: 5,
                        maxLines: 10,
                        vertical: true,
                      ),
                      CupertinoListTile(
                        leading: const IosIconTile(
                          icon: CupertinoIcons.doc_on_doc,
                          color: Color(0xFF30B0C7),
                        ),
                        title: const Text('最小模板'),
                        subtitle: const Text('主编 + 写手，可复制给 Agent'),
                        trailing: CupertinoButton(
                          padding: EdgeInsets.zero,
                          onPressed: _copyMinTemplate,
                          child: const Text('复制'),
                        ),
                        onTap: _fillMinTemplate,
                      ),
                    ],
                  ),
                  CupertinoListSection.insetGrouped(
                    margin: iosSectionMargin,
                    decoration: iosSectionDecoration(context),
                    footer: _sectionFooter(
                      '粘贴 mermaid 或字符思维导图。先识别预览，点填入才替换成员，不会自动保存。每人先套当前默认 API 和模型。内置「最小模板」可一键填入或复制给 Agent。',
                    ),
                    children: [
                      CupertinoListTile(
                        leading: const IosIconTile(
                          icon: CupertinoIcons.search,
                          color: Color(0xFF8E8E93),
                        ),
                        title: const Text('识别'),
                        trailing: const CupertinoListTileChevron(),
                        onTap: _recognizeMindmap,
                      ),
                      if (_parsed != null) _mindmapPreview(),
                      if (_parsed != null && !_parsed!.isEmpty)
                        CupertinoListTile(
                          leading: const BaguaIcon(
                            size: 31,
                            color: kHomeGroupAccent,
                          ),
                          title: Text(
                            '填入 ${_agentsFromParse(_parsed!).length} 个 Agent',
                          ),
                          trailing: const CupertinoListTileChevron(),
                          onTap: _fillFromMindmap,
                        ),
                    ],
                  ),
                  CupertinoListSection.insetGrouped(
                    margin: iosSectionMargin,
                    decoration: iosSectionDecoration(context),
                    header: const Text('组织架构'),
                    footer: _sectionFooter(
                      '用户默认只对接负责人。其他人被 @ 或由上级安排后才发言，说完向直接上级汇报。',
                    ),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                        child: Text(
                          groupChatOrgLines(_agents).join('\n'),
                          style: const TextStyle(fontSize: 15, height: 1.55),
                        ),
                      ),
                    ],
                  ),
                  CupertinoListSection.insetGrouped(
                    margin: iosSectionMargin,
                    decoration: iosSectionDecoration(context),
                    header: const Text('统一 API'),
                    footer: _sectionFooter(
                      '一键把选中的 API 配置和模型应用到所有 Agent。单独设置过的 Agent 不受影响。',
                    ),
                    children: [
                      CupertinoListTile(
                        leading: const IosIconTile(
                          icon: CupertinoIcons.globe,
                          color: Color(0xFF0A84FF),
                        ),
                        title: const Text('统一 API 配置'),
                        subtitle: Text(
                          _unifiedProfileId.isNotEmpty
                              ? '已应用到全部 Agent · $_unifiedModel'
                              : '点击选择配置',
                        ),
                        trailing: const CupertinoListTileChevron(),
                        onTap: _applyUnifiedApi,
                      ),
                    ],
                  ),
                  CupertinoListSection.insetGrouped(
                    margin: iosSectionMargin,
                    decoration: iosSectionDecoration(context),
                    header: const Text('Agent'),
                    footer: _sectionFooter('每个 Agent 独立，可自己选接口、名字、职位和人设。'),
                    children: [
                      for (var i = 0; i < _agents.length; i++)
                        AgentSwipeDelete(
                          key: ValueKey('agent_row_${_agents[i].id}'),
                          openNotifier: _openSwipeKey,
                          swipeKey: 'agent_${_agents[i].id}',
                          onOpenRectChanged: _onOpenSwipeRectChanged,
                          showDelete: _agents.length > 1,
                          onTap: () => _editAgent(_agents[i], i),
                          onDelete: () async {
                            _openSwipeKey.value = null;
                            final ok = await showIosConfirmDialog(
                              context: context,
                              title: '删除 Agent',
                              message: '删除「${_agents[i].name}」？',
                              confirmLabel: '删除',
                              isDestructiveAction: true,
                            );
                            if (ok && mounted) _removeAgent(i);
                          },
                          child: CupertinoListTile(
                            leading: CircleAvatar(
                              radius: 14,
                              backgroundColor: _agents[i].color,
                              child: Text(
                                groupAgentInitial(_agents[i].name, '${i + 1}'),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            title: Text(_agents[i].name),
                            subtitle: Text(
                              _agentSubtitle(_agents[i], _agents),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: const Icon(
                              CupertinoIcons.chevron_right,
                              size: 16,
                            ),
                          ),
                        ),
                      CupertinoListTile(
                        leading: const IosIconTile(
                          icon: CupertinoIcons.plus,
                          color: Color(0xFF34C759),
                        ),
                        title: const Text('添加 Agent'),
                        trailing: const CupertinoListTileChevron(),
                        onTap: () {
                          final agent = _newAgent(
                            '成员 ${_agents.length}',
                            _agents.length,
                          );
                          setState(() => _agents.add(agent));
                          _editAgent(agent, _agents.length - 1);
                        },
                      ),
                    ],
                  ),
                ],
              ),
              if (_openSwipeRect != null)
                Positioned.fill(
                  child: Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: (e) {
                      final rect = _openSwipeRect;
                      if (rect != null &&
                          !rect.inflate(2).contains(e.position)) {
                        _closeAgentSwipe();
                      }
                    },
                    child: const SizedBox.expand(),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _mindmapPreview() {
    final parsed = _parsed;
    if (parsed == null) return const SizedBox.shrink();
    if (parsed.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Text(
          '没认出 Agent。需要有角色区，例如主编、策划、写手A。',
          style: TextStyle(color: Color(0xFF8E8E93), fontSize: 13),
        ),
      );
    }
    final preview = _agentsFromParse(parsed);
    final minimalCount = parsed.agentsFor(minimal: true).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '识别到 ${parsed.agents.length} 个 Agent',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          if (parsed.note.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              parsed.note,
              style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 13),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            _defaultProfile == null
                ? '还没有默认 API，填入后可给每个人补接口。'
                : '将使用 ${_defaultProfile!.name} · $_defaultModel',
            style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 13),
          ),
          if (parsed.minimalNames.isNotEmpty) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: CupertinoSlidingSegmentedControl<bool>(
                groupValue: _useMinimal,
                children: {
                  false: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text('全部 ${parsed.agents.length} 人'),
                  ),
                  true: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text('最小 $minimalCount 人'),
                  ),
                },
                onValueChanged: (value) {
                  if (value == null) return;
                  setState(() => _useMinimal = value);
                },
              ),
            ),
          ],
          const SizedBox(height: 10),
          Text(
            groupChatOrgLines(preview).join('\n'),
            style: const TextStyle(fontSize: 15, height: 1.55),
          ),
        ],
      ),
    );
  }
}

/// 分组底部说明：Apple 标准的 12 号次级灰，与设置页同一套。
Widget _sectionFooter(String text) {
  return DefaultTextStyle.merge(
    style: const TextStyle(
      fontSize: 12,
      height: 1.35,
      fontWeight: FontWeight.w400,
      color: CupertinoColors.secondaryLabel,
    ),
    child: Text(text),
  );
}

String _agentSubtitle(GroupAgent agent, List<GroupAgent> agents) {
  final supervisor = groupChatAgentById(agent.reportsToId.trim(), agents);
  final desk = supervisor == null ? '对接用户' : '汇报给 ${supervisor.name.trim()}';
  final parts = [
    if (agent.title.trim().isNotEmpty) agent.title.trim(),
    desk,
    if (agent.model.trim().isNotEmpty) agent.model.trim(),
  ];
  return parts.join(' · ');
}

class _GroupAgentEditScreen extends StatefulWidget {
  final ShiyiState shiyi;
  final GroupAgent agent;
  final List<GroupAgent> teammates;
  const _GroupAgentEditScreen({
    required this.shiyi,
    required this.agent,
    required this.teammates,
  });

  @override
  State<_GroupAgentEditScreen> createState() => _GroupAgentEditScreenState();
}

class _GroupAgentEditScreenState extends State<_GroupAgentEditScreen> {
  late final TextEditingController _name;
  late final TextEditingController _title;
  late final TextEditingController _persona;
  late final TextEditingController _model;
  late String _profileId;
  late String _reportsToId;
  late int _colorIndex;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.agent.name);
    _title = TextEditingController(text: widget.agent.title);
    _persona = TextEditingController(text: widget.agent.persona);
    _model = TextEditingController(text: widget.agent.model);
    _profileId = widget.agent.apiProfileId;
    _reportsToId = widget.agent.reportsToId;
    _colorIndex = widget.agent.colorIndex;
  }

  @override
  void dispose() {
    _name.dispose();
    _title.dispose();
    _persona.dispose();
    _model.dispose();
    super.dispose();
  }

  ApiProfile? get _profile {
    for (final profile in widget.shiyi.apiProfiles) {
      if (profile.profileId == _profileId) return profile;
    }
    if (widget.shiyi.apiProfiles.isEmpty) return null;
    return profileMatchingSettings(
          widget.shiyi.settings,
          widget.shiyi.apiProfiles,
        ) ??
        widget.shiyi.apiProfiles.first;
  }

  List<GroupAgent> get _supervisorCandidates => [
    for (final agent in widget.teammates)
      if (groupChatCanReportTo(widget.agent, agent, widget.teammates)) agent,
  ];

  void _commit() {
    Navigator.pop(
      context,
      widget.agent.copyWith(
        name: _name.text.trim().isEmpty ? widget.agent.name : _name.text.trim(),
        title: _title.text.trim(),
        persona: _persona.text,
        apiProfileId: _profile?.profileId ?? _profileId,
        model: _model.text.trim().isEmpty
            ? (_profile?.model ?? '')
            : _model.text.trim(),
        reportsToId: _reportsToId,
        colorIndex: _colorIndex,
      ),
    );
  }

  Future<void> _pickSupervisor() async {
    final chosen = await showIosFadeModalPopup<String>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('选择上级'),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, ''),
            child: const Text('对接用户（负责人）'),
          ),
          for (final agent in _supervisorCandidates)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(ctx, agent.id),
              child: Text(
                agent.title.trim().isEmpty
                    ? agent.name
                    : '${agent.name} · ${agent.title.trim()}',
              ),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() => _reportsToId = chosen);
  }

  Future<void> _pickProfile() async {
    if (widget.shiyi.apiProfiles.isEmpty) {
      showCupertinoDialog<void>(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: const Text('没有可用配置'),
          content: const Text('请先到设置里添加拾忆 API 配置。'),
          actions: [
            CupertinoDialogAction(
              child: const Text('好'),
              onPressed: () => Navigator.pop(ctx),
            ),
          ],
        ),
      );
      return;
    }
    final chosen = await showIosFadeModalPopup<ApiProfile>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('选择 API 配置'),
        actions: [
          for (final profile in widget.shiyi.apiProfiles)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(ctx, profile),
              child: Text(profile.name),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() {
      _profileId = chosen.profileId;
      if (_model.text.trim().isEmpty) _model.text = chosen.model;
    });
  }

  Future<void> _pickModel() async {
    final profile = _profile;
    final models = profile == null
        ? const <String>[]
        : widget.shiyi.cachedModelsForProfile(profile);
    if (models.isEmpty) {
      showCupertinoDialog<void>(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: const Text('没有可用模型'),
          content: const Text('当前配置还没有模型列表，请先刷新或检查 API 配置。'),
          actions: [
            CupertinoDialogAction(
              child: const Text('好'),
              onPressed: () => Navigator.pop(ctx),
            ),
          ],
        ),
      );
      return;
    }
    final chosen = await showIosFadeModalPopup<String>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('选择模型'),
        actions: [
          for (final model in models)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(ctx, model),
              child: Text(model),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() => _model.text = chosen);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profile = _profile;
    final supervisor = groupChatAgentById(_reportsToId, widget.teammates);
    return MacBackFade(
      child: CupertinoTheme(
        data: iosCupertinoTheme(context),
        child: Scaffold(
          backgroundColor: iosGroupedBackground(context),
          appBar: AppBar(
            leadingWidth: 72,
            leading: Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Platform.isWindows
                  ? MacActionButton(
                      icon: CupertinoIcons.chevron_left,
                      tooltip: '返回',
                      onTap: () => Navigator.pop(context),
                    )
                  : TrafficLightsButton(
                      busy: false,
                      tooltip: '返回',
                      onTap: () => Navigator.pop(context),
                    ),
            ),
            toolbarHeight: 64,
            centerTitle: true,
            backgroundColor: theme.scaffoldBackgroundColor,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            title: const Text(
              'Agent',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  onPressed: _commit,
                  child: const Text(
                    '完成',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.only(top: 8, bottom: 28),
            children: [
              CupertinoListSection.insetGrouped(
                margin: iosSectionMargin,
                decoration: iosSectionDecoration(context),
                header: const Text('身份'),
                children: [
                  IosLabeledField(
                    icon: CupertinoIcons.person_fill,
                    color: const Color(0xFF0A84FF),
                    title: '名字',
                    controller: _name,
                    placeholder: '名字',
                  ),
                  IosLabeledField(
                    icon: CupertinoIcons.briefcase_fill,
                    color: const Color(0xFFAF52DE),
                    title: '职位',
                    controller: _title,
                    placeholder: '例如项目经理',
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                    child: Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        for (var i = 0; i < groupAgentPalette.length; i++)
                          GestureDetector(
                            onTap: () => setState(() => _colorIndex = i),
                            child: CircleAvatar(
                              radius: 12,
                              backgroundColor: groupAgentPalette[i],
                              child: _colorIndex == i
                                  ? const Icon(
                                      CupertinoIcons.checkmark,
                                      size: 14,
                                      color: Colors.white,
                                    )
                                  : null,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              CupertinoListSection.insetGrouped(
                margin: iosSectionMargin,
                decoration: iosSectionDecoration(context),
                header: const Text('对接关系'),
                footer: _sectionFooter('对接用户的人是负责人；其他人只向自己的直接上级汇报。'),
                children: [
                  CupertinoListTile(
                    leading: const IosIconTile(
                      icon: CupertinoIcons.arrow_up_circle_fill,
                      color: Color(0xFF0A84FF),
                    ),
                    title: const Text('上级'),
                    additionalInfo: Text(
                      supervisor == null ? '对接用户' : supervisor.name,
                      style: const TextStyle(color: Color(0xFF8E8E93)),
                    ),
                    trailing: const CupertinoListTileChevron(),
                    onTap: _pickSupervisor,
                  ),
                ],
              ),
              CupertinoListSection.insetGrouped(
                margin: iosSectionMargin,
                decoration: iosSectionDecoration(context),
                header: const Text('接口'),
                footer: _sectionFooter('每个 Agent 用自己的拾忆 API 配置，互不影响。'),
                children: [
                  CupertinoListTile(
                    leading: const IosIconTile(
                      icon: CupertinoIcons.square_stack_3d_up_fill,
                      color: Color(0xFF5856D6),
                    ),
                    title: const Text('API 配置'),
                    additionalInfo: Text(
                      profile?.name ?? '未选择',
                      style: const TextStyle(color: Color(0xFF8E8E93)),
                    ),
                    trailing: const CupertinoListTileChevron(),
                    onTap: _pickProfile,
                  ),
                  IosLabeledField(
                    icon: CupertinoIcons.bolt_fill,
                    color: const Color(0xFF34C759),
                    title: '模型',
                    controller: _model,
                    placeholder: profile?.model.isEmpty ?? true
                        ? '模型 ID'
                        : profile!.model,
                    onTap: _pickModel,
                  ),
                ],
              ),
              CupertinoListSection.insetGrouped(
                margin: iosSectionMargin,
                decoration: iosSectionDecoration(context),
                header: const Text('人设提示词'),
                footer: _sectionFooter('只作用于这个 Agent，不会改拾忆全局人设。'),
                children: [
                  IosLabeledField(
                    icon: CupertinoIcons.doc_text_fill,
                    color: const Color(0xFFFF9F0A),
                    title: '提示词',
                    controller: _persona,
                    placeholder: '例如：你是犀利的产品经理，说话短、直接、爱追问。',
                    minLines: 6,
                    maxLines: 12,
                    vertical: true,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
