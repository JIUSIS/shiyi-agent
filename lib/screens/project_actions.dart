import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/models.dart';

/// 新建项目：输入名称并选择工作目录后创建。
Future<Project?> createProjectWithFolder(
  BuildContext context,
  ShiyiState shiyi,
) async {
  final controller = TextEditingController();
  String? folder;
  final created = await showDialog<Project>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        void showError(String message) {
          ScaffoldMessenger.of(
            ctx,
          ).showSnackBar(SnackBar(content: Text(message)));
        }

        return AlertDialog(
          title: const Text('新建项目'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(hintText: '项目名称'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  final dir = await FilePicker.platform.getDirectoryPath();
                  if (dir == null || dir.trim().isEmpty) return;
                  if (!ctx.mounted) return;
                  setState(() => folder = dir.trim());
                },
                icon: const Icon(Icons.folder_open_outlined),
                label: Text(
                  folder ?? '选择文件夹位置',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                final name = controller.text.trim();
                if (name.isEmpty) {
                  showError('请输入项目名称');
                  return;
                }
                if (folder == null || folder!.trim().isEmpty) {
                  showError('请选择文件夹位置');
                  return;
                }
                try {
                  final p = await shiyi.addProject(name, workspaceDir: folder!);
                  if (ctx.mounted) Navigator.pop(ctx, p);
                } catch (e) {
                  showError('创建项目失败：$e');
                }
              },
              child: const Text('创建'),
            ),
          ],
        );
      },
    ),
  );
  controller.dispose();
  return created;
}

/// 设置 / 清除项目级工作目录。
Future<void> showProjectFolderSheet(
  BuildContext context,
  ShiyiState shiyi,
  Project project,
) async {
  final action = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.folder_copy_outlined),
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
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.folder_open_outlined),
            title: const Text('选择文件夹'),
            subtitle: const Text('项目下会话未单独设置时自动使用'),
            onTap: () => Navigator.pop(ctx, 'pick'),
          ),
          if (project.workspaceDir.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.restart_alt),
              title: const Text('清除项目目录'),
              subtitle: const Text('回到全局默认目录'),
              onTap: () => Navigator.pop(ctx, 'clear'),
            ),
        ],
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
  final controller = TextEditingController(text: project.name);
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('重命名项目'),
      content: TextField(
        controller: controller,
        autofocus: true,
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text.trim()),
          child: const Text('确定'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (name == null || name.isEmpty) return;
  await shiyi.renameProject(project.id, name);
}

/// 删除项目；项目下会话移回未分类，不删除会话。
Future<void> deleteProjectDialog(
  BuildContext context,
  ShiyiState shiyi,
  Project project,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('删除项目'),
      content: Text('删除项目「${project.name}」？项目下会话会移到「未分类」，不会删除会话。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
          ),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  if (ok == true) await shiyi.deleteProject(project.id);
}
