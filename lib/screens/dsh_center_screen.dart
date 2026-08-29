import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/mac_page_route.dart';
import '../services/dsh_endpoint.dart';
import '../services/dsh_service.dart';
import '../services/update_service.dart';
import '../widgets/ios_style.dart';
import 'about_screen.dart';
import 'dsh_models_screen.dart';
import 'dsh_presets_screen.dart';
import 'dsh_settings_screen.dart';
import 'log_screen.dart';
import 'settings_screen.dart';

const _iosBlue = Color(0xFF0A84FF);
const _iosOrange = Color(0xFFFF9500);
const _iosPurple = Color(0xFFAF52DE);
const _iosIndigo = Color(0xFF5856D6);
const _iosGray = Color(0xFF8E8E93);

Color _iosGroupedBackground(bool dark) =>
    dark ? const Color(0xFF000000) : const Color(0xFFF2F2F7);

BoxDecoration _iosSectionDecoration(bool dark) => BoxDecoration(
  color: dark ? const Color(0xFF1C1C1E) : const Color(0xFFFFFFFF),
  borderRadius: BorderRadius.circular(10),
);

bool _isDark(BuildContext context, String themeMode) {
  final platformDark =
      MediaQuery.platformBrightnessOf(context) == Brightness.dark;
  return themeMode == 'dark' || (themeMode == 'system' && platformDark);
}

/// DeepSeek Harness 设置根页：拾忆设置同款大标题 + Inset Grouped。
/// 只保留 DSH 有的入口：模型 / 预设 / 引擎 / 凭据；工作区、技能、文件已在功能页，不进设置。
/// 外观 / 关于 / 日志是 App 级，两边共用。
class DshCenterScreen extends StatefulWidget {
  final String? sessionId;
  final ShiyiState? shiyi;
  const DshCenterScreen({super.key, this.sessionId, this.shiyi});

  @override
  State<DshCenterScreen> createState() => _DshCenterScreenState();
}

