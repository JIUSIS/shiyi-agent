import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/update_service.dart';
import '../widgets/welcome_avatar.dart';

/// 关于页：应用信息、检查更新、项目主页与版权说明。
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  static const String appName = '拾忆 ShiYi';

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

/// 功能特性列表（与 README 保持一致）。
const _features = <(IconData, String)>[
  (Icons.api, '接入不同 LLM API，自由切换模型'),
  (Icons.forum_outlined, '多轮对话与独立会话管理'),
  (Icons.folder_outlined, '每个会话可设置独立项目工作目录'),
  (Icons.attach_file_outlined, '文件 / 图片附件，支持视觉模型'),
  (Icons.terminal, '内置免 root 终端（bash / python3 / apt 装包）'),
  (Icons.psychology_outlined, '长期记忆：记住偏好与项目背景'),
  (Icons.bolt_outlined, '技能系统：输入 / 快速选择技能'),
  (Icons.travel_explore, '网页搜索与网页内容提取'),
  (Icons.record_voice_over_outlined, '语音朗读、深浅色主题'),
];

class _AboutScreenState extends State<AboutScreen> {
  bool _checking = false;

  Future<void> _checkUpdate() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final result = await UpdateService.check();
      if (!mounted) return;
      switch (result.status) {
        case UpdateCheckStatus.updateAvailable:
          UpdateService.showUpdateAvailable(context, result.tag, result.notes);
        case UpdateCheckStatus.upToDate:
          UpdateService.showPlainDialog(
            context,
            '当前已是最新版本',
            'v${UpdateService.appVersion} 已经是最新版本。',
          );
        case UpdateCheckStatus.failed:
          UpdateService.showPlainDialog(
            context,
            '检查更新失败',
            '无法获取版本信息，请检查网络后重试。',
          );
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            children: [
              Center(
                child: WelcomeAvatar(size: 100, asset: 'assets/avatar.png'),
              ),
              const SizedBox(height: 12),
              Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      AboutScreen.appName,
                      style: theme.textTheme.titleLarge!.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: theme.colorScheme.outlineVariant,
                        ),
                      ),
                      child: Text(
                        'v${UpdateService.appVersion}',
                        style: theme.textTheme.labelSmall!.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '个人 AI 工作台：对话、长期记忆、项目文件、内置终端与技能系统，一站式完成。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium!.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                '功能特性',
                style: theme.textTheme.bodySmall!.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              LayoutBuilder(
                builder: (context, constraints) {
                  final itemWidth = (constraints.maxWidth - 8) / 2;
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final f in _features)
                        SizedBox(
                          width: itemWidth,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Icon(
                                  f.$1,
                                  size: 16,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  f.$2,
                                  style: theme.textTheme.bodySmall!.copyWith(
                                    height: 1.35,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 18),
              Card(
                color: theme.colorScheme.surfaceContainerHigh,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    ListTile(
                      dense: true,
                      leading: Icon(
                        Icons.link,
                        color: theme.colorScheme.primary,
                        size: 20,
                      ),
                      title: const Text(
                        'github.com/JIUSIS/shiyi-agent',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: const Text('点击复制链接'),
                      trailing: const Icon(Icons.copy, size: 16),
                      onTap: () async {
                        await Clipboard.setData(
                          const ClipboardData(text: UpdateService.repoUrl),
                        );
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('链接已复制')),
                          );
                        }
                      },
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    ListTile(
                      dense: true,
                      leading: Icon(
                        Icons.system_update_alt,
                        color: theme.colorScheme.primary,
                        size: 20,
                      ),
                      title: const Text('检查更新'),
                      subtitle: Text(
                        _checking ? '正在检查…' : '从 GitHub Releases 检查新版本',
                      ),
                      trailing: _checking
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : null,
                      onTap: _checkUpdate,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Center(
                child: Text(
                  '本项目基于 GPL-3.0 协议开源\n使用、修改与分发请遵守 GPL-3.0 条款',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall!.copyWith(
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: .7,
                    ),
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
