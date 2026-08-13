import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/app_state.dart';
import '../core/mac_page_route.dart';
import '../core/models.dart';
import '../services/file_workspace.dart';
import '../services/image_service.dart';
import '../services/tts_service.dart';
import '../widgets/ios_style.dart';
import '../widgets/message_bubble.dart';
import '../widgets/traffic_lights_button.dart';
import '../widgets/welcome_avatar.dart';

const _iosBlue = Color(0xFF0A84FF);
const _iosRed = Color(0xFFFF3B30);
const _iosGreen = Color(0xFF34C759);
const _iosOrange = Color(0xFFFF9500);
const _iosGray = Color(0xFF8E8E93);
const _iosIndigo = Color(0xFF5856D6);

class ChatScreen extends StatefulWidget {
  final ShiyiState shiyi;
  final String? sessionId;
  const ChatScreen({super.key, required this.shiyi, this.sessionId});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen>
    with SingleTickerProviderStateMixin
    implements BackGestureTarget {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  int _lastCount = 0;
  String? _speakingId;

  /// 预测性返回：拖动进度 0~1，1 表示完全缩小悬浮。
  late final AnimationController _dragCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    value: 0,
  );
  MacPageRoute? _route;
  bool _showToolLog = false;
  bool _autoScrollScheduled = false;

