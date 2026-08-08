import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../widgets/welcome_avatar.dart';

/// 关于页：应用信息、检查更新、项目主页与版权说明。
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  static const String appName = '拾忆 ShiYi';
  static const String version = '1.0.1';
  static const String repoUrl = 'https://github.com/JIUSIS/shiyi-agent';
  static const String apiReleaseUrl =
      'https://api.github.com/repos/JIUSIS/shiyi-agent/releases/latest';

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

class _FeatureTile extends StatelessWidget {
  final IconData icon;
  final String label;
  const _FeatureTile({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label, style: theme.textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}

class _AboutScreenState extends State<AboutScreen> {
  bool _checking = false;

  /// 数字分段比较版本号：a > b 返回 1，相等 0，a < b 返回 -1。
  int _compareVersion(String a, String b) {
    final pa = a
        .split(RegExp(r'[.\-]'))
        .map(int.tryParse)
        .whereType<int>()
        .toList();
    final pb = b
        .split(RegExp(r'[.\-]'))
        .map(int.tryParse)
        .whereType<int>()
        .toList();
    final len = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < len; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x > y ? 1 : -1;
    }
    return 0;
  }

  Future<void> _checkUpdate() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final latest = await _fetchLatest();
      if (!mounted) return;
      if (latest == null) {
        _showDialog('检查更新失败', '无法获取版本信息，请检查网络后重试。');
        return;
      }
      final remoteVer = latest.tag.replaceFirst(RegExp('^v'), '');
      if (_compareVersion(remoteVer, AboutScreen.version) > 0) {
        _showUpdateAvailable(remoteVer, latest.notes);
      } else {
        _showDialog('当前已是最新版本', 'v${AboutScreen.version} 已经是最新版本。');
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  /// 获取最新版本：优先 GitHub Releases API，403/网络失败时回退 jsDelivr 镜像。
  /// 返回 null 表示两种来源都不可用。
  Future<({String tag, String notes})?> _fetchLatest() async {
    // ① GitHub Releases API（公开仓库无需鉴权；403 多为区域网络受限/限流）
    try {
      final res = await http
          .get(
            Uri.parse(AboutScreen.apiReleaseUrl),
            headers: const {'User-Agent': 'ShiYi'},
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final d = jsonDecode(res.body) as Map<String, dynamic>;
        return (
          tag: (d['tag_name'] ?? '') as String,
          notes: (d['body'] as String? ?? '').trim(),
        );
      }
      if (res.statusCode == 404) {
        // 仓库没有任何 Release：视为当前版本即最新。
        return (tag: 'v${AboutScreen.version}', notes: '');
      }
    } catch (_) {}
    // ② jsDelivr 镜像（国内可达，不受 GitHub API 限流影响）
    try {
      final res = await http
          .get(
            Uri.parse('https://data.jsdelivr.com/v1/packages/gh/JIUSIS/shiyi-agent'),
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final d = jsonDecode(res.body) as Map<String, dynamic>;
        final versions = (d['versions'] as List? ?? []);
        String? best;
        for (final v in versions) {
          final s = (v is Map ? v['version'] : v)?.toString() ?? '';
          final tag = s.replaceFirst(RegExp('^v'), '');
          if (tag.isEmpty || int.tryParse(tag.split('.').first) == null) {
            continue;
          }
          if (best == null || _compareVersion(tag, best) > 0) best = tag;
        }
        if (best != null) return (tag: 'v$best', notes: '');
      }
    } catch (_) {}
    return null;
  }

  void _showDialog(String title, String message) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _showUpdateAvailable(String ver, String notes) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('发现新版本 v$ver'),
        content: Text(
          notes.isEmpty ? '有新版本可以更新。' : '更新说明：\n\n$notes',
          maxLines: 12,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await Clipboard.setData(
                const ClipboardData(text: AboutScreen.repoUrl),
              );
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('Release 链接已复制，可到浏览器打开下载')),
                );
              }
            },
            child: const Text('复制链接'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
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
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            children: [
              Center(
                child: WelcomeAvatar(size: 84, asset: 'assets/avatar.png'),
              ),
              const SizedBox(height: 16),
              Center(
                child: Text(
                  AboutScreen.appName,
                  style: theme.textTheme.titleLarge!.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Center(
                child: Text(
                  'v${AboutScreen.version}',
                  style: theme.textTheme.bodySmall!.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                '拾忆是一款运行在 Android 手机上的个人 AI 工作台。\n'
                '它将大语言模型、长期记忆、项目文件管理、内置终端和技能系统整合到一个应用中，'
                '让 AI 不只是回答问题，还能读取资料、修改文件、运行命令、整理项目。',
                style: theme.textTheme.bodyMedium!.copyWith(height: 1.6),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 28),
              Text(
                '功能特性',
                style: theme.textTheme.bodySmall!.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Card(
                color: theme.colorScheme.surfaceContainerHigh,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  children: [
                    for (final f in _features) ...[
                      _FeatureTile(icon: f.$1, label: f.$2),
                      if (f != _features.last) const Divider(height: 1, indent: 48),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 28),
              Card(
                color: theme.colorScheme.surfaceContainerHigh,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                child: ListTile(
                  leading: Icon(Icons.link, color: theme.colorScheme.primary),
                  title: const Text(
                    'github.com/JIUSIS/shiyi-agent',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: const Text('点击复制链接'),
                  onTap: () async {
                    await Clipboard.setData(
                      const ClipboardData(text: AboutScreen.repoUrl),
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('链接已复制')),
                      );
                    }
                  },
                ),
              ),
              const SizedBox(height: 8),
              Card(
                color: theme.colorScheme.surfaceContainerHigh,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                child: ListTile(
                  leading: Icon(
                    Icons.system_update_alt,
                    color: theme.colorScheme.primary,
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
              ),
              const SizedBox(height: 28),
              Center(
                child: Text(
                  '本项目基于 GPL-3.0 协议开源\n使用、修改与分发请遵守 GPL-3.0 条款',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall!.copyWith(
                    color: theme.colorScheme.onSurfaceVariant.withValues(alpha: .7),
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