class _DshCenterScreenState extends State<DshCenterScreen> {
  bool _running = false;
  String? _localVersion;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final shiyi = widget.shiyi;
    if (shiyi != null) {
      DshService.instance.applyConnection(shiyi.settings);
    }
    if (shiyi != null && !DshEndpoint.isLocal(shiyi.settings)) {
      _running = await DshService.instance.isRunning();
      _localVersion = DshEndpoint.displayHost(
        DshEndpoint.urlOf(shiyi.settings),
      );
    } else {
      _localVersion = await DshService.instance.localVersion();
      if (_localVersion != null && _localVersion!.isNotEmpty) {
        _running = await DshService.instance.isRunning();
      } else {
        _running = false;
      }
    }
    if (mounted) setState(() {});
  }

  void _open(Widget page) {
    Navigator.push(context, MacPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    final shiyi = widget.shiyi;
    if (shiyi != null) {
      return ListenableBuilder(
        listenable: shiyi,
        builder: (context, _) => _page(context, shiyi),
      );
    }
    return _page(context, null);
  }

  Widget _page(BuildContext context, ShiyiState? shiyi) {
    final themeMode = shiyi?.settings.themeMode ?? 'system';
    final dark = _isDark(context, themeMode);
    final sid = widget.sessionId;
    final remote = shiyi != null && !DshEndpoint.isLocal(shiyi.settings);
    final installed = _localVersion != null && _localVersion!.isNotEmpty;
    final engineSub = remote
        ? (_running
              ? 'DeepSeek Harness · 已连接 · ${_localVersion ?? DshEndpoint.shortLabel(shiyi.settings)}'
              : 'DeepSeek Harness · 未连接 · ${DshEndpoint.shortLabel(shiyi.settings)}')
        : !installed
        ? 'DeepSeek Harness · 未安装'
        : _running
        ? 'DeepSeek Harness · 服务运行中 · $_localVersion'
        : 'DeepSeek Harness · 服务未运行';
    return CupertinoTheme(
      data: iosCupertinoTheme(context),
      child: Material(
        type: MaterialType.transparency,
        child: CupertinoPageScaffold(
          backgroundColor: _iosGroupedBackground(dark),
          child: SafeArea(
            bottom: false,
            child: ColoredBox(
              color: _iosGroupedBackground(dark),
              child: ListView(
                padding: const EdgeInsets.only(top: 8, bottom: 36),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 20, 4),
                    child: Row(
                      children: [
                        if (Platform.isWindows) ...[
                          Tooltip(
                            message: '返回',
                            child: CupertinoButton(
                              padding: const EdgeInsets.all(6),
                              onPressed: () => Navigator.of(context).maybePop(),
                              child: const Icon(CupertinoIcons.back, size: 22),
                            ),
                          ),
                          const SizedBox(width: 4),
                        ],
                        Text(
                          '设置',
                          style: TextStyle(
                            fontSize: 34,
                            fontWeight: FontWeight.w700,
                            color: dark
                                ? CupertinoColors.white
                                : CupertinoColors.black,
                          ),
                        ),
                      ],
                    ),
                  ),
                  CupertinoListSection.insetGrouped(
                    decoration: _iosSectionDecoration(dark),
                    backgroundColor: _iosGroupedBackground(dark),
                    header: const Text('模型'),
                    children: [
                      _navTile(
                        icon: CupertinoIcons.square_stack_3d_up_fill,
                        color: _iosBlue,
                        title: '模型',
                        subtitle: shiyi == null
                            ? '提供商 / 模型目录'
                            : '拾忆接口地址 / 密钥 / 模型与预设',
                        onTap: () => _open(
                          shiyi == null
                              ? DshModelsScreen(sessionId: sid)
                              : shiyiModelApiSettingsPage(shiyi),
                        ),
                      ),
                      _navTile(
                        icon: CupertinoIcons.person_crop_circle,
                        color: _iosOrange,
                        title: 'Agent 预设',
                        subtitle: '标准 / Android 精简 / 自建',
                        onTap: () => _open(DshPresetsScreen(sessionId: sid)),
                      ),
                    ],
                  ),
                  if (shiyi != null)
                    CupertinoListSection.insetGrouped(
                      decoration: _iosSectionDecoration(dark),
                      backgroundColor: _iosGroupedBackground(dark),
                      header: const Text('对话'),
                      children: [
                        _navTile(
                          icon: CupertinoIcons.sparkles,
                          color: _iosIndigo,
                          title: 'Agent 引擎',
                          subtitle: engineSub,
                          onTap: () => _open(AgentEnginePage(shiyi: shiyi)),
                        ),
                      ],
                    ),
                  CupertinoListSection.insetGrouped(
                    decoration: _iosSectionDecoration(dark),
                    backgroundColor: _iosGroupedBackground(dark),
                    header: const Text('通用'),
                    children: [
                      if (shiyi != null)
                        _navTile(
                          icon: CupertinoIcons.paintbrush_fill,
                          color: _iosPurple,
                          title: '外观',
                          subtitle: shiyiThemeModeLabel(themeMode),
                          onTap: () =>
                              _open(shiyiAppearanceSettingsPage(shiyi)),
                        ),
                    ],
                  ),
                  CupertinoListSection.insetGrouped(
                    decoration: _iosSectionDecoration(dark),
                    backgroundColor: _iosGroupedBackground(dark),
                    header: const Text('支持'),
                    children: [
                      _navTile(
                        icon: CupertinoIcons.doc_text_search,
                        color: _iosOrange,
                        title: 'DSH 高级诊断',
                        subtitle: '凭据状态 / 原始命名空间',
                        onTap: () => _open(const DshSettingsScreen()),
                      ),
                      if (shiyi != null)
                        _navTile(
                          icon: CupertinoIcons.info_circle_fill,
                          color: _iosBlue,
                          title: '关于',
                          subtitle: '版本、检查更新与功能特性',
                          onTap: () => _open(AboutScreen(shiyi: shiyi)),
                        ),
                      _navTile(
                        icon: CupertinoIcons.doc_text_fill,
                        color: _iosGray,
                        title: '日志',
                        subtitle: '查看智能体运行与错误日志',
                        onTap: () => _open(const LogScreen()),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 18),
                    child: FutureBuilder<String>(
                      future: UpdateService.currentVersion(),
                      builder: (context, snap) => Center(
                        child: Text(
                          '拾忆 v${snap.data ?? UpdateService.appVersion}'
                          '${_localVersion == null ? '' : ' · DSH $_localVersion'}',
                          style: TextStyle(
                            fontSize: 13,
                            color: dark
                                ? CupertinoColors.white.withValues(alpha: .6)
                                : CupertinoColors.black.withValues(alpha: .55),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Widget _navTile({
  required IconData icon,
  required Color color,
  required String title,
  required String subtitle,
  required VoidCallback onTap,
}) {
  return CupertinoListTile(
    leading: Container(
      width: 31,
      height: 31,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Icon(icon, size: 17, color: CupertinoColors.white),
    ),
    title: Text(title),
    subtitle: Text(subtitle),
    trailing: const CupertinoListTileChevron(),
    onTap: onTap,
  );
}