  @override
  void initState() {
    super.initState();
    if (widget.sessionId != null &&
        widget.shiyi.currentSessionId != widget.sessionId) {
      widget.shiyi.selectSession(widget.sessionId!);
    }
    // 标记正在查看的会话：回复完成时若用户不在看，主页才显示未读。
    widget.shiyi.viewingSessionId =
        widget.sessionId ?? widget.shiyi.currentSessionId;
    // 打开聊天页时从 DB 恢复 token 统计与上下文估算，避免显示残留/0 值。
    final statsId = widget.sessionId ?? widget.shiyi.currentSessionId;
    if (statsId != null) {
      widget.shiyi.refreshTokenStats(statsId);
    }
    // 流式文本变化只重建正在输出的气泡；这里负责平滑跟随滚动。
    widget.shiyi.streamText.addListener(_onStreamTextChanged);
    TtsService.instance.speakingId.addListener(_onSpeakingChanged);
    TtsService.instance.lastError.addListener(_onTtsError);
    // 输入 @ 时弹出文件/文件夹选择器。
    _input.addListener(_onInputTextChanged);
    _refreshWorkspace();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is MacPageRoute) {
      _route = route;
      route.backGestureTarget = this;
    }
  }

  @override
  void dispose() {
    _route?.backGestureTarget = null;
    _dragCtrl.dispose();
    widget.shiyi.streamText.removeListener(_onStreamTextChanged);
    widget.shiyi.viewingSessionId = null;
    TtsService.instance.speakingId.removeListener(_onSpeakingChanged);
    TtsService.instance.lastError.removeListener(_onTtsError);
    _input.removeListener(_onInputTextChanged);
    _input.dispose();
    super.dispose();
  }

  void _onSpeakingChanged() {
    if (!mounted) return;
    setState(() => _speakingId = TtsService.instance.speakingId.value);
  }

  void _onTtsError() {
    final msg = TtsService.instance.lastError.value;
    if (!mounted || msg == null) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('朗读失败：$msg')));
  }

  /// 回到最新消息（reverse 列表里最新消息在 offset 0，即视觉底部）。
  void _scrollToLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  /// 流式文本变化：每帧最多安排一次跟随滚动，避免 token 高频到达时
  /// addPostFrameCallback/animateTo 队列堆积拖慢 UI 主线程。
  void _onStreamTextChanged() {
    if (_autoScrollScheduled) return;
    _autoScrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoScrollScheduled = false;
      if (!mounted || !_scroll.hasClients) return;
      if (_scroll.position.pixels <= 96) {
        // 流式阶段直接跳到最新位置；连续 animateTo 会反复创建动画控制器并掉帧。
        _scroll.jumpTo(0);
      }
    });
  }

  /// 构建单条消息气泡；liveContent 非空时渲染流式实时文本。
  Widget _messageItem(
    ChatMessage m, {
    String? liveContent,
    String? liveReasoning,
  }) {
    return MessageBubble(
      message: m,
      liveContent: liveContent,
      liveReasoning: liveReasoning,
      busy: widget.shiyi.isBusy,
      speaking: _speakingId == m.id,
      onCopy: _copyMessage,
      onDelete: _confirmDelete,
      onRegenerate: _confirmRegenerate,
      onSpeak: _speakMessage,
      onStopSpeak: _stopSpeak,
      onSaveMemory: (msg) async {
        final messenger = ScaffoldMessenger.of(context);
        await widget.shiyi.addMemoryManual(msg.content);
        messenger.showSnackBar(const SnackBar(content: Text('已保存到长期记忆')));
      },
      onSaveSkill: (msg) {
        _saveSkillDialog(msg.content);
      },
    );
  }

  /// 新消息加入时自动跟随到底部；流式文本增长由 [_onStreamTextChanged]
  /// 单独处理，避免 ListenableBuilder 每次重建又额外安排滚动回调。
  void _maybeAutoScroll(List<ChatMessage> messages) {
    final count = messages.length;
    if (count == _lastCount) return;
    _lastCount = count;
    if (_autoScrollScheduled) return;
    _autoScrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoScrollScheduled = false;
      if (!mounted || !_scroll.hasClients) return;
      if (_scroll.position.pixels <= 96) _scroll.jumpTo(0);
    });
  }

  Future<void> _send() async {
    if (widget.shiyi.pendingQuestion != null) {
      _submitAnswer();
      return;
    }
    final text = _input.text;
    if (text.trim().isEmpty &&
        _pendingImages.isEmpty &&
        _pendingFiles.isEmpty) {
      return;
    }
    final sb = StringBuffer();
    for (final path in _pendingImages) {
      sb.writeln('![图片]($path)');
    }
    for (final path in _pendingFiles) {
      sb.writeln('【附件：${p.basename(path)}】');
      sb.writeln('路径：$path');
    }
    if (text.trim().isNotEmpty) sb.write(text);
    _input.clear();
    setState(() {
      _pendingImages.clear();
      _pendingFiles.clear();
    });
    FocusScope.of(context).unfocus();
    await widget.shiyi.guideSend(sb.toString());
    _scrollToLatest();
  }

  /// 模型提问时，主输入框直接作为回答输入：发送即把内容交回 question 工具。
  void _submitAnswer() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    FocusScope.of(context).unfocus();
    widget.shiyi.answerQuestion(null, custom: text);
    _scrollToLatest();
  }

  final List<String> _pendingImages = [];

  /// 待发送的附件文件（已复制到工作目录 attachments/ 下）。
  final List<String> _pendingFiles = [];

  /// 当前会话工作目录（缓存显示用）。
  String? _workspace;

  Future<void> _refreshWorkspace() async {
    final w = await widget.shiyi.currentWorkspace();
    if (!mounted) return;
    setState(() => _workspace = w);
  }

  /// 弹出会话工作目录设置面板。
  Future<void> _pickWorkspace() async {
    await _refreshWorkspace();
    if (!mounted) return;
    final current = _workspace ?? '';
    final sessionId = widget.sessionId ?? widget.shiyi.currentSessionId;
    final project = sessionId == null
        ? null
        : widget.shiyi.projectForSession(sessionId);
    showIosFadeSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: iosGroupedBackground(context),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _IosSheetHeader(title: '工作目录'),
            SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CupertinoListSection.insetGrouped(
                    decoration: iosSectionDecoration(ctx),
                    backgroundColor: iosGroupedBackground(ctx),
                    children: [
                      CupertinoListTile(
                        leading: _IosWorkspaceIconTile(
                          icon: CupertinoIcons.folder_fill,
                          color: _iosBlue,
                        ),
                        title: const Text('当前项目目录'),
                        subtitle: Text(
                          current.isEmpty ? '（读取中…）' : current,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (sessionId != null)
                        CupertinoListTile(
                          leading: _IosWorkspaceIconTile(
                            icon: CupertinoIcons.folder_badge_plus,
                            color: _iosIndigo,
                          ),
                          title: const Text('所属项目'),
                          subtitle: Text(
                            project == null
                                ? '未分类'
                                : project.workspaceDir.isEmpty
                                ? project.name
                                : '${project.name}\n目录：${project.workspaceDir}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: const CupertinoListTileChevron(),
                          onTap: () async {
                            Navigator.pop(ctx);
                            await _pickProjectForSession(sessionId);
                          },
                        ),
                      if (project != null)
                        CupertinoListTile(
                          leading: _IosWorkspaceIconTile(
                            icon: CupertinoIcons.folder_open,
                            color: _iosOrange,
                          ),
                          title: const Text('项目工作目录'),
                          subtitle: Text(
                            project.workspaceDir.isEmpty
                                ? '未设置（用全局默认）'
                                : project.workspaceDir,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: const CupertinoListTileChevron(),
                          onTap: () async {
                            Navigator.pop(ctx);
                            await _pickProjectWorkspace(project);
                          },
                        ),
                    ],
                  ),
                  CupertinoListSection.insetGrouped(
                    decoration: iosSectionDecoration(ctx),
                    backgroundColor: iosGroupedBackground(ctx),
                    children: [
                      CupertinoListTile(
                        leading: _IosWorkspaceIconTile(
                          icon: CupertinoIcons.folder,
                          color: _iosGreen,
                        ),
                        title: const Text('选择目录'),
                        subtitle: const Text('把本会话的工作目录设为选中的文件夹'),
                        trailing: const CupertinoListTileChevron(),
                        onTap: () async {
                          Navigator.pop(ctx);
                          final p = await FilePicker.platform
                              .getDirectoryPath();
                          if (p == null || !mounted) return;
                          await widget.shiyi.setCurrentSessionWorkspace(p);
                          await _refreshWorkspace();
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('本会话项目目录已设为：$p')),
                          );
                        },
                      ),
                      CupertinoListTile(
                        leading: _IosWorkspaceIconTile(
                          icon: CupertinoIcons.arrow_counterclockwise,
                          color: _iosGray,
                        ),
                        title: const Text('使用全局默认目录'),
                        subtitle: const Text('清除本会话的自定义目录'),
                        trailing: const CupertinoListTileChevron(),
                        onTap: () async {
                          Navigator.pop(ctx);
                          await widget.shiyi.setCurrentSessionWorkspace('');
                          await _refreshWorkspace();
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已恢复全局默认工作目录')),
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickProjectForSession(String sessionId) async {
    final shiyi = widget.shiyi;
    final selectedId = await showIosFadeSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: iosGroupedBackground(context),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _IosSheetHeader(),
            SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 12),
              child: CupertinoListSection.insetGrouped(
                decoration: iosSectionDecoration(ctx),
                backgroundColor: iosGroupedBackground(ctx),
                children: [
                  CupertinoListTile(
                    leading: _IosWorkspaceIconTile(
                      icon: CupertinoIcons.folder_badge_plus,
                      color: _iosIndigo,
                    ),
                    title: const Text('移动到项目'),
                  ),
                  for (final p in shiyi.projects)
                    CupertinoListTile(
                      leading: _IosWorkspaceIconTile(
                        icon: CupertinoIcons.folder_fill,
                        color: _iosBlue,
                      ),
                      title: Text(
                        p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text('${p.sessionCount} 个会话'),
                      trailing: const CupertinoListTileChevron(),
                      onTap: () => Navigator.pop(ctx, p.id),
                    ),
                  CupertinoListTile(
                    leading: _IosWorkspaceIconTile(
                      icon: CupertinoIcons.tray,
                      color: _iosGray,
                    ),
                    title: const Text('未分类'),
                    trailing: const CupertinoListTileChevron(),
                    onTap: () => Navigator.pop(ctx, ''),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (selectedId == null || !mounted) return;
    await shiyi.moveSessionToProject(
      sessionId,
      selectedId.isEmpty ? null : selectedId,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(selectedId.isEmpty ? '已移动到未分类' : '已移动到项目')),
    );
  }

  Future<void> _pickProjectWorkspace(Project project) async {
    final shiyi = widget.shiyi;
    final action = await showIosFadeSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: iosGroupedBackground(context),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _IosSheetHeader(),
            SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 12),
              child: CupertinoListSection.insetGrouped(
                decoration: iosSectionDecoration(ctx),
                backgroundColor: iosGroupedBackground(ctx),
                children: [
                  CupertinoListTile(
                    leading: _IosWorkspaceIconTile(
                      icon: CupertinoIcons.folder_fill,
                      color: _iosIndigo,
                    ),
                    title: Text(
                      '「${project.name}」工作目录',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      project.workspaceDir.isEmpty
                          ? '未设置（会话用全局默认）'
                          : project.workspaceDir,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  CupertinoListTile(
                    leading: _IosWorkspaceIconTile(
                      icon: CupertinoIcons.folder,
                      color: _iosGreen,
                    ),
                    title: const Text('选择文件夹'),
                    subtitle: const Text('本会话未单独设置目录时自动使用'),
                    trailing: const CupertinoListTileChevron(),
                    onTap: () => Navigator.pop(ctx, 'pick'),
                  ),
                  if (project.workspaceDir.isNotEmpty)
                    CupertinoListTile(
                      leading: _IosWorkspaceIconTile(
                        icon: CupertinoIcons.arrow_counterclockwise,
                        color: _iosGray,
                      ),
                      title: const Text('清除项目目录'),
                      subtitle: const Text('回到全局默认目录'),
                      trailing: const CupertinoListTileChevron(),
                      onTap: () => Navigator.pop(ctx, 'clear'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'clear') {
      await shiyi.setProjectWorkspace(project.id, '');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已清除项目目录')));
      return;
    }
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null || dir.trim().isEmpty || !mounted) return;
    await shiyi.setProjectWorkspace(project.id, dir);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('项目工作目录已设为：$dir')));
  }

  /// 上次输入 @ 触发选择器的时间（防抖）。
  DateTime? _lastAtTrigger;

  /// 上次输入 / 触发技能选择器的时间（防抖）。
  DateTime? _lastSlashTrigger;

  Future<void> _pickImage({required bool fromCamera}) async {
    try {
      if (fromCamera) {
        final path = await ImageService.pickAndSave(fromCamera: true);
        if (path != null && mounted) {
          setState(() => _pendingImages.add(path));
        }
      } else {
        final paths = await ImageService.pickMultipleAndSave();
        if (paths.isNotEmpty && mounted) {
          setState(() => _pendingImages.addAll(paths));
        }
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '选择图片失败：${e.toString().replaceFirst('Exception: ', '')}',
          ),
        ),
      );
    }
  }

  void _removeImage(int index) {
    setState(() => _pendingImages.removeAt(index));
  }

  void _removeFile(int index) {
    setState(() => _pendingFiles.removeAt(index));
  }

  /// 选择一个或多个文件并复制到工作目录 attachments/ 下，供模型用 run_terminal 读取。
  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(allowMultiple: true);
      if (result == null || result.files.isEmpty) return;
      var added = 0;
      for (final f in result.files) {
        final src = f.path;
        if (src == null || !mounted) return;
        final dest = await FileWorkspace.copyToAttachments(src);
        if (dest == null) continue;
        setState(() => _pendingFiles.add(dest));
        added++;
      }
      if (added > 0) _stripAt();
      if (added == 0 && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('文件复制到工作目录失败')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '选择文件失败：${e.toString().replaceFirst('Exception: ', '')}',
          ),
        ),
      );
    }
  }

  /// 选择文件夹并整体复制到工作目录 attachments/ 下。
  Future<void> _pickFolder() async {
    try {
      final path = await FilePicker.platform.getDirectoryPath();
      if (path == null || !mounted) return;
      final dest = await FileWorkspace.copyDirectoryToAttachments(path);
      if (dest == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('文件夹复制到工作目录失败（可能同名已存在）')));
        return;
      }
      setState(() => _pendingFiles.add(dest));
      _stripAt();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '选择文件夹失败：${e.toString().replaceFirst('Exception: ', '')}',
          ),
        ),
      );
    }
  }

  /// 输入框末尾是 @ 时弹文件/文件夹选择，是 / 时弹技能选择（都带防抖）。
  void _onInputTextChanged() {
    final t = _input.text;
    final now = DateTime.now();
    if (t.endsWith('@')) {
      if (_lastAtTrigger != null &&
          now.difference(_lastAtTrigger!).inMilliseconds < 600) {
        return;
      }
      _lastAtTrigger = now;
      _pickAtTarget();
      return;
    }
    if (t.endsWith('/')) {
      if (_lastSlashTrigger != null &&
          now.difference(_lastSlashTrigger!).inMilliseconds < 600) {
        return;
      }
      _lastSlashTrigger = now;
      _pickSkillSheet();
    }
  }

  /// 输入 / 时弹出技能选择，可多选，选中后加载到当前会话（注入系统提示）。
  void _pickSkillSheet() {
    final shiyi = widget.shiyi;
    final skills = shiyi.skills;
    showIosFadeSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 8, 2),
                child: Row(
                  children: [
                    Text(
                      '加载技能（可多选）',
                      style: Theme.of(ctx).textTheme.titleSmall,
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _stripSlash();
                      },
                      child: const Text('完成'),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: skills.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('还没有技能，去「技能」页创建或导入'),
                      )
                    : ListView(
                        shrinkWrap: true,
                        children: [
                          for (final s in skills)
                            ListTile(
                              dense: true,
                              leading: const Icon(Icons.bolt_outlined),
                              title: Text(s.name),
                              subtitle: s.description.isEmpty
                                  ? null
                                  : Text(
                                      s.description,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                              trailing: shiyi.isSkillLoaded(s)
                                  ? Icon(
                                      Icons.check_circle,
                                      size: 20,
                                      color: Theme.of(ctx).colorScheme.primary,
                                    )
                                  : const Icon(Icons.circle_outlined, size: 20),
                              onTap: () {
                                shiyi.toggleLoadedSkill(s);
                                setSheetState(() {});
                              },
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 选择成功后把触发用的 / 从输入框删掉。
  void _stripSlash() {
    final t = _input.text;
    if (t.endsWith('/')) {
      _input.text = t.substring(0, t.length - 1);
      _input.selection = TextSelection.collapsed(offset: _input.text.length);
    }
  }

  void _pickAtTarget() {
    showIosFadeModalPopup<void>(
      context: context,
      builder: (ctx) => CupertinoTheme(
        data: iosCupertinoTheme(context),
        child: CupertinoActionSheet(
          title: const Text('选择附件'),
          actions: [
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.pop(ctx);
                _pickFile();
              },
              child: const Text('选择文件'),
            ),
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.pop(ctx);
                _pickFolder();
              },
              child: const Text('选择文件夹'),
            ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ),
      ),
    );
  }

  /// 选择成功后把触发用的 @ 从输入框删掉。
  void _stripAt() {
    final t = _input.text;
    if (t.endsWith('@')) {
      _input.text = t.substring(0, t.length - 1);
      _input.selection = TextSelection.collapsed(offset: _input.text.length);
    }
  }

  void _pickAttachmentSheet() {
    showIosFadeModalPopup<void>(
      context: context,
      builder: (ctx) => CupertinoTheme(
        data: iosCupertinoTheme(context),
        child: CupertinoActionSheet(
          title: const Text('添加附件'),
          actions: [
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.pop(ctx);
                _pickImage(fromCamera: false);
              },
              child: const Text('从相册选择'),
            ),
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.pop(ctx);
                _pickImage(fromCamera: true);
              },
              child: const Text('拍照'),
            ),
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.pop(ctx);
                _pickFile();
              },
              child: const Text('发送文件'),
            ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ),
      ),
    );
  }

  Future<void> _sendSuggestion(String text) async {
    _input.text = text;
    await _send();
  }

  Future<void> _speakMessage(ChatMessage msg) async {
    await TtsService.instance.speak(
      msg.id,
      msg.content,
      rate: widget.shiyi.settings.ttsRate,
    );
  }

  void _stopSpeak() {
    TtsService.instance.stop();
  }

  Future<void> _copyMessage(ChatMessage msg) async {
    final text = stripImageMarkers(msg.content);
    final content = text.isEmpty ? msg.content : text;
    await Clipboard.setData(ClipboardData(text: content));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已复制到剪贴板')));
  }

  Future<void> _confirmDelete(ChatMessage msg) async {
    final ok = await showIosFadeDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条消息？'),
        content: const Text('删除后不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) await widget.shiyi.deleteMessage(msg.id);
  }

  Future<void> _confirmRegenerate(ChatMessage msg) async {
    final idx = widget.shiyi.messages.indexWhere((m) => m.id == msg.id);
    final hasAfter = idx >= 0 && idx < widget.shiyi.messages.length - 1;
    if (hasAfter) {
      final ok = await showIosFadeDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('重新生成这条回复？'),
          content: const Text('将删除该回复之后的所有消息，再基于此前对话重新生成。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('重新生成'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    await widget.shiyi.regenerate(msg.id);
  }

  // ---------- 系统预测性返回（由 MacPageRoute 转发系统手势） ----------
  @override
  void onBackGestureProgress(double progress) {
    if (!mounted) return;
    _dragCtrl.stop();
    _dragCtrl.value = progress.clamp(0.0, 1.0);
  }

  @override
  void onBackGestureCommit() {
    if (!mounted) return;
    _performPop();
  }

  @override
  void onBackGestureCancel() {
    if (!mounted) return;
    _dragCtrl.animateBack(
      0,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  /// 执行返回：先补完缩小悬浮动画，再真正 pop。
  Future<void> _performPop() async {
    // 工具信息流是当前页面上的临时层，优先响应系统返回。
    if (_showToolLog) {
      if (mounted) setState(() => _showToolLog = false);
      return;
    }
    // 直接由路由的淡入淡出完成返回，省掉额外的拖动收尾动画。
    FocusManager.instance.primaryFocus?.unfocus();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _performPop();
      },
      child: AnimatedBuilder(
        animation: _dragCtrl,
        builder: (context, child) {
          final t = _dragCtrl.value;
          // 静止状态零开销：直接透传，不套变换/裁剪层。
          if (t <= 0.001) return child!;
          // 淡入淡出代替缩小悬浮：无缩放/裁剪绘制开销。
          return Opacity(opacity: 1.0 - t * 0.45, child: child);
        },
        child: RepaintBoundary(
          child: Stack(
            children: [
              Scaffold(
                appBar: AppBar(
                  leadingWidth: 104,
                  leading: Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: ListenableBuilder(
                        listenable: widget.shiyi,
                        builder: (context, _) => TrafficLightsButton(
                          busy: widget.shiyi.isBusy,
                          tooltip: '返回',
                          onTap: _performPop,
                        ),
                      ),
                    ),
                  ),
                  // 右侧对称占位放工具调用信息流胶囊（与左侧返回区等宽），标题保持居中。
                  actions: [
                    SizedBox(
                      width: 104,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: ListenableBuilder(
                          listenable: widget.shiyi,
                          builder: (context, _) {
                            final events = widget.shiyi.toolEvents;
                            return Center(
                              child: events.isEmpty
                                  ? _ToolPillIdle(
                                      onTap: () => setState(
                                        () => _showToolLog = !_showToolLog,
                                      ),
                                    )
                                  : _ToolPill(
                                      event: events.last,
                                      index: events.length,
                                      total: events.length,
                                      onTap: () => setState(
                                        () => _showToolLog = !_showToolLog,
                                      ),
                                    ),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                  title: ListenableBuilder(
                    listenable: widget.shiyi,
                    builder: (context, _) {
                      if (widget.shiyi.currentSessionId == null) {
                        return const Text('新会话');
                      }
                      final s = widget.shiyi.sessions.firstWhere(
                        (e) => e.id == widget.shiyi.currentSessionId,
                        orElse: () => Session(
                          id: '',
                          title: '新会话',
                          model: '',
                          createdAt: 0,
                          updatedAt: 0,
                        ),
                      );
                      return Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Text(
                            s.title,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (widget.shiyi.settings.model.isNotEmpty)
                            Text(
                              widget.shiyi.settings.model,
                              style: theme.textTheme.bodySmall!.copyWith(
                                color: theme.hintColor,
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
                body: Column(
                  children: [
                    Expanded(
                      child: ListenableBuilder(
                        // 只监听消息版本：status/token/工具轮等状态变化
                        // 不再重建整个消息列表（流式文本由气泡内部
                        // ValueListenableBuilder 单独驱动）。
                        listenable: widget.shiyi.messagesRevision,
                        builder: (context, _) {
                          final messages = widget.shiyi.messages;
                          // 工具调用已集中到右上角信息流胶囊，对话流里不再显示工具消息与纯工具回合。
                          final visible = messages
                              .where(
                                (m) =>
                                    m.role != 'tool' &&
                                    !(m.role == 'assistant' &&
                                        m.hasToolCalls &&
                                        m.content.trim().isEmpty &&
                                        !m.streaming),
                              )
                              .toList();
                          _maybeAutoScroll(visible);
                          if (messages.isEmpty) {
                            return _Welcome(
                              shiyi: widget.shiyi,
                              onPick: _sendSuggestion,
                            );
                          }
                          if (visible.isEmpty) return const SizedBox.shrink();
                          final archivedCount = visible
                              .where((m) => m.archived)
                              .length;
                          // 反转显示：index 0 是最新消息；归档历史放在最上方，
                          // 与仍然活跃的消息之间插入一条分隔提示。
                          final items = <Object>[];
                          for (var i = visible.length - 1; i >= 0; i--) {
                            if (archivedCount > 0 && i == archivedCount - 1) {
                              items.add(_ArchivedDivider(count: archivedCount));
                            }
                            items.add(visible[i]);
                          }
                          return ListView.builder(
                            controller: _scroll,
                            reverse: true,
                            padding: const EdgeInsets.all(12),
                            itemCount: items.length,
                            itemBuilder: (context, i) {
                              final item = items[i];
                              if (item is _ArchivedDivider) {
                                return item;
                              }
                              final m = item as ChatMessage;
                              // 流式消息：只监听自己的实时文本，单独重建。
                              if (m.streaming) {
                                return KeyedSubtree(
                                  key: ValueKey(m.id),
                                  child: ValueListenableBuilder<String>(
                                    valueListenable:
                                        widget.shiyi.streamReasoning,
                                    builder: (context, reasoning, _) =>
                                        ValueListenableBuilder<String>(
                                          valueListenable:
                                              widget.shiyi.streamText,
                                          builder: (context, text, _) =>
                                              _messageItem(
                                                m,
                                                liveContent: text,
                                                liveReasoning: reasoning,
                                              ),
                                        ),
                                  ),
                                );
                              }
                              // 历史消息：稳定不变，隔离重绘。
                              return KeyedSubtree(
                                key: ValueKey(m.id),
                                child: RepaintBoundary(child: _messageItem(m)),
                              );
                            },
                          );
                        },
                      ),
                    ),
                    ListenableBuilder(
                      listenable: widget.shiyi,
                      builder: (context, _) => Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.shiyi.status != null)
                            Builder(
                              builder: (context) {
                                final s = widget.shiyi.status!;
                                final isError = s.startsWith('错误');
                                final bg = isError
                                    ? theme.colorScheme.errorContainer
                                          .withValues(alpha: .4)
                                    : theme.colorScheme.surfaceContainerHigh
                                          .withValues(alpha: .7);
                                final fg = isError
                                    ? theme.colorScheme.onErrorContainer
                                    : theme.colorScheme.onSurfaceVariant;
                                return Container(
                                  width: double.infinity,
                                  color: bg,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 6,
                                  ),
                                  child: Text(
                                    s,
                                    style: theme.textTheme.bodySmall!.copyWith(
                                      color: fg,
                                    ),
                                  ),
                                );
                              },
                            ),
                          if (widget.shiyi.trimNotice != null)
                            Container(
                              width: double.infinity,
                              color: theme.colorScheme.tertiaryContainer
                                  .withValues(alpha: .55),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              child: Text(
                                widget.shiyi.trimNotice!,
                                style: theme.textTheme.bodySmall!.copyWith(
                                  color: theme.colorScheme.onTertiaryContainer,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    ListenableBuilder(
                      listenable: widget.shiyi,
                      builder: (context, _) => _TokenStats(shiyi: widget.shiyi),
                    ),
                    ListenableBuilder(
                      listenable: widget.shiyi,
                      builder: (context, _) => _LoadedSkillChips(
                        skills: widget.shiyi.loadedSkills,
                        onRemove: (s) => widget.shiyi.toggleLoadedSkill(s),
                      ),
                    ),
                    ListenableBuilder(
                      listenable: widget.shiyi,
                      builder: (context, _) =>
                          _PlanModeChip(planMode: widget.shiyi.planMode),
                    ),
                    // 当前会话项目目录条：点击可修改。
                    GestureDetector(
                      onTap: _pickWorkspace,
                      child: Container(
                        margin: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHigh
                              .withValues(alpha: .6),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.folder_outlined,
                              size: 14,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                _workspace ?? '项目目录…',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelSmall!.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              Icons.edit_outlined,
                              size: 13,
                              color: theme.hintColor,
                            ),
                          ],
                        ),
                      ),
                    ),
                    // 模型提问面板：内嵌在输入框上方，从下方滑入，不遮挡会话内容。
                    ListenableBuilder(
                      listenable: widget.shiyi,
                      builder: (context, _) {
                        final q = widget.shiyi.pendingQuestion;
                        return AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          transitionBuilder: (child, animation) =>
                              SlideTransition(
                                position: Tween<Offset>(
                                  begin: const Offset(0, 0.35),
                                  end: Offset.zero,
                                ).animate(animation),
                                child: FadeTransition(
                                  opacity: animation,
                                  child: child,
                                ),
                              ),
                          child: q == null
                              ? const SizedBox.shrink(
                                  key: ValueKey('no-question'),
                                )
                              : _QuestionPanel(
                                  key: ValueKey('question-${q.hashCode}'),
                                  question: q,
                                  shiyi: widget.shiyi,
                                ),
                        );
                      },
                    ),
                    ListenableBuilder(
                      listenable: widget.shiyi,
                      builder: (context, _) => _Composer(
                        input: _input,
                        busy: widget.shiyi.isBusy,
                        questionActive: widget.shiyi.pendingQuestion != null,
                        pendingImages: _pendingImages,
                        pendingFiles: _pendingFiles,
                        onPickAttachment: _pickAttachmentSheet,
                        onRemoveImage: _removeImage,
                        onRemoveFile: _removeFile,
                        onSend: _send,
                        onStop: widget.shiyi.stop,
                        enterToSend: widget.shiyi.settings.enterToSend,
                      ),
                    ),
                  ],
                ),
              ),
              // 操作信息流面板：默认收起，点右上角胶囊手动展开/收起。
              ListenableBuilder(
                listenable: widget.shiyi,
                builder: (context, _) {
                  if (!_showToolLog) return const SizedBox.shrink();
                  return Positioned(
                    top: MediaQuery.paddingOf(context).top + kToolbarHeight + 8,
                    right: 8,
                    width: 280,
                    child: _ToolLogPanel(
                      events: widget.shiyi.toolEvents,
                      onClose: () => setState(() => _showToolLog = false),
                    ),
                  );
                },
              ),
              // 上下文达到压缩阈值后，右下角悬浮「压缩上下文」胶囊。
              Positioned(
                right: 14,
                bottom: 110,
                child: ListenableBuilder(
                  listenable: widget.shiyi,
                  builder: (context, _) {
                    if (!_compressNeeded()) return const SizedBox.shrink();
                    final theme = Theme.of(context);
                    return Material(
                      color: theme.colorScheme.primary,
                      borderRadius: BorderRadius.circular(20),
                      elevation: 3,
                      shadowColor: Colors.black.withValues(alpha: .3),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: _compressContext,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 9,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.compress_outlined,
                                size: 16,
                                color: theme.colorScheme.onPrimary,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '压缩上下文',
                                style: TextStyle(
                                  color: theme.colorScheme.onPrimary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 上下文是否已超过压缩阈值（达到限制后显示悬浮压缩胶囊）。
  bool _compressNeeded() {
    final s = widget.shiyi;
    final limit = s.settings.contextLimit;
    final pct = s.settings.compressThresholdPercent;
    if (limit <= 0 || pct <= 0) return false;
    return s.sessionContextTokensFull > limit * pct / 100;
  }

  Future<void> _compressContext() async {
    final shiyi = widget.shiyi;
    final sessionId = widget.sessionId ?? shiyi.currentSessionId;
    if (sessionId == null) return;
    final tokens = await shiyi.activeContextTokenEstimate(sessionId);
    if (!mounted) return;
    final limit = shiyi.settings.contextLimit;
    final pct = limit <= 0 ? 0.0 : (tokens / limit * 100).clamp(0, 100);
    final ok = await showIosFadeDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('压缩上下文'),
        content: Text(
          '当前会话上下文约 ${pct.toStringAsFixed(0)}%'
          '（${(tokens / 10000).toStringAsFixed(1)}w token / 上限 ${(limit / 10000).toStringAsFixed(0)}w token）。\n'
          '压缩会把早期历史归档为滚动摘要，只发送摘要和最近完整消息；'
          '完整历史仍保留在本地，不会删除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('压缩'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    showIosFadeDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              SizedBox(width: 16),
              Text('正在压缩上下文…'),
            ],
          ),
        ),
      ),
    );
    final ({bool ok, int archived, int beforeTokens, int afterTokens}) result;
    try {
      result = await shiyi.compressSession(sessionId);
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
    final done = result.ok;
    if (!mounted) return;
    final msg = done
        ? '压缩完成：已归档 ${result.archived} 条，上下文 '
              '${(result.beforeTokens / 10000).toStringAsFixed(1)}w → '
              '${(result.afterTokens / 10000).toStringAsFixed(1)}w token'
        : '压缩失败（消息太少或 API 未配置）';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _saveSkillDialog(String content) {
    final nameCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    final contentCtrl = TextEditingController(text: content);
    showIosFadeDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('保存为技能'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: '技能名称',
                  hintText: '例如：写周报',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: descCtrl,
                decoration: const InputDecoration(labelText: '描述（可选）'),
                maxLines: 2,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: contentCtrl,
                decoration: const InputDecoration(labelText: '技能内容'),
                maxLines: 6,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              final name = nameCtrl.text.trim();
              if (name.isEmpty) return;
              try {
                await widget.shiyi.saveSkill(
                  Skill(
                    id: 0,
                    name: name,
                    description: descCtrl.text.trim(),
                    content: contentCtrl.text.trim(),
                    createdAt: DateTime.now().millisecondsSinceEpoch,
                  ),
                );
                if (ctx.mounted) Navigator.pop(ctx);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('技能已保存，可在「技能」页查看')),
                  );
                }
              } catch (e) {
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(
                      content: Text(
                        '保存失败：${e.toString().replaceFirst('Exception: ', '')}',
                      ),
                    ),
                  );
                }
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}

/// 输入框上方的 token 统计栏：本次会话累计 / 本轮对话 / 剩余上下文百分比。
class _ArchivedDivider extends StatelessWidget {
  final int count;

  const _ArchivedDivider({required this.count});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          const Expanded(child: Divider()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              '已归档 $count 条 · 不占用当前上下文',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
          ),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }
}

class _TokenStats extends StatelessWidget {
  final ShiyiState shiyi;
  const _TokenStats({required this.shiyi});

  static String _fmt(int n) {
    if (n >= 100000000) return '${(n / 100000000).toStringAsFixed(1)}亿';
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}w';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = shiyi.sessionTotalTokens;
    final round = shiyi.lastRoundTokens;
    final limit = shiyi.settings.contextLimit;
    final tokens = shiyi.sessionContextTokens;
    final remain = limit <= 0
        ? 100.0
        : ((limit - tokens) / limit * 100).clamp(0, 100);
    final remainInt = remain.round();
    final cacheText = !shiyi.roundCacheKnown || shiyi.roundInputTokens <= 0
        ? '缓存 --'
        : '缓存 ${(shiyi.roundCachedTokens / shiyi.roundInputTokens * 100).round()}%';
    final color = remainInt <= 20
        ? theme.colorScheme.error
        : remainInt <= 50
        ? theme.colorScheme.tertiary
        : theme.colorScheme.onSurfaceVariant;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Text(
        '会话 ${_fmt(total)} · 本轮 ${_fmt(round)} · 上下文 ${_fmt(tokens)}/${_fmt(limit)}（剩 $remainInt%）· $cacheText',
        textAlign: TextAlign.center,
        style: theme.textTheme.labelSmall!.copyWith(color: color, fontSize: 11),
      ),
    );
  }
}

/// 模型发起的 question 工具面板：内嵌在输入框上方，从下方滑入，
/// 不遮挡会话内容；点选项或直接在输入框填写回答后发送。
class _QuestionPanel extends StatelessWidget {
  final Map<String, dynamic> question;
  final ShiyiState shiyi;
  const _QuestionPanel({
    super.key,
    required this.question,
    required this.shiyi,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final qText = question['question']?.toString() ?? '';
    final options =
        (question['options'] as List?)?.cast<String>() ??
        const <String>['确认', '取消'];
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: .35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                Icons.help_outline,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Text(
                '拾忆 向你提问',
                style: theme.textTheme.titleSmall!.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              IconButton(
                onPressed: () => shiyi.answerQuestion(null),
                icon: const Icon(Icons.close, size: 18),
                tooltip: '取消提问',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(qText, style: theme.textTheme.bodyMedium!.copyWith(height: 1.4)),
          if (options.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '快捷选项',
                    style: theme.textTheme.labelMedium!.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 160),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < options.length; i++) ...[
                            if (i > 0) const SizedBox(height: 6),
                            FilledButton.tonal(
                              onPressed: () => shiyi.answerQuestion(i),
                              style: FilledButton.styleFrom(
                                alignment: Alignment.centerLeft,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                visualDensity: VisualDensity.compact,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              child: Text(
                                options[i],
                                textAlign: TextAlign.left,
                                style: theme.textTheme.bodyMedium,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 当前会话已加载技能的小提示条（输入栏上方，可多选），每个技能可单独移除。
class _LoadedSkillChips extends StatelessWidget {
  final List<Skill> skills;
  final ValueChanged<Skill> onRemove;
  const _LoadedSkillChips({required this.skills, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    if (skills.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [for (final s in skills) _buildChip(theme, s)],
        ),
      ),
    );
  }

  Widget _buildChip(ThemeData theme, Skill s) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 240),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bolt, size: 15, color: theme.colorScheme.primary),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                s.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall,
              ),
            ),
            const SizedBox(width: 4),
            InkWell(
              onTap: () => onRemove(s),
              borderRadius: BorderRadius.circular(8),
              child: const Padding(
                padding: EdgeInsets.all(2),
                child: Icon(Icons.close, size: 15),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 计划模式指示条（输入栏上方）：提示当前处于只读计划阶段。
class _PlanModeChip extends StatelessWidget {
  final bool planMode;
  const _PlanModeChip({required this.planMode});

  @override
  Widget build(BuildContext context) {
    if (!planMode) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.engineering_outlined,
            size: 15,
            color: theme.colorScheme.onTertiaryContainer,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              '计划模式：只读 · 先出方案，确认后再执行',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onTertiaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  final TextEditingController input;
  final bool busy;
  final bool questionActive;
  final List<String> pendingImages;
  final List<String> pendingFiles;
  final VoidCallback onPickAttachment;
  final ValueChanged<int> onRemoveImage;
  final ValueChanged<int> onRemoveFile;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final bool enterToSend;
  const _Composer({
    required this.input,
    required this.busy,
    required this.questionActive,
    required this.pendingImages,
    required this.pendingFiles,
    required this.onPickAttachment,
    required this.onRemoveImage,
    required this.onRemoveFile,
    required this.onSend,
    required this.onStop,
    required this.enterToSend,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: dark ? const Color(0xCC1C1C1E) : const Color(0xD9F2F2F7),
        border: Border(
          top: BorderSide(
            color: dark
                ? Colors.white.withValues(alpha: .12)
                : Colors.black.withValues(alpha: .08),
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (pendingImages.isNotEmpty || pendingFiles.isNotEmpty)
              _previewRow(theme),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 40,
                  height: 40,
                  child: IconButton(
                    onPressed: onPickAttachment,
                    icon: const Icon(
                      CupertinoIcons.plus_circle,
                      size: 24,
                      color: _iosBlue,
                    ),
                    tooltip: '添加附件',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 40,
                      height: 40,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: dark
                          ? const Color(0xFF2C2C2E)
                          : const Color(0xFFE5E5EA),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Focus(
                      onKeyEvent: (node, event) {
                        if (!enterToSend ||
                            event is! KeyDownEvent ||
                            (event.logicalKey != LogicalKeyboardKey.enter &&
                                event.logicalKey !=
                                    LogicalKeyboardKey.numpadEnter)) {
                          return KeyEventResult.ignored;
                        }
                        onSend();
                        return KeyEventResult.handled;
                      },
                      child: TextField(
                        controller: input,
                        minLines: 1,
                        maxLines: 5,
                        textInputAction: enterToSend
                            ? TextInputAction.send
                            : TextInputAction.newline,
                        onSubmitted: enterToSend ? (_) => onSend() : null,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontSize: 16,
                          height: 1.25,
                        ),
                        decoration: InputDecoration(
                          hintText: questionActive ? '直接输入你的回答…' : '输入消息…',
                          hintStyle: TextStyle(color: theme.hintColor),
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                          errorBorder: InputBorder.none,
                          focusedErrorBorder: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                        textAlignVertical: TextAlignVertical.center,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: input,
                  builder: (context, value, _) {
                    final hasInput =
                        value.text.trim().isNotEmpty ||
                        pendingImages.isNotEmpty ||
                        pendingFiles.isNotEmpty;
                    return _sendControl(dark: dark, hasInput: hasInput);
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _sendControl({required bool dark, required bool hasInput}) {
    if (busy) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _roundIconButton(
            onPressed: onStop,
            icon: CupertinoIcons.stop_circle_fill,
            color: _iosRed,
            tooltip: '停止',
          ),
          if (hasInput) ...[
            const SizedBox(width: 2),
            _roundIconButton(
              onPressed: onSend,
              icon: CupertinoIcons.arrow_up_circle_fill,
              color: _iosBlue,
              tooltip: questionActive ? '发送回答' : '发送并引导',
            ),
          ],
        ],
      );
    }
    return _roundIconButton(
      onPressed: hasInput ? onSend : null,
      icon: hasInput
          ? CupertinoIcons.arrow_up_circle_fill
          : CupertinoIcons.arrow_up_circle,
      color: hasInput
          ? _iosBlue
          : dark
          ? const Color(0xFF48484A)
          : const Color(0xFFC7C7CC),
      tooltip: questionActive ? '发送回答' : '发送',
    );
  }

  Widget _roundIconButton({
    required VoidCallback? onPressed,
    required IconData icon,
    required Color color,
    required String tooltip,
  }) {
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon, size: 34, color: color),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      tooltip: tooltip,
    );
  }

  Widget _previewRow(ThemeData theme) {
    return SizedBox(
      height: 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: pendingImages.length + pendingFiles.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          if (i < pendingImages.length) {
            final path = pendingImages[i];
            return Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(
                    File(path),
                    width: 56,
                    height: 56,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      width: 56,
                      height: 56,
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: theme.hintColor,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 0,
                  right: 0,
                  child: GestureDetector(
                    onTap: () => onRemoveImage(i),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(
                        Icons.close,
                        size: 14,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            );
          }
          final f = pendingFiles[i - pendingImages.length];
          return Stack(
            children: [
              Container(
                width: 140,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.insert_drive_file_outlined,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        p.basename(f),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall,
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                top: 0,
                right: 0,
                child: GestureDetector(
                  onTap: () => onRemoveFile(i - pendingImages.length),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.close,
                      size: 14,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  final ShiyiState shiyi;
  final ValueChanged<String> onPick;
  const _Welcome({required this.shiyi, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final suggestions = [
      '帮我记住：我偏好用 Markdown 写文档',
      '我学到一个技能：用番茄工作法管理时间',
      '帮我搜索记忆里关于「项目」的内容',
    ];
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 40),
        const Center(child: WelcomeAvatar(size: 240)),
        const SizedBox(height: 12),
        Text(
          '你好，我是拾忆\n与你共同成长的智能体',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleLarge!.copyWith(height: 1.3),
        ),
        const SizedBox(height: 8),
        Text(
          '跨会话记忆 · 技能沉淀 · 工具调用',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium!.copyWith(color: theme.hintColor),
        ),
        const SizedBox(height: 28),
        for (final s in suggestions) ...[
          OutlinedButton(
            onPressed: () => onPick(s),
            style: OutlinedButton.styleFrom(alignment: Alignment.centerLeft),
            child: Text(s),
          ),
        ],
      ],
    );
  }
}

// ---------- 工具调用信息流（右上角胶囊 + 展开面板） ----------

String _toolLabel(String name) => switch (name) {
  'web_search' => '搜索',
  'web_extract' => '抓取',
  'save_memory' => '记忆',
  'search_memory' => '检索',
  'run_skill' => '技能',
  'run_terminal' => '终端',
  _ => name,
};

IconData _toolIcon(String name) => switch (name) {
  'web_search' => Icons.travel_explore,
  'web_extract' => Icons.web_asset,
  'save_memory' => Icons.bookmark_add_outlined,
  'search_memory' => Icons.manage_search,
  'run_skill' => Icons.bolt,
  _ => Icons.construction,
};

BoxShadow _toolPillShadow(BuildContext context) {
  final isLight = Theme.of(context).brightness == Brightness.light;
  return BoxShadow(
    color: Colors.black.withValues(alpha: isLight ? 0.16 : 0.35),
    blurRadius: 12,
    offset: const Offset(0, 3),
  );
}

Color _toolPillBackground(BuildContext context) {
  final isLight = Theme.of(context).brightness == Brightness.light;
  return Colors.white.withValues(alpha: isLight ? 0.40 : 0.10);
}

Widget _toolPillShell({
  required BuildContext context,
  required VoidCallback onTap,
  required Widget child,
}) {
  return Container(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(14),
      boxShadow: [_toolPillShadow(context)],
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Material(
          color: _toolPillBackground(context),
          child: InkWell(onTap: onTap, child: child),
        ),
      ),
    ),
  );
}

/// 待机状态的工具胶囊：灰色圆点 + 「工具」字样，点击展开信息流面板。
class _ToolPillIdle extends StatelessWidget {
  final VoidCallback onTap;
  const _ToolPillIdle({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return _toolPillShell(
      context: context,
      onTap: onTap,
      child: SizedBox(
        width: 92,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: cs.outlineVariant,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    '工具',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.hintColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              Text(
                '0.0s',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 右上角胶囊：显示最近一条工具调用状态（含步骤计数/读秒），点击展开信息流面板。
class _ToolPill extends StatefulWidget {
  final ToolEvent event;
  final int index;
  final int total;
  final VoidCallback onTap;
  const _ToolPill({
    required this.event,
    required this.index,
    required this.total,
    required this.onTap,
  });

  @override
  State<_ToolPill> createState() => _ToolPillState();
}

class _ToolPillState extends State<_ToolPill> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant _ToolPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 工具结束后取消每秒刷新计时器（避免常驻空转 setState）。
    _syncTimer();
  }

  /// 运行中每秒刷新耗时显示；事件完成后立即停表。
  void _syncTimer() {
    if (widget.event.done) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    if (_timer != null) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final event = widget.event;
    final elapsedSec =
        (DateTime.now().millisecondsSinceEpoch - event.startedAt) / 1000;
    return _toolPillShell(
      context: context,
      onTap: widget.onTap,
      child: SizedBox(
        width: 92,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!event.done)
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: cs.primary,
                  ),
                )
              else
                Icon(
                  event.ok ? Icons.check_circle : Icons.error,
                  size: 14,
                  color: event.ok ? const Color(0xFF28C840) : cs.error,
                ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  event.done
                      ? _toolLabel(event.name)
                      : '${_toolLabel(event.name)} ${widget.index}/${widget.total}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.hintColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (event.durationMs != null ||
                  (!event.done && elapsedSec >= 1)) ...[
                const SizedBox(width: 4),
                Text(
                  event.done
                      ? '${(event.durationMs! / 1000).toStringAsFixed(1)}s'
                      : '${elapsedSec.toStringAsFixed(0)}s',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.hintColor,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 工具调用信息流面板：右上角展开，滚动显示本轮全部工具调用。
class _ToolLogPanel extends StatefulWidget {
  final List<ToolEvent> events;
  final VoidCallback onClose;
  const _ToolLogPanel({required this.events, required this.onClose});

  @override
  State<_ToolLogPanel> createState() => _ToolLogPanelState();
}

class _ToolLogPanelState extends State<_ToolLogPanel> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Material(
      elevation: 6,
      shadowColor: Colors.black.withValues(alpha: .3),
      color: cs.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 6, 6),
            child: Row(
              children: [
                Icon(Icons.bolt, size: 15, color: cs.primary),
                const SizedBox(width: 6),
                Text(
                  '工具调用',
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  tooltip: '收起',
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onClose,
                ),
              ],
            ),
          ),
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: widget.events.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 14),
                      child: Text(
                        '暂无工具调用',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.hintColor,
                        ),
                      ),
                    )
                  : ListView.separated(
                      controller: _scroll,
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                      itemCount: widget.events.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      // 倒序显示：最新的一条在最上面。
                      itemBuilder: (context, i) => _ToolLogItem(
                        event: widget.events[widget.events.length - 1 - i],
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolLogItem extends StatelessWidget {
  final ToolEvent event;
  const _ToolLogItem({required this.event});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final okColor = const Color(0xFF28C840);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: !event.done
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: cs.primary,
                    ),
                  )
                : Icon(
                    event.ok ? Icons.check_circle : Icons.error,
                    size: 15,
                    color: event.ok ? okColor : cs.error,
                  ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _toolIcon(event.name),
                      size: 14,
                      color: cs.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _toolLabel(event.name),
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    if (event.done)
                      Text(
                        event.durationMs == null
                            ? '完成'
                            : '${(event.durationMs! / 1000).toStringAsFixed(1)}s',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.hintColor,
                        ),
                      )
                    else
                      Text(
                        '运行中',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: cs.primary,
                        ),
                      ),
                  ],
                ),
                if (event.argsSummary.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    event.argsSummary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.hintColor,
                    ),
                  ),
                ],
                if (event.done && event.summary != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    event.summary!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _IosWorkspaceIconTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  const _IosWorkspaceIconTile({required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 31,
      height: 31,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Icon(icon, size: 17, color: CupertinoColors.white),
    );
  }
}

class _IosSheetHeader extends StatelessWidget {
  final String? title;
  const _IosSheetHeader({this.title});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36,
            height: 5,
            decoration: BoxDecoration(
              color: dark ? Colors.white24 : Colors.black26,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          if (title != null) ...[
            const SizedBox(height: 10),
            Text(
              title!,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: dark ? Colors.white54 : Colors.black54,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
