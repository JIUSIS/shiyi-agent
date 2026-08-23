import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Material, MaterialType;
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../services/update_service.dart';
import '../widgets/ios_style.dart';
import '../widgets/welcome_avatar.dart';

const _iosBlue = Color(0xFF0A84FF);
const _iosGreen = Color(0xFF34C759);
const _iosPurple = Color(0xFFAF52DE);
const _iosOrange = Color(0xFFFF9500);
const _iosPink = Color(0xFFFF2D55);
const _iosTeal = Color(0xFF64D2FF);
const _iosIndigo = Color(0xFF5856D6);
const _iosGray = Color(0xFF8E8E93);

bool _aboutIsDark(BuildContext context, String themeMode) {
  final platformDark =
      MediaQuery.platformBrightnessOf(context) == Brightness.dark;
  return themeMode == 'dark' || (themeMode == 'system' && platformDark);
}

/// 关于页：iOS Inset Grouped 分组列表，完整列出拾忆现有功能。
class AboutScreen extends StatefulWidget {
  final ShiyiState shiyi;
  const AboutScreen({super.key, required this.shiyi});

  static const String appName = '拾忆 ShiYi';

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

/// 功能特性（完整功能名 + 一句话说明）。
const _features = <(IconData, Color, String, String)>[
  (
    CupertinoIcons.sparkles,
    _iosIndigo,
    '双引擎切换',
    '拾忆本地引擎或 DeepSeek Harness，会话数据各自独立',
  ),
  (
    CupertinoIcons.square_stack_3d_up_fill,
    _iosBlue,
    '多模型 API',
    'OpenAI / Anthropic / Gemini / DeepSeek 等常见接口，会话可单独选配置',
  ),
  (
    CupertinoIcons.chat_bubble_2_fill,
    _iosGreen,
    '多轮对话与会话管理',
    '独立会话、流式输出、思考过程、悬空输入区与消息入场动画',
  ),
  (CupertinoIcons.person_2_fill, _iosTeal, '子代理协作', '派出专项子代理分头处理任务，进度实时可见'),
  (CupertinoIcons.folder_fill, _iosOrange, '项目分类管理', '项目文件夹统一管理会话与工作目录'),
  (CupertinoIcons.doc_text_fill, _iosTeal, '文件与附件', '会话附件、路径浏览，以及图片视觉理解'),
  (CupertinoIcons.bookmark_fill, _iosPink, '长期记忆', '自动沉淀偏好、决定与项目背景，支持检索管理'),
  (CupertinoIcons.bolt_fill, _iosIndigo, '技能系统', '输入 / 快速调用，支持导入与自定义技能包'),
  (
    CupertinoIcons.desktopcomputer,
    _iosGray,
    '内置终端',
    '底部「终端」栏接入同一套 Alpine / proot，bash / python3 / apk，无需另装 Termux',
  ),
  (CupertinoIcons.globe, _iosBlue, '网页搜索与内容提取', '联网搜索、抓取网页正文；可走自定义 SOCKS5'),
  (
    CupertinoIcons.lock_shield_fill,
    _iosTeal,
    'SOCKS5 代理',
    '自动检测本机 Clash，或手动添加境外代理服务器',
  ),
  (
    CupertinoIcons.square_on_square,
    _iosTeal,
    '上下文压缩',
    '大上下文自动压缩、手动压缩、思考开关与强度可按会话调节',
  ),
  (CupertinoIcons.speedometer, _iosGreen, '缓存与思考强度', '缓存命中率统计，思考开关与强度可按会话调节'),
  (CupertinoIcons.speaker_3_fill, _iosPink, '语音朗读', '可调节语速的文本朗读'),
  (CupertinoIcons.paintbrush_fill, _iosPurple, '深浅色主题', '浅色 / 深色 / 跟随系统'),
  (
    CupertinoIcons.cloud_download_fill,
    _iosBlue,
    '自动检查更新',
    '启动时检查 GitHub Releases',
  ),
];

class _AboutScreenState extends State<AboutScreen> {
  bool _checking = false;
  String _version = UpdateService.appVersion;

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final v = await UpdateService.currentVersion();
    if (mounted) setState(() => _version = v);
  }

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
            'v$_version 已经是最新版本。',
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

