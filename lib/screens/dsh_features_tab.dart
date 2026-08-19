import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/mac_page_route.dart';
import '../services/dsh_service.dart';
import '../widgets/ios_style.dart';
import '../widgets/mac_action_button.dart';
import '../widgets/traffic_lights_button.dart';
import 'dsh_center_screen.dart';
import 'dsh_models_screen.dart';
import 'dsh_plugins_screen.dart';
import 'dsh_skills_screen.dart';
import 'dsh_workspaces_screen.dart';

const _skillPurple = Color(0xFFAF52DE);
const _modelOrange = Color(0xFFFF9F0A);
const _workspaceTeal = Color(0xFF30B0C7);
const _pluginIndigo = Color(0xFF5856D6);

/// DS Harness 引擎的主页 tab 1「功能」：
/// 外观复用拾忆功能页（红绿灯/大标题/彩色功能卡片）。
/// 所有入口都依赖 DSH 服务运行：本页加载时先做安装/运行诊断，
/// 未就绪时统一显示「DSH 未安装 / DSH 未启动」并置灰，3 秒自动重查，
/// 服务就绪后入口自动恢复。
class DshFeaturesTab extends StatefulWidget {
  final ShiyiState shiyi;
  const DshFeaturesTab({super.key, required this.shiyi});

  @override
  State<DshFeaturesTab> createState() => _DshFeaturesTabState();
}

class _DshFeaturesTabState extends State<DshFeaturesTab> {
  String? _unavailableReason = 'DSH 检测中…';
  Timer? _statusTimer;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    DshService.instance.status.addListener(_onDshStatus);
    unawaited(_checkStatus());
    _statusTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _checkStatus(),
    );
  }

  @override
  void dispose() {
    DshService.instance.status.removeListener(_onDshStatus);
    _statusTimer?.cancel();
    super.dispose();
  }

  void _onDshStatus() => _checkStatus();

  Future<void> _checkStatus() async {
    if (_checking) return;
    _checking = true;
    try {
      final reason = await DshService.instance.unavailableReason();
      if (!mounted) return;
      if (reason != _unavailableReason) {
        setState(() => _unavailableReason = reason);
      }
    } finally {
      _checking = false;
    }
  }

  void _showUnavailable() {
    final reason = _unavailableReason ?? 'DSH 服务不可用';
    final waiting = reason.contains('中');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          waiting
              ? '$reason，请稍候再试'
              : '$reason，请先到「Agent 引擎」安装或启动 DeepSeek Harness',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final available = _unavailableReason == null;
    return CupertinoTheme(
      data: iosCupertinoTheme(context),
      child: Scaffold(
        backgroundColor: iosGroupedBackground(context),
        appBar: AppBar(
          leadingWidth: 72,
          leading: Platform.isWindows
              ? null
              : Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: TrafficLightsButton(tooltip: '', busy: false),
                ),
          toolbarHeight: 64,
          centerTitle: true,
          backgroundColor: theme.scaffoldBackgroundColor,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          clipBehavior: Clip.none,
          title: const Text(
            '功能',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FrostedSettingsButton(
                onPressed: () => Navigator.push(
                  context,
                  MacPageRoute(
                    builder: (_) => DshCenterScreen(shiyi: widget.shiyi),
                  ),
                ),
              ),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.only(top: 4, bottom: 28),
          children: [
            if (_unavailableReason != null) _statusBanner(_unavailableReason!),
            CupertinoListSection.insetGrouped(
              margin: iosSectionMargin,
              decoration: iosSectionDecoration(context),
              children: [
                _FeatureTile(
                  icon: CupertinoIcons.archivebox_fill,
                  color: _workspaceTeal,
                  title: '工作数据',
                  subtitle: available ? '目录 / 项目 / 会话归档' : _unavailableReason!,
                  enabled: available,
                  onTap: available
                      ? () => Navigator.push(
                          context,
                          MacPageRoute(
                            builder: (_) => const DshWorkspacesScreen(),
                          ),
                        )
                      : _showUnavailable,
                ),
                _FeatureTile(
                  icon: CupertinoIcons.square_stack_3d_up_fill,
                  color: _modelOrange,
                  title: '模型数据',
                  subtitle: available ? '已注入 API 配置 / 删除' : _unavailableReason!,
                  enabled: available,
                  onTap: available
                      ? () => Navigator.push(
                          context,
                          MacPageRoute(
                            builder: (_) =>
                                DshModelsScreen(shiyi: widget.shiyi),
                          ),
                        )
                      : _showUnavailable,
                ),
                _FeatureTile(
                  icon: CupertinoIcons.rocket_fill,
                  color: _skillPurple,
                  title: '技能',
                  subtitle: available
                      ? 'DeepSeek Harness 技能包目录'
                      : _unavailableReason!,
                  enabled: available,
                  onTap: available
                      ? () => Navigator.push(
                          context,
                          MacPageRoute(
                            builder: (_) =>
                                DshSkillsScreen(shiyi: widget.shiyi),
                          ),
                        )
                      : _showUnavailable,
                ),
                _FeatureTile(
                  icon: CupertinoIcons.square_grid_2x2,
                  color: _pluginIndigo,
                  title: '插件',
                  subtitle: available
                      ? '已装载插件 · 启停 / 删除 / 配置'
                      : _unavailableReason!,
                  enabled: available,
                  onTap: available
                      ? () => Navigator.push(
                          context,
                          MacPageRoute(
                            builder: (_) => const DshPluginsScreen(),
                          ),
                        )
                      : _showUnavailable,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusBanner(String reason) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final severe = reason.contains('未安装') || reason.contains('未启动');
    final color = severe
        ? CupertinoColors.systemRed
        : CupertinoColors.systemOrange;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 2, 12, 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: dark ? 0.22 : 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            CupertinoIcons.exclamationmark_triangle_fill,
            color: color,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              reason,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FeatureTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool enabled;
  const _FeatureTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final dim = !enabled;
    return CupertinoListTile(
      leading: Opacity(
        opacity: dim ? 0.45 : 1,
        child: Container(
          width: 31,
          height: 31,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Icon(icon, size: 17, color: CupertinoColors.white),
        ),
      ),
      title: Text(
        title,
        style: dim
            ? const TextStyle(color: CupertinoColors.secondaryLabel)
            : null,
      ),
      subtitle: Text(
        subtitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: dim ? const TextStyle(color: CupertinoColors.systemGrey) : null,
      ),
      trailing: Icon(
        CupertinoIcons.chevron_right,
        size: 16,
        color: dim
            ? CupertinoColors.systemGrey
            : CupertinoColors.secondaryLabel,
      ),
      onTap: onTap,
    );
  }
}
