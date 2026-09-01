import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../screens/project_actions.dart';
import 'ios_style.dart';

const _iosBlue = Color(0xFF0A84FF);
const _iosGray = Color(0xFF8E8E93);

/// 选择群聊所属项目文件夹：返回项目 id，空字符串 = 未分类，null = 取消。
Future<String?> showGroupProjectPicker(
  BuildContext context,
  ShiyiState shiyi, {
  String? currentProjectId,
}) {
  return showIosFadeSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: iosGroupedBackground(context),
    builder: (ctx) => ListenableBuilder(
      listenable: shiyi,
      builder: (ctx, _) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _GroupProjectPickerHeader(title: '项目文件夹'),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 12),
                child: CupertinoListSection.insetGrouped(
                  margin: iosSectionMargin,
                  decoration: iosSectionDecoration(ctx),
                  backgroundColor: iosGroupedBackground(ctx),
                  children: [
                    for (final p in shiyi.projects)
                      Dismissible(
                        key: ValueKey('group-project-${p.id}'),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          color: CupertinoColors.destructiveRed,
                          child: const Icon(
                            CupertinoIcons.delete,
                            size: 19,
                            color: CupertinoColors.white,
                          ),
                        ),
                        confirmDismiss: (_) async {
                          await deleteProjectDialog(ctx, shiyi, p);
                          return !shiyi.projects.any((item) => item.id == p.id);
                        },
                        child: CupertinoListTile(
                          leading: const _GroupProjectIconTile(
                            icon: CupertinoIcons.folder_fill,
                            color: _iosBlue,
                          ),
                          title: Text(
                            p.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${p.sessionCount} 个会话'),
                              Text(
                                p.workspaceDir.isEmpty
                                    ? '未设置目录'
                                    : p.workspaceDir,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                          trailing: currentProjectId == p.id
                              ? const Icon(
                                  CupertinoIcons.checkmark,
                                  size: 18,
                                  color: _iosBlue,
                                )
                              : const CupertinoListTileChevron(),
                          onTap: () => Navigator.pop(ctx, p.id),
                        ),
                      ),
                    CupertinoListTile(
                      leading: const _GroupProjectIconTile(
                        icon: CupertinoIcons.tray,
                        color: _iosGray,
                      ),
                      title: const Text('未分类'),
                      trailing:
                          (currentProjectId == null || currentProjectId.isEmpty)
                          ? const Icon(
                              CupertinoIcons.checkmark,
                              size: 18,
                              color: _iosBlue,
                            )
                          : const CupertinoListTileChevron(),
                      onTap: () => Navigator.pop(ctx, ''),
                    ),
                    CupertinoListTile(
                      leading: const _GroupProjectIconTile(
                        icon: CupertinoIcons.folder_badge_plus,
                        color: Color(0xFF30B0C7),
                      ),
                      title: const Text('新建项目文件夹'),
                      trailing: const CupertinoListTileChevron(),
                      onTap: () => _createProject(ctx, shiyi),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> _createProject(BuildContext context, ShiyiState shiyi) async {
  final project = await createProjectWithFolder(context, shiyi);
  if (project == null || !context.mounted) return;
  Navigator.pop(context, project.id);
}

class _GroupProjectIconTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  const _GroupProjectIconTile({required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Icon(icon, size: 17, color: CupertinoColors.white),
    );
  }
}

class _GroupProjectPickerHeader extends StatelessWidget {
  final String? title;
  const _GroupProjectPickerHeader({this.title});

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
