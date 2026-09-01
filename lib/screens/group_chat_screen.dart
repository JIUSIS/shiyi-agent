import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../core/group_chat.dart';
import '../core/mac_page_route.dart';
import '../core/models.dart';
import '../core/reasoning_models.dart';
import '../services/group_chat_store.dart';
import '../services/file_workspace.dart';
import '../services/llm_client.dart';
import '../services/termux_runtime.dart';
import '../widgets/bagua_icon.dart';
import '../widgets/chat_liquid_glass.dart';
import '../widgets/ios_style.dart';
import '../widgets/group_project_picker.dart';
import '../widgets/mac_action_button.dart';
import '../widgets/message_bubble.dart';
import '../widgets/traffic_lights_button.dart';
import 'group_chat_setup_screen.dart';

class GroupChatScreen extends StatefulWidget {
  final ShiyiState shiyi;
  final String roomId;
  const GroupChatScreen({super.key, required this.shiyi, required this.roomId});

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _AgentTurnResult {
  final GroupMessage? message;
  final bool failed;

  const _AgentTurnResult({this.message, this.failed = false});
}

class GroupChatActiveRun {
  final String roomId;
  final Set<LlmClient> clients = {};
  bool stopRequested = false;
  bool active = false;
  final ValueNotifier<int> revision = ValueNotifier(0);
  final Map<String, GroupMessage> liveDrafts = {};
  GroupChatActiveRun(this.roomId);
}

final Map<String, GroupChatActiveRun> groupChatActiveRuns = {};

class _GroupChatScreenState extends State<GroupChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _followTail = true;
  final _store = GroupChatStore.instance;
  GroupRoom? _room;
  List<GroupMessage> _messages = [];
  bool _loading = true;
  bool _busy = false;
  bool _compressingContext = false;
  Completer<void>? _roundCompleter;
  final Set<String> _enteredIds = {};
  int _roundCachedTokens = 0;
  int _roundInputTokens = 0;
  bool _roundCacheKnown = false;
  int _sessionCachedTokens = 0;
  int _sessionInputTokens = 0;
  bool _sessionCacheKnown = false;
  bool _thinkingOn = true;
  String _thinkingEffort = '';
  String _unifiedProfileName = '';
  String _unifiedModelId = '';
  final List<String> _pendingImages = [];
  final List<String> _pendingFiles = [];

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_syncFollowTail);
    _reload();
    groupChatActiveRuns.putIfAbsent(
      widget.roomId,
      () => GroupChatActiveRun(widget.roomId),
    );
    final active = groupChatActiveRuns[widget.roomId];
    if (active != null) {
      active.revision.addListener(_onActiveRunRevision);
      if (active.active || active.clients.isNotEmpty) {
        _busy = true;
      }
    }
  }

  @override
  void dispose() {
    _scroll.removeListener(_syncFollowTail);
    groupChatActiveRuns[widget.roomId]?.revision.removeListener(
      _onActiveRunRevision,
    );
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onActiveRunRevision() {
    if (!mounted) return;
    final active = _activeRun;
    final busy = active.active || active.clients.isNotEmpty;
    final wasBusy = _busy;
    setState(() => _busy = busy);
    if (wasBusy && !busy) unawaited(_reload());
  }

  List<GroupMessage> get _visibleMessages {
    final live = [
      for (final draft in _activeRun.liveDrafts.values)
        if (draft.roomId == widget.roomId) draft,
    ];
    if (live.isEmpty) return _messages;
    final liveIds = {for (final draft in live) draft.id};
    final merged = <GroupMessage>[
      for (final message in _messages)
        if (!liveIds.contains(message.id)) message,
      ...live,
    ];
    merged.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return merged;
  }

  void _markDraftChanged() {
    if (mounted) {
      setState(() {});
    } else {
      _activeRun.revision.value++;
    }
  }

  GroupChatActiveRun get _activeRun => groupChatActiveRuns.putIfAbsent(
    widget.roomId,
    () => GroupChatActiveRun(widget.roomId),
  );

  Future<void> _reload() async {
    final room = await _store.getRoom(widget.roomId);
    final messages = await _store.listMessages(widget.roomId);
    if (!mounted) return;
    setState(() {
      _room = room;
      _messages = messages;
      _loading = false;
    });
  }

  Future<void> _editMembers() async {
    final room = _room;
    if (room == null) return;
    final changed = await Navigator.push<bool>(
      context,
      MacPageRoute(
        builder: (_) => GroupChatSetupScreen(shiyi: widget.shiyi, room: room),
      ),
    );
    if (changed == true) await _reload();
  }

  void _insertMention(GroupAgent agent) {
    final token = '@${agent.name} ';
    final text = _input.text;
    if (text.contains('@${agent.name}')) return;
    _input.text = text.isEmpty ? token : '$text$token';
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
    setState(() {});
  }

  Future<void> _send() async {
    final room = _room;
    if (room == null) return;
    final rawText = _input.text.trim();
    final attachmentBlock = _attachmentContext();
    final text = [
      rawText,
      attachmentBlock,
    ].where((part) => part.isNotEmpty).join('\n\n');
    if (text.isEmpty) return;
    if (room.agents.isEmpty) {
      showCupertinoDialog(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: const Text('提示'),
          content: const Text('先去编辑成员，至少加一个 Agent'),
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

    if (_busy) {
      // 忙时先打断当前轮，等它退出后再开新轮，避免用户被锁死。
      _stopRun();
      final prev = _roundCompleter;
      if (prev != null) await prev.future;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final user = GroupMessage(
      id: groupChatNewId('gm'),
      roomId: room.id,
      role: 'user',
      content: text,
      createdAt: now,
    );
    _input.clear();
    _pendingFiles.clear();
    _pendingImages.clear();
    final completer = Completer<void>();
    _roundCompleter = completer;
    setState(() {
      _messages = [..._messages, user];
      _busy = true;
      _activeRun.stopRequested = false;
      _activeRun.active = true;
      _roundCachedTokens = 0;
      _roundInputTokens = 0;
      _roundCacheKnown = false;
    });
    try {
      await _store.insertMessage(user);
      _jumpToLatest(force: true);
      final reworkCounts = <String, int>{};
      final queue = [...groupChatInitialTargets(text, room.agents)];
      var emptySpins = 0;
      while (queue.isNotEmpty && !_activeRun.stopRequested) {
        final batch = <GroupAgent>[];
        while (batch.length < groupChatMaxParallelAgents && queue.isNotEmpty) {
          final agent = queue.removeAt(0);
          batch.add(agent);
        }
        if (batch.isEmpty) continue;
        final results = await Future.wait([
          for (final agent in batch) _runAgent(agent),
        ]);
        if (_activeRun.stopRequested) break;
        if (results.any((result) => result.failed)) break;
        final progressed = results.any(
          (result) =>
              result.message != null &&
              (result.message!.content.trim().isNotEmpty ||
                  result.message!.reasoning.trim().isNotEmpty),
        );
        final followups = groupChatNextFollowupTargets(
          speakers: batch,
          replies: [for (final result in results) result.message],
          agents: room.agents,
        );
        if (!progressed && followups.isNotEmpty) {
          emptySpins++;
          if (emptySpins >= 3) break;
        } else if (progressed) {
          emptySpins = 0;
        }
        for (final followup in followups) {
          if (followup.isRework) {
            final count = (reworkCounts[followup.handoffKey] ?? 0) + 1;
            reworkCounts[followup.handoffKey] = count;
            if (count > groupChatMaxReworksPerHandoff) continue;
          }
          if (queue.any((item) => item.id == followup.target.id)) continue;
          queue.add(followup.target);
        }
      }
    } finally {
      _activeRun.active = false;
      if (mounted) {
        setState(() => _busy = false);
      } else {
        _activeRun.revision.value++;
      }
      if (!completer.isCompleted) completer.complete();
    }
  }

  String _attachmentContext() {
    if (_pendingFiles.isEmpty && _pendingImages.isEmpty) return '';
    final parts = <String>[
      for (final path in _pendingFiles) path,
      for (final path in _pendingImages) path,
    ];
    return '已附加文件，可用 file_read 或 run_terminal 读取：\n${parts.join('\n')}';
  }

  Future<_AgentTurnResult> _runAgent(GroupAgent agent) async {
    final room = _room;
    if (room == null) return const _AgentTurnResult();
    final profile = groupChatProfileFor(
      agent,
      widget.shiyi.apiProfiles,
      fallback: widget.shiyi.apiProfiles.isEmpty
          ? ApiProfile(
              name: '当前',
              baseUrl: widget.shiyi.settings.baseUrl,
              apiKey: widget.shiyi.settings.apiKey,
              model: widget.shiyi.settings.model,
              apiProtocol: widget.shiyi.settings.apiProtocol,
            )
          : null,
    );
    if (profile == null || profile.baseUrl.trim().isEmpty) {
      final message = '${agent.name} 还没有可用的 API 配置';
      if (mounted) {
        showCupertinoDialog(
          context: context,
          builder: (ctx) => CupertinoAlertDialog(
            title: Text(agent.name),
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
      return _AgentTurnResult(
        failed: true,
        message: await _failedDraft(room, agent, message),
      );
    }
    final model = agent.model.trim().isEmpty ? profile.model : agent.model;
    if (model.trim().isEmpty) {
      final message = '${agent.name} 还没有模型 ID';
      if (mounted) {
        showCupertinoDialog(
          context: context,
          builder: (ctx) => CupertinoAlertDialog(
            title: Text(agent.name),
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
      return _AgentTurnResult(
        failed: true,
        message: await _failedDraft(room, agent, message),
      );
    }
    return _runAgentWithTools(room, agent, profile, model);
  }

  Future<_AgentTurnResult> _runAgentWithTools(
    GroupRoom room,
    GroupAgent agent,
    ApiProfile profile,
    String model,
  ) async {
    final draft = GroupMessage(
      id: groupChatNewId('gm'),
      roomId: room.id,
      role: 'agent',
      agentId: agent.id,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      streaming: true,
    );
    _activeRun.liveDrafts[draft.id] = draft;
    _markDraftChanged();
    _jumpToLatest();
    final settings = widget.shiyi.settings;
    final workingDir = await _projectWorkingDir(room.projectId);
    final tools = _groupChatTools();
    final contextSummary = await _store.getSummary(room.id, agent.id);
    String? failure;
    final loopMsgs = groupChatApiMessages(
      speaker: agent,
      agents: room.agents,
      history: _messages.where((m) => m.id != draft.id).toList(),
      contextSummary: contextSummary,
    );
    const maxToolRounds = 8;
    var roundCached = 0;
    var roundInput = 0;
    try {
      for (var round = 0; round < maxToolRounds; round++) {
        TurnResult? lastTurn;
        final client = LlmClient(
          baseUrl: profile.baseUrl,
          apiKey: profile.apiKey,
          model: model,
          protocol: profile.apiProtocol,
          sessionId: room.id,
          temperature: settings.temperature,
          maxTokens: settings.maxOutputTokens,
          tools: tools,
          reasoningEffortOverride: _thinkingOn
              ? ReasoningModels.defaultEffort(model)
              : 'off',
          shouldStop: () => _activeRun.stopRequested,
          onTurn: (turn) {
            lastTurn = turn;
            draft.content = turn.text;
            draft.reasoning = turn.reasoning;
            _markDraftChanged();
            _jumpToLatest();
          },
        );
        _activeRun.clients.add(client);
        try {
          await client.send(loopMsgs);
          final c = client.lastCachedTokens ?? 0;
          final i = client.lastPromptTokens ?? client.lastInputTokens ?? 0;
          roundCached += c.clamp(0, i).toInt();
          roundInput += i;
        } finally {
          _activeRun.clients.remove(client);
        }

        final result = lastTurn;
        if (result == null) break;
        draft.content = result.text;
        draft.reasoning = result.reasoning;
        _markDraftChanged();

        final hasTools = result.toolCalls.isNotEmpty;
        if (!hasTools) break;

        // Record tool_calls in the assistant message.
        loopMsgs.add({
          'role': 'assistant',
          'content': result.text,
          if (result.reasoning.isNotEmpty)
            'reasoning_content': result.reasoning,
          'tool_calls': [
            for (final tc in result.toolCalls)
              {
                'id': tc['id'] ?? 'call_${groupChatNewId('tc')}',
                'type': 'function',
                'function': {'name': tc['name'], 'arguments': tc['arguments']},
              },
          ],
        });

        // Execute each tool call.
        for (final tc in result.toolCalls) {
          final toolId = tc['id'] ?? 'call_${groupChatNewId('tc')}';
          final output = await _executeGroupTool(
            tc['name'] ?? '',
            tc['arguments'] ?? '{}',
            workingDir: workingDir,
          );
          loopMsgs.add({
            'role': 'tool',
            'content': output,
            'tool_call_id': toolId,
          });
        }
      }
    } on LlmCancelledException {
      // 用户点了停止，保留已经流出来的内容。
    } catch (e) {
      failure = e.toString();
      final text = draft.content.trim();
      draft.content = text.isEmpty ? '回复失败：$failure' : '$text\n\n回复失败：$failure';
    }
    _roundCachedTokens += roundCached;
    _roundInputTokens += roundInput;
    if (roundInput > 0) _roundCacheKnown = true;
    _sessionCachedTokens += roundCached;
    _sessionInputTokens += roundInput;
    if (roundInput > 0) _sessionCacheKnown = true;
    _markDraftChanged();
    draft.streaming = false;
    if (failure == null &&
        draft.content.trim().isEmpty &&
        draft.reasoning.trim().isEmpty) {
      failure = '模型返回为空';
      draft.content = '回复失败：$failure';
    }
    if (failure != null && draft.content.trim().isEmpty) {
      draft.content = '回复失败：$failure';
    }
    if (failure == null &&
        draft.content.trim().isEmpty &&
        draft.reasoning.trim().isEmpty) {
      _activeRun.liveDrafts.remove(draft.id);
      _markDraftChanged();
      return const _AgentTurnResult(failed: true);
    }
    await _store.insertMessage(draft);
    if (mounted) {
      setState(() {
        _activeRun.liveDrafts.remove(draft.id);
        _messages = [..._messages, draft];
      });
    } else {
      _activeRun.liveDrafts.remove(draft.id);
      _activeRun.revision.value++;
    }
    _jumpToLatest();
    return _AgentTurnResult(message: draft, failed: failure != null);
  }

  Future<GroupMessage?> _failedDraft(
    GroupRoom room,
    GroupAgent agent,
    String message,
  ) async {
    final draft = GroupMessage(
      id: groupChatNewId('gm'),
      roomId: room.id,
      role: 'agent',
      agentId: agent.id,
      content: message,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _store.insertMessage(draft);
    if (mounted) {
      setState(() => _messages = [..._messages, draft]);
      _jumpToLatest();
    } else {
      _activeRun.revision.value++;
    }
    return draft;
  }

  Future<String> _projectWorkingDir(String projectId) async {
    if (projectId.isNotEmpty) {
      for (final project in widget.shiyi.projects) {
        if (project.id == projectId && project.workspaceDir.trim().isNotEmpty) {
          return project.workspaceDir;
        }
      }
    }
    return FileWorkspace.ensure();
  }

  List<Map<String, dynamic>> _groupChatTools() {
    return [
      {
        'type': 'function',
        'function': {
          'name': 'file_read',
          'description': '读取文本文件内容（最大200KB）。相对路径基于项目工作目录。',
          'parameters': {
            'type': 'object',
            'properties': {
              'path': {'type': 'string', 'description': '文件路径'},
            },
            'required': ['path'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'file_write',
          'description': '把文本内容写入文件（自动创建父目录）。用于保存生成的内容。',
          'parameters': {
            'type': 'object',
            'properties': {
              'path': {'type': 'string', 'description': '文件路径'},
              'content': {'type': 'string', 'description': '完整内容'},
            },
            'required': ['path', 'content'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'run_terminal',
          'description':
              '执行 shell 命令并返回输出。默认工作目录是项目目录。'
              '你可以用这个工具运行脚本、查看文件列表、安装依赖等。',
          'parameters': {
            'type': 'object',
            'properties': {
              'command': {'type': 'string', 'description': '要执行的 shell 命令'},
            },
            'required': ['command'],
          },
        },
      },
    ];
  }

  Future<String> _executeGroupTool(
    String name,
    String argsJson, {
    required String workingDir,
  }) async {
    Map<String, dynamic> args = {};
    try {
      args = jsonDecode(argsJson) as Map<String, dynamic>;
    } catch (_) {}
    try {
      switch (name) {
        case 'file_read':
          final path = args['path']?.toString() ?? '';
          if (path.isEmpty) return '错误：path 不能为空';
          final file = File(
            path.startsWith('/') || path.contains(':')
                ? path
                : workingDir.isEmpty
                ? path
                : '$workingDir/$path',
          );
          if (!file.existsSync()) return '文件不存在: $path';
          final content = await file.readAsString();
          if (content.length > 200 * 1024) {
            return content.substring(0, 200 * 1024) + '\n（截断，超过200KB）';
          }
          return content;
        case 'file_write':
          final path = args['path']?.toString() ?? '';
          final content = args['content']?.toString() ?? '';
          if (path.isEmpty) return '错误：path 不能为空';
          final file = File(
            path.startsWith('/') || path.contains(':')
                ? path
                : workingDir.isEmpty
                ? path
                : '$workingDir/$path',
          );
          await file.parent.create(recursive: true);
          await file.writeAsString(content);
          return '已写入: ${file.path} (${content.length} chars)';
        case 'run_terminal':
          final command = args['command']?.toString() ?? '';
          if (command.isEmpty) return '错误：command 不能为空';
          return _runGroupTerminal(command, workingDir);
        default:
          return '未知工具: $name';
      }
    } catch (e) {
      return '工具 $name 执行失败: $e';
    }
  }

  Future<String> _runGroupTerminal(String command, String workingDir) async {
    try {
      final settings = widget.shiyi.settings;
      final cwd = workingDir.trim().isEmpty ? null : workingDir.trim();
      final String shell;
      final List<String> args;
      Map<String, String>? environment;
      var backendWarn = '';
      if (TermuxRuntime.isWindows) {
        final backend = await TermuxRuntime.resolveWindowsBackend(
          settings.terminalBackend,
        );
        switch (backend) {
          case 'wsl2':
            shell = 'wsl.exe';
            args = ['-e', 'bash', '-lc', command];
            environment = const {'WSL_UTF8': '1'};
          case 'gitbash':
            shell =
                await TermuxRuntime.gitBashPath() ??
                r'C:\Program Files\Git\bin\bash.exe';
            args = ['--login', '-c', command];
          case 'cmd':
            shell = 'cmd';
            args = ['/c', command];
          default:
            shell = 'pwsh';
            args = [
              '-NoProfile',
              '-NoLogo',
              '-NonInteractive',
              '-Command',
              command,
            ];
        }
        if (settings.terminalBackend == 'wsl2' && backend != 'wsl2') {
          backendWarn = '（你选择了 WSL2，但当前不可用，已回退 $backend）';
        } else if (settings.terminalBackend == 'gitbash' &&
            backend != 'gitbash') {
          backendWarn = '（你选择了 Git Bash，但当前不可用，已回退 $backend）';
        }
      } else {
        await TermuxRuntime.ensureInstalled();
        final argv = await TermuxRuntime.shellCommand(['-c', command]);
        shell = argv.first;
        args = argv.sublist(1);
        environment = await TermuxRuntime.environment();
      }
      final proc = await Process.start(
        shell,
        args,
        workingDirectory: cwd,
        environment: environment,
      );
      final stdoutFuture = proc.stdout.transform(utf8.decoder).join();
      final stderrFuture = proc.stderr.transform(utf8.decoder).join();
      int? exitCode;
      try {
        exitCode = await proc.exitCode.timeout(const Duration(seconds: 60));
      } on TimeoutException {
        proc.kill();
        return '终端执行超时（已强制终止）：命令超过 60 秒未完成。';
      }
      final stdout = (await stdoutFuture).trim();
      final stderr = (await stderrFuture).trim();
      final buf = StringBuffer();
      if (stdout.isNotEmpty) buf.write(stdout);
      if (stderr.isNotEmpty) {
        if (buf.isNotEmpty) buf.write('\n');
        buf.write(stderr);
      }
      if (backendWarn.isNotEmpty) {
        if (buf.isNotEmpty) buf.write('\n');
        buf.write(backendWarn);
      }
      return buf.isEmpty ? '命令执行完成（无输出），退出码 $exitCode' : '退出码 $exitCode\n$buf';
    } on ProcessException catch (e) {
      return '终端执行异常: ${e.message}';
    } catch (e) {
      return '终端执行失败: $e';
    }
  }

  void _stopRun() {
    _activeRun.stopRequested = true;
    _activeRun.active = false;
    for (final client in List.of(_activeRun.clients)) {
      client.cancel();
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _pickAttachment() async {
    if (!mounted) return;
    showIosFadeModalPopup<void>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('添加附件'),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(ctx);
              _pickGroupFile();
            },
            child: const Text('发送文件'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
      ),
    );
  }

  Future<void> _pickGroupFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(allowMultiple: true);
      if (result == null || result.files.isEmpty) return;
      final room = _room;
      if (room == null) return;
      final workingDir = await _projectWorkingDir(room.projectId);
      var added = 0;
      for (final file in result.files) {
        final src = file.path;
        if (src == null || !mounted) return;
        final dest = await FileWorkspace.copyToAttachments(
          src,
          workspacePath: workingDir,
        );
        if (dest == null) continue;
        setState(() => _pendingFiles.add(dest));
        added++;
      }
      if (added == 0 && mounted) {
        showCupertinoDialog(
          context: context,
          builder: (ctx) => CupertinoAlertDialog(
            title: const Text('添加附件失败'),
            content: const Text('文件复制到项目目录失败，请检查项目文件夹。'),
            actions: [
              CupertinoDialogAction(
                child: const Text('好'),
                onPressed: () => Navigator.pop(ctx),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      showCupertinoDialog(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: const Text('添加附件失败'),
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          actions: [
            CupertinoDialogAction(
              child: const Text('好'),
              onPressed: () => Navigator.pop(ctx),
            ),
          ],
        ),
      );
    }
  }

  void _onUnifiedModelChanged(SessionModelSelection selection) {
    setState(() {
      _unifiedProfileName = selection.profile;
      _unifiedModelId = selection.model;
    });
    final room = _room;
    if (room == null) return;
    for (final p in widget.shiyi.apiProfiles) {
      if (p.name == selection.profile) {
        setState(() {
          for (var i = 0; i < room.agents.length; i++) {
            room.agents[i] = room.agents[i].copyWith(
              apiProfileId: p.profileId,
              model: selection.model,
            );
          }
        });
        unawaited(_store.saveAgents(widget.roomId, room.agents));
        break;
      }
    }
  }

  int _estimateTokens(String text) => (text.trim().length / 4).ceil();

  int _agentContextTokens(GroupAgent agent) {
    final room = _room;
    if (room == null) return 0;
    final messages = groupChatApiMessages(
      speaker: agent,
      agents: room.agents,
      history: _messages,
    );
    return messages.fold(
      0,
      (sum, message) => sum + _estimateTokens('${message['content'] ?? ''}'),
    );
  }

  String get _contextLabel => '${_visibleMessages.length}条';

  Future<void> _openAgentContext() async {
    final room = _room;
    if (room == null || room.agents.isEmpty) return;
    final selected = await showIosFadeModalPopup<GroupAgent>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('选择要压缩上下文的成员'),
        actions: [
          for (final agent in room.agents)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(ctx, agent),
              child: Text(
                '${agent.name} · 约 ${_agentContextTokens(agent)} tokens',
              ),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    final ok = await showIosConfirmDialog(
      context: context,
      title: '压缩 ${selected.name} 的上下文？',
      message: '会用这个成员自己的 API，把早期历史整理成摘要。原始消息仍保留在本地。',
      confirmLabel: '压缩',
    );
    if (ok == true && mounted) await _compressAgentContext(selected);
  }

  Future<void> _compressAgentContext(GroupAgent agent) async {
    if (_compressingContext) return;
    final room = _room;
    if (room == null) return;
    final profile = groupChatProfileFor(
      agent,
      widget.shiyi.apiProfiles,
      fallback: widget.shiyi.apiProfiles.isEmpty
          ? ApiProfile(
              name: '当前',
              baseUrl: widget.shiyi.settings.baseUrl,
              apiKey: widget.shiyi.settings.apiKey,
              model: widget.shiyi.settings.model,
              apiProtocol: widget.shiyi.settings.apiProtocol,
            )
          : null,
    );
    final model = agent.model.trim().isEmpty
        ? profile?.model ?? ''
        : agent.model;
    if (profile == null ||
        profile.baseUrl.trim().isEmpty ||
        model.trim().isEmpty) {
      showCupertinoDialog(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: Text(agent.name),
          content: const Text('这个成员还没有可用的 API 配置，无法压缩。'),
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
    setState(() => _compressingContext = true);
    try {
      final summary = await _summarizeAgentHistory(room, agent, profile, model);
      await _store.saveSummary(room.id, agent.id, summary);
      if (!mounted) return;
      showCupertinoDialog(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: const Text('已压缩'),
          content: Text('${agent.name} 的早期历史已整理成摘要，下次发言会自动带上。'),
          actions: [
            CupertinoDialogAction(
              child: const Text('好'),
              onPressed: () => Navigator.pop(ctx),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      showCupertinoDialog(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: const Text('压缩失败'),
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          actions: [
            CupertinoDialogAction(
              child: const Text('好'),
              onPressed: () => Navigator.pop(ctx),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _compressingContext = false);
    }
  }

  Future<String> _summarizeAgentHistory(
    GroupRoom room,
    GroupAgent agent,
    ApiProfile profile,
    String model,
  ) async {
    final messages = groupChatApiMessages(
      speaker: agent,
      agents: room.agents,
      history: _messages,
    );
    messages.add({
      'role': 'user',
      'content':
          '请把以上对话历史压缩成一份简洁中文摘要。只保留：目标任务、已做决定、'
          '产出物路径、未完成事项、关键约束。不要回答问题，直接输出摘要。',
    });
    var summary = '';
    final client = LlmClient(
      baseUrl: profile.baseUrl,
      apiKey: profile.apiKey,
      model: model,
      protocol: profile.apiProtocol,
      sessionId: room.id,
      temperature: widget.shiyi.settings.temperature,
      maxTokens: widget.shiyi.settings.maxOutputTokens,
      tools: const [],
      reasoningEffortOverride: 'off',
      shouldStop: () => _activeRun.stopRequested,
      onTurn: (turn) => summary = turn.text,
    );
    _activeRun.clients.add(client);
    try {
      await client.send(messages);
    } finally {
      _activeRun.clients.remove(client);
    }
    final text = summary.trim();
    if (text.isEmpty) throw Exception('模型未返回摘要');
    return text;
  }

  Future<void> _openProjectPicker() async {
    final room = _room;
    if (room == null || !mounted) return;
    final result = await showGroupProjectPicker(
      context,
      widget.shiyi,
      currentProjectId: room.projectId,
    );
    if (result == null || !mounted) return;
    await _store.setRoomProject(room.id, result);
    room.projectId = result;
    setState(() {});
  }

  bool _shouldAnimateEnter(GroupMessage message) {
    if (_enteredIds.contains(message.id)) return false;
    var should = false;
    if (message.isUser) {
      final now = DateTime.now().millisecondsSinceEpoch;
      should = message.createdAt > 0 && now - message.createdAt < 2500;
    } else if (message.streaming) {
      should = true;
    }
    if (should) _enteredIds.add(message.id);
    return should;
  }

  void _jumpToLatest({bool force = false}) {
    if (!mounted) return;
    if (force) _followTail = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      if (!_followTail) return;
      _scroll.jumpTo(0);
    });
  }

  bool get _nearBottom {
    if (!_scroll.hasClients) return true;
    return _scroll.position.pixels <= 32;
  }

  void _syncFollowTail() {
    _followTail = _nearBottom;
  }

  ChatMessage _asChat(GroupMessage message) => ChatMessage(
    id: message.id,
    sessionId: message.roomId,
    role: message.isUser ? 'user' : 'assistant',
    content: message.content,
    reasoning: message.reasoning,
    createdAt: message.createdAt,
    streaming: message.streaming,
  );

  String _speakerName(GroupMessage message, GroupRoom room) {
    if (message.isUser) return '你';
    final agent = groupChatAgentById(message.agentId, room.agents);
    if (agent == null) return 'Agent';
    final role = agent.title.trim();
    if (role.isEmpty) return agent.name;
    return '${agent.name} · $role';
  }

  Color? _speakerColor(GroupMessage message, GroupRoom room) {
    if (message.isUser) return null;
    return groupChatAgentById(message.agentId, room.agents)?.color;
  }

  Future<void> _copyMessage(ChatMessage message) async {
    await Clipboard.setData(ClipboardData(text: message.content));
  }

  Future<void> _deleteMessage(ChatMessage message) async {
    final ok = await showIosConfirmDialog(
      context: context,
      title: '删除这条消息？',
      message: '删除后不能恢复。',
      confirmLabel: '删除',
      isDestructiveAction: true,
    );
    if (!ok) return;
    await _store.deleteMessage(message.id);
    if (!mounted) return;
    setState(() {
      _messages = [
        for (final item in _messages)
          if (item.id != message.id) item,
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    final room = _room;
    final theme = Theme.of(context);
    final desktop =
        Platform.isWindows && MediaQuery.sizeOf(context).width >= 720;
    return MacBackFade(
      child: CupertinoTheme(
        data: iosCupertinoTheme(context),
        child: ColoredBox(
          color: theme.scaffoldBackgroundColor,
          child: Center(
            child: ConstrainedBox(
              constraints: desktop
                  ? const BoxConstraints(maxWidth: 1080)
                  : const BoxConstraints(),
              child: Scaffold(
                backgroundColor: theme.scaffoldBackgroundColor,
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
                            busy: _busy,
                            tooltip: '返回',
                            onTap: () => Navigator.pop(context),
                          ),
                  ),
                  centerTitle: true,
                  backgroundColor: theme.scaffoldBackgroundColor,
                  surfaceTintColor: Colors.transparent,
                  elevation: 0,
                  scrolledUnderElevation: 0,
                  clipBehavior: Clip.none,
                  toolbarHeight: 64,
                  title: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        room?.title.isEmpty ?? true ? '群聊' : room!.title,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (room != null && room.agents.isNotEmpty)
                        Text(
                          '${room.agents.length} 个 Agent',
                          style: theme.textTheme.bodySmall!.copyWith(
                            color: theme.hintColor,
                          ),
                        ),
                    ],
                  ),
                  actions: [
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: FrostedSettingsButton(onPressed: _editMembers),
                    ),
                  ],
                ),
                body: _loading || room == null
                    ? const Center(child: CupertinoActivityIndicator())
                    : ChatFloatingComposerScaffold(
                        messages: (context, overlayHeight) {
                          if (_visibleMessages.isEmpty) {
                            return Padding(
                              padding: EdgeInsets.only(bottom: overlayHeight),
                              child: const _GroupEmpty(),
                            );
                          }
                          return ScrollConfiguration(
                            behavior: ScrollConfiguration.of(
                              context,
                            ).copyWith(overscroll: false),
                            child: ListView.builder(
                              controller: _scroll,
                              reverse: true,
                              clipBehavior: Clip.none,
                              padding: EdgeInsets.fromLTRB(
                                messageListSidePadding,
                                12,
                                messageListSidePadding,
                                overlayHeight + 12,
                              ),
                              itemCount: _visibleMessages.length,
                              itemBuilder: (context, index) {
                                final message =
                                    _visibleMessages[_visibleMessages.length - 1 - index];
                                return MessageBubble(
                                  key: ValueKey(message.id),
                                  message: _asChat(message),
                                  liveReasoning:
                                      message.streaming &&
                                          message.reasoning.isNotEmpty
                                      ? message.reasoning
                                      : null,
                                  busy: _busy,
                                  animateEnter: _shouldAnimateEnter(message),
                                  speakerName: _speakerName(message, room),
                                  speakerColor: _speakerColor(message, room),
                                  onCopy: _copyMessage,
                                  onDelete: _deleteMessage,
                                );
                              },
                            ),
                          );
                        },
                        overlay: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _mentionsWithStats(room.agents),
                            LiquidGlassChatComposer(
                              input: _input,
                              busy: _busy,
                              allowSendWhileBusy: true,
                              enterToSend: widget.shiyi.settings.enterToSend,
                              pendingImages: _pendingImages,
                              pendingFiles: _pendingFiles,
                              onPickAttachment: _pickAttachment,
                              onRemoveImage: (i) =>
                                  setState(() => _pendingImages.removeAt(i)),
                              onRemoveFile: (i) =>
                                  setState(() => _pendingFiles.removeAt(i)),
                              onSend: _send,
                              onStop: _stopRun,
                              idleHint: '发给对接人，或点名字 @Ta',
                              busyHint: 'Agent 回复中…',
                              showAttachmentButton: true,
                              thinkingOn: _thinkingOn,
                              onThinkingToggled: (v) =>
                                  setState(() => _thinkingOn = v),
                              thinkingOptions: const [
                                ThinkingIntensityOption('', 'Default'),
                                ThinkingIntensityOption('low', 'Low'),
                                ThinkingIntensityOption('medium', 'Medium'),
                                ThinkingIntensityOption('high', 'High'),
                                ThinkingIntensityOption('max', 'Max'),
                              ],
                              thinkingValue: _thinkingEffort,
                              onThinkingChanged: (v) =>
                                  setState(() => _thinkingEffort = v),
                              onContextLimit: _openAgentContext,
                              contextLimitLabel: _contextLabel,
                              compressBusy: _compressingContext,
                              modelOptions: [
                                for (final p in widget.shiyi.apiProfiles)
                                  SessionModelOption(
                                    value: p.name,
                                    label: p.name,
                                    subtitle: p.model,
                                    models: widget.shiyi.cachedModelsForProfile(
                                      p,
                                    ),
                                  ),
                              ],
                              modelValue: _unifiedProfileName,
                              modelId: _unifiedModelId,
                              onModelChanged: _onUnifiedModelChanged,
                              modelEnabled: true,
                              onWorkspacePressed: _openProjectPicker,
                              workspaceTooltip: '项目文件夹',
                            ),
                          ],
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _mentionChips(List<GroupAgent> agents) {
    if (agents.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: ChatComposerChip.height,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final agent in agents)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChatComposerChip(
                tooltip: '点名 ${agent.name}',
                color: agent.color,
                onTap: () => _insertMention(agent),
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: agent.color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text('@${agent.name}'),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _fmt(int n) {
    if (n >= 100000000) return '${(n / 100000000).toStringAsFixed(1)}亿';
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}w';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }

  Widget _groupStatsChip() {
    final theme = Theme.of(context);
    final cacheText = !_sessionCacheKnown || _sessionInputTokens <= 0
        ? '缓存 --'
        : '缓存 ${(_sessionCachedTokens / _sessionInputTokens * 100).round()}%';
    final roundText = !_roundCacheKnown || _roundInputTokens <= 0
        ? '本轮命中 --'
        : '本轮命中 ${_fmt(_roundCachedTokens)}/未缓存 ${_fmt((_roundInputTokens - _roundCachedTokens).clamp(0, _roundInputTokens))}';
    return ChatStatsChip(
      label: cacheText,
      detail: '$cacheText · $roundText',
      color: theme.colorScheme.onSurfaceVariant,
    );
  }

  Widget _mentionsWithStats(List<GroupAgent> agents) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Row(
        children: [
          _groupStatsChip(),
          const SizedBox(width: 8),
          Expanded(child: _mentionChips(agents)),
        ],
      ),
    );
  }
}

class _GroupEmpty extends StatelessWidget {
  const _GroupEmpty();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const BaguaIcon(size: 56, color: CupertinoColors.systemGrey3),
            const SizedBox(height: 12),
            const Text(
              '还没有消息',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            const Text(
              '发给对接人，或点上面的名字 @Ta',
              textAlign: TextAlign.center,
              style: TextStyle(color: CupertinoColors.secondaryLabel),
            ),
          ],
        ),
      ),
    );
  }
}
