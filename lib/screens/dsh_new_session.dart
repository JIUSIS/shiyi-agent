import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../services/dsh_api.dart';
import '../services/dsh_service.dart';
import '../widgets/ios_style.dart';

const _builtInNames = <String, String>{
  'standard': '标准模式',
  'code': 'PTC 模式',
  'minimal': '极简模式',
  'cordis': '创造模式',
};

const _builtInDescriptions = <String, String>{
  'standard': '功能完整的编码 Agent，支持文件编辑、Shell、检索、技能与子代理。',
  'code': '标准模式全部能力，并以 Code Mode SDK 组合多步操作。',
  'minimal': '仅持久 bash 与 str_replace_editor 的双工具编码 Agent。',
  'cordis': '用于创建自定义预设，带运行时检查与创作指导。',
};

/// 预设展示名：官方内置四档使用中文名，其余用服务端元数据兜底。
String dshPresetDisplayName(DshPresetInfo preset) {
  if (preset.trust == 'system') {
    final builtIn = _builtInNames[preset.id];
    if (builtIn != null) return builtIn;
  }
  return preset.name ?? preset.id;
}

String? dshPresetDescription(DshPresetInfo preset) {
  if (preset.trust == 'system') {
    final builtIn = _builtInDescriptions[preset.id];
    if (builtIn != null) return builtIn;
  }
  return preset.description;
}

/// 新建 DSH 会话前选择 Agent 预设。
///
/// 返回选中预设 id；`null` = 用户取消；`''` = 预设目录读取失败，按 DSH
/// 当前默认创建（兼容未挂 agentPreset 服务的旧版本）。
Future<String?> pickDshAgentPreset(
  BuildContext context, {
  DshApiClient? api,
}) async {
  final presets = <DshPresetInfo>[];
  try {
    final roster = await (api ?? DshService.instance.api).listPresets();
    presets.addAll(
      roster.presets.where((p) => p.broken == null || p.broken!.isEmpty),
    );
  } catch (_) {
    return '';
  }
  if (!context.mounted) return null;
  if (presets.isEmpty) return '';
  final defaultId =
      presets.where((p) => p.isDefault).firstOrNull?.id ?? presets.first.id;
  return showIosFadeModalPopup<String>(
    context: context,
    builder: (ctx) => CupertinoTheme(
      data: iosCupertinoTheme(ctx),
      child: _DshPresetPickerSheet(presets: presets, defaultId: defaultId),
    ),
  );
}

class _DshPresetPickerSheet extends StatelessWidget {
  final List<DshPresetInfo> presets;
  final String defaultId;

  const _DshPresetPickerSheet({required this.presets, required this.defaultId});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final system = presets.where((p) => p.trust == 'system').toList();
    final user = presets.where((p) => p.trust == 'user').toList();
    final hairline = dark
        ? Colors.white.withValues(alpha: 0.10)
        : Colors.black.withValues(alpha: 0.08);
    return Material(
      color: dark ? const Color(0xFF000000) : const Color(0xFFF2F2F7),
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight:
                MediaQuery.sizeOf(context).height *
                (Platform.isWindows ? 0.72 : 0.82),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '选择 Agent 预设',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: dark
                            ? CupertinoColors.white
                            : CupertinoColors.black,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '会话开始后预设固定，会决定它的工具与能力。',
                      style: TextStyle(
                        fontSize: 13,
                        color: dark
                            ? CupertinoColors.white.withValues(alpha: 0.55)
                            : CupertinoColors.black.withValues(alpha: 0.55),
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
                  shrinkWrap: true,
                  children: [
                    if (system.isNotEmpty)
                      CupertinoListSection.insetGrouped(
                        header: const Text('系统预设'),
                        children: [for (final p in system) _option(context, p)],
                      ),
                    if (user.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      CupertinoListSection.insetGrouped(
                        header: const Text('自定义'),
                        children: [for (final p in user) _option(context, p)],
                      ),
                    ],
                  ],
                ),
              ),
              Container(
                decoration: BoxDecoration(
                  color: dark ? const Color(0xFF1C1C1E) : Colors.white,
                  border: Border(top: BorderSide(color: hairline)),
                ),
                child: CupertinoButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _option(BuildContext context, DshPresetInfo p) {
    final (icon, color) = _presetVisual(p);
    final description = dshPresetDescription(p);
    return CupertinoListTile(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 16, 12),
      leadingSize: 29,
      leadingToTitle: 12,
      leading: _PresetIconTile(icon: icon, color: color),
      title: Text(
        dshPresetDisplayName(p),
        style: TextStyle(
          fontSize: 17,
          height: 22 / 17,
          fontWeight: FontWeight.w400,
          color: CupertinoColors.label.resolveFrom(context),
        ),
      ),
      subtitle: description == null || description.isEmpty
          ? null
          : Text(
              description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                height: 18 / 13,
                fontWeight: FontWeight.w400,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
      trailing: p.id == defaultId
          ? Icon(
              CupertinoIcons.checkmark_circle_fill,
              size: 20,
              color: CupertinoColors.systemBlue,
            )
          : const CupertinoListTileChevron(),
      onTap: () => Navigator.pop(context, p.id),
    );
  }

  (IconData, Color) _presetVisual(DshPresetInfo p) {
    if (p.trust == 'system') {
      switch (p.id) {
        case 'standard':
          return (CupertinoIcons.sparkles, CupertinoColors.systemBlue);
        case 'code':
          return (
            CupertinoIcons.chevron_left_slash_chevron_right,
            CupertinoColors.systemPurple,
          );
        case 'minimal':
          return (CupertinoIcons.bolt_fill, CupertinoColors.systemOrange);
        case 'cordis':
          return (CupertinoIcons.wand_stars, CupertinoColors.systemGreen);
      }
    }
    return (CupertinoIcons.person_crop_circle_fill, CupertinoColors.systemTeal);
  }
}

class _PresetIconTile extends StatelessWidget {
  final IconData icon;
  final Color color;

  const _PresetIconTile({required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 29,
      height: 29,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Icon(icon, size: 16, color: color),
    );
  }
}