  Future<void> _copyRepoUrl() async {
    await Clipboard.setData(const ClipboardData(text: UpdateService.repoUrl));
    if (mounted) {
      _showIosAlert(context, '完成', '项目链接已复制');
    }
  }

  Future<void> _showIosAlert(
    BuildContext context,
    String title,
    String message,
  ) {
    return showIosFadeDialog<void>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text(title),
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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.shiyi,
      builder: (context, _) {
        final dark = _aboutIsDark(context, widget.shiyi.settings.themeMode);
        return CupertinoTheme(
          data: iosCupertinoTheme(context),
          child: Material(
            type: MaterialType.transparency,
            child: CupertinoPageScaffold(
              backgroundColor: dark
                  ? const Color(0xFF000000)
                  : const Color(0xFFF2F2F7),
              navigationBar: CupertinoNavigationBar(
                backgroundColor: dark
                    ? const Color(0xE6000000)
                    : const Color(0xE6F2F2F7),
                middle: const Text('关于'),
              ),
              child: SafeArea(
                bottom: false,
                child: ListView(
                  padding: const EdgeInsets.only(top: 8, bottom: 36),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                      child: Center(
                        child: WelcomeAvatar(
                          size: 112,
                          asset: 'assets/avatar.png',
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            AboutScreen.appName,
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: dark
                                  ? const Color(0xFF2C2C2E)
                                  : CupertinoColors.systemGrey5,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              'v$_version',
                              style: TextStyle(
                                fontSize: 12,
                                color: dark
                                    ? CupertinoColors.white.withValues(
                                        alpha: .6,
                                      )
                                    : CupertinoColors.black.withValues(
                                        alpha: .55,
                                      ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Text(
                        '愿中国青年都摆脱冷气，只是向上走，不必听自暴自弃者流的话。'
                        '能做事的做事，能发声的发声。有一分热，发一分光，'
                        '就令萤火一般，也可以在黑暗里发一点光，不必等候炬火。',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          color: dark
                              ? CupertinoColors.white.withValues(alpha: .6)
                              : CupertinoColors.black.withValues(alpha: .55),
                          height: 1.4,
                        ),
                      ),
                    ),
                    CupertinoListSection.insetGrouped(
                      header: const Text('功能特性'),
                      children: [
                        for (final f in _features)
                          CupertinoListTile(
                            leading: _AboutIconTile(icon: f.$1, color: f.$2),
                            title: Text(f.$3),
                            subtitle: Text(f.$4),
                          ),
                      ],
                    ),
                    CupertinoListSection.insetGrouped(
                      header: const Text('项目'),
                      children: [
                        CupertinoListTile(
                          leading: const _AboutIconTile(
                            icon: CupertinoIcons.link,
                            color: _iosBlue,
                          ),
                          title: const Text(
                            'github.com/JIUSIS/shiyi-agent',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: const Text('点击复制项目链接'),
                          trailing: const CupertinoListTileChevron(),
                          onTap: _copyRepoUrl,
                        ),
                        CupertinoListTile(
                          leading: _AboutIconTile(
                            icon: _checking
                                ? CupertinoIcons.hourglass
                                : CupertinoIcons.cloud_download_fill,
                            color: _iosGreen,
                          ),
                          title: const Text('检查更新'),
                          subtitle: Text(
                            _checking ? '正在检查…' : '从 GitHub Releases 检查新版本',
                          ),
                          trailing: _checking
                              ? const CupertinoActivityIndicator()
                              : const CupertinoListTileChevron(),
                          onTap: _checkUpdate,
                        ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 18),
                      child: Text(
                        '本项目基于 GPL-3.0 协议开源\n使用、修改与分发请遵守 GPL-3.0 条款',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: dark
                              ? CupertinoColors.white.withValues(alpha: .5)
                              : CupertinoColors.black.withValues(alpha: .5),
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _AboutIconTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  const _AboutIconTile({required this.icon, required this.color});

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
