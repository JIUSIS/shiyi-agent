import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import 'project_actions.dart';

/// 项目管理页：新建 / 重命名 / 删除项目，并显示每个项目下的会话数。
class ProjectsScreen extends StatelessWidget {
  final ShiyiState shiyi;
  const ProjectsScreen({super.key, required this.shiyi});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([
        shiyi.projectsRevision,
        shiyi.sessionsRevision,
      ]),
      builder: (context, _) {
        final projects = List<Project>.from(shiyi.projects);
        return Scaffold(
          appBar: AppBar(title: const Text('项目管理')),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonalIcon(
                    onPressed: () => createProjectWithFolder(context, shiyi),
                    icon: const Icon(Icons.add),
                    label: const Text('新建项目'),
                  ),
                ),
              ),
              Expanded(
                child: projects.isEmpty
                    ? Center(
                        child: Text(
                          '还没有项目\n新建项目后，可把会话归类管理',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.all(12),
                        itemCount: projects.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, i) {
                          final p = projects[i];
                          return ListTile(
                            dense: true,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(
                                color: theme.colorScheme.outlineVariant,
                              ),
                            ),
                            leading: Icon(
                              Icons.folder_copy_outlined,
                              color: theme.colorScheme.primary,
                            ),
                            title: Text(
                              p.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              p.workspaceDir.isEmpty
                                  ? '${p.sessionCount} 个会话 · 目录未设置'
                                  : '${p.sessionCount} 个会话 · ${p.workspaceDir}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  tooltip: '设置工作目录',
                                  icon: const Icon(Icons.folder_open_outlined),
                                  onPressed: () =>
                                      showProjectFolderSheet(context, shiyi, p),
                                ),
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  tooltip: '重命名',
                                  icon: const Icon(Icons.edit_outlined),
                                  onPressed: () =>
                                      renameProjectDialog(context, shiyi, p),
                                ),
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  tooltip: '删除',
                                  icon: Icon(
                                    Icons.delete_outline,
                                    color: theme.colorScheme.error,
                                  ),
                                  onPressed: () =>
                                      deleteProjectDialog(context, shiyi, p),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
