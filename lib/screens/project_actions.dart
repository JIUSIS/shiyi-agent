import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import '../widgets/ios_style.dart';

const _iosBlue = Color(0xFF0A84FF);

/// 新建项目：输入名称并选择工作目录后创建。
Future<Project?> createProjectWithFolder(
  BuildContext context,
  ShiyiState shiyi,
) {
  return showIosFadeDialog<Project>(
    context: context,
    builder: (_) => CupertinoTheme(
      data: iosCupertinoTheme(context),
      child: _NewProjectDialog(shiyi: shiyi),
    ),
  );
}

class _NewProjectDialog extends StatefulWidget {
  final ShiyiState shiyi;
  const _NewProjectDialog({required this.shiyi});

  @override
  State<_NewProjectDialog> createState() => _NewProjectDialogState();
}

class _NewProjectDialogState extends State<_NewProjectDialog> {
  final TextEditingController _controller = TextEditingController();
  String? _folder;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _showError(String message) {
    showIosFadeDialog<void>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('无法创建项目'),
        content: Text(message),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(ctx),
            child: const Text('好'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickFolder() async {
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null || dir.trim().isEmpty) return;
    if (!mounted) return;
    setState(() => _folder = dir.trim());
  }

  Future<void> _create() async {
    final name = _controller.text.trim();
    if (name.isEmpty) {
      _showError('请输入项目名称');
      return;
    }
    if (_folder == null || _folder!.trim().isEmpty) {
      _showError('请选择文件夹位置');
      return;
    }
    try {
      final p = await widget.shiyi.addProject(name, workspaceDir: _folder!);
      if (mounted) Navigator.pop(context, p);
    } catch (e) {
      _showError('创建项目失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoAlertDialog(
      title: const Text('新建项目'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CupertinoTextField(
            controller: _controller,
            autofocus: true,
            placeholder: '项目名称',
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            clearButtonMode: OverlayVisibilityMode.editing,
            onSubmitted: (_) => _create(),
          ),
          const SizedBox(height: 12),
          CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: _pickFolder,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              decoration: BoxDecoration(
                color: iosSectionBackground(context),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(CupertinoIcons.folder, size: 18, color: _iosBlue),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _folder ?? '选择文件夹位置',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _folder == null
                            ? Theme.of(context).colorScheme.onSurfaceVariant
                            : Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ),
                  Icon(
                    CupertinoIcons.chevron_right,
                    size: 14,
                    color: Theme.of(context).hintColor,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: _create,
          child: const Text('创建'),
        ),
      ],
    );
  }
}

/// 设置 / 清除项目级工作目录。
Future<void> showProjectFolderSheet(
  BuildContext context,
  ShiyiState shiyi,
  Project project,
) async {
  final action = await showIosFadeModalPopup<String>(
    context: context,
    builder: (ctx) => CupertinoTheme(
      data: iosCupertinoTheme(context),
      child: CupertinoActionSheet(
        title: Text(
          '「${project.name}」工作目录',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        message: Text(
          project.workspaceDir.isEmpty ? '未设置（会话用全局默认）' : project.workspaceDir,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, 'pick'),
            child: const Text('选择文件夹'),
          ),
          if (project.workspaceDir.isNotEmpty)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(ctx, 'clear'),
              child: const Text('清除项目目录'),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
      ),
    ),
  );
  if (action == null) return;
  if (action == 'clear') {
    await shiyi.setProjectWorkspace(project.id, '');
    return;
  }
  final dir = await FilePicker.platform.getDirectoryPath();
  if (dir == null || dir.trim().isEmpty) return;
  await shiyi.setProjectWorkspace(project.id, dir);
}

/// 重命名项目。
Future<void> renameProjectDialog(
  BuildContext context,
  ShiyiState shiyi,
  Project project,
) async {
  final name = await showIosFadeDialog<String>(
    context: context,
    builder: (ctx) => CupertinoTheme(
      data: iosCupertinoTheme(context),
      child: _RenameProjectDialog(project: project),
    ),
  );
  if (name == null || name.isEmpty) return;
  await shiyi.renameProject(project.id, name);
}

class _RenameProjectDialog extends StatefulWidget {
  final Project project;
  const _RenameProjectDialog({required this.project});

  @override
  State<_RenameProjectDialog> createState() => _RenameProjectDialogState();
}

class _RenameProjectDialogState extends State<_RenameProjectDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.project.name,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoAlertDialog(
      title: const Text('重命名项目'),
      content: CupertinoTextField(
        controller: _controller,
        autofocus: true,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        clearButtonMode: OverlayVisibilityMode.editing,
        onSubmitted: (v) => Navigator.pop(context, v.trim()),
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

/// 删除项目；项目下会话移回未分类，不删除会话。
Future<void> deleteProjectDialog(
  BuildContext context,
  ShiyiState shiyi,
  Project project,
) async {
  final ok = await showIosFadeDialog<bool>(
    context: context,
    builder: (ctx) => CupertinoTheme(
      data: iosCupertinoTheme(context),
      child: CupertinoAlertDialog(
        title: const Text('删除项目'),
        content: Text('删除项目「${project.name}」？项目下会话会移到「未分类」，不会删除会话。'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    ),
  );
  if (ok == true) await shiyi.deleteProject(project.id);
}
