import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import '../services/skill_pack.dart';
import '../widgets/ios_style.dart';
import '../widgets/markdown_text.dart';
import '../widgets/traffic_lights_button.dart';

class SkillsScreen extends StatelessWidget {
  final ShiyiState shiyi;
  const SkillsScreen({super.key, required this.shiyi});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CupertinoTheme(
      data: CupertinoThemeData(brightness: theme.brightness),
      child: ListenableBuilder(
        listenable: shiyi,
        builder: (context, _) {
          return Scaffold(
            backgroundColor: iosGroupedBackground(context),
            appBar: AppBar(
              leadingWidth: 72,
              leading: Padding(
                padding: const EdgeInsets.only(left: 12),
                child: TrafficLightsButton(
                  busy: shiyi.isBusy,
                  tooltip: '新建技能',
                  onTap: () => _editSkill(context, null),
                ),
              ),
              toolbarHeight: 64,
              centerTitle: true,
              backgroundColor: theme.scaffoldBackgroundColor,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              scrolledUnderElevation: 0,
              clipBehavior: Clip.none,
              title: const Text(
                '技能',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
              ),
              actions: [
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: _FrostedImportButton(
                    onPressed: () => _importSkill(context),
                  ),
                ),
              ],
            ),
            body: shiyi.skills.isEmpty
                ? _EmptySkills(onCreate: () => _editSkill(context, null))
                : ListView(
                    padding: const EdgeInsets.only(top: 4, bottom: 20),
                    children: [
                      CupertinoListSection.insetGrouped(
                        margin: iosSectionMargin,
                        decoration: iosSectionDecoration(context),
                        children: [
                          for (final s in shiyi.skills)
                            _SkillTile(
                              skill: s,
                              onTap: () => _view(context, s),
                              onMore: () => _showSkillActions(context, s),
                            ),
                        ],
                      ),
                    ],
                  ),
          );
        },
      ),
    );
  }

  // ---------------- 导入 ----------------

  Future<void> _importSkill(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
      withData: false,
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) {
      messenger.showSnackBar(const SnackBar(content: Text('读取文件失败')));
      return;
    }
    final docs = await getApplicationDocumentsDirectory();
    final destDir =
        '${docs.path}/skills_import_${DateTime.now().millisecondsSinceEpoch}';
    final SkillPack pack;
    try {
      pack = await SkillPackIO.importZip(zipPath: path, destDir: destDir);
    } catch (e) {
      try {
        final dir = Directory(destDir);
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      } catch (_) {}
      if (context.mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              '导入失败：${e.toString().replaceFirst('FormatException: ', '')}',
            ),
          ),
        );
      }
      return;
    }
    if (!context.mounted) return;
    Skill? existing;
    for (final x in shiyi.skills) {
      if (x.name == pack.name) {
        existing = x;
        break;
      }
    }
    final replace = await showIosFadeDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text(existing == null ? '导入技能' : '技能已存在'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '名称：${pack.name}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (pack.description.isNotEmpty) ...[
                const Text('描述', style: TextStyle(fontWeight: FontWeight.w600)),
                MarkdownInlineText(pack.description),
              ],
              Text(
                '正文 ${pack.content.length} 字符 · 文本辅助文件 ${pack.files.length} 个'
                '${pack.largeFiles.isEmpty ? '' : ' · 大文件 ${pack.largeFiles.length} 个（${_fmtBytes(_totalLarge(pack))}）'}',
              ),
              const SizedBox(height: 8),
              Text(
                pack.content.length > 120
                    ? '${pack.content.substring(0, 120)}…'
                    : pack.content,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(existing == null ? '导入' : '覆盖'),
          ),
        ],
      ),
    );
    if (replace != true) return;
    try {
      await shiyi.saveSkill(
        Skill(
          id: existing?.id ?? 0,
          name: pack.name,
          description: pack.description,
          content: pack.content,
          files: pack.files,
          largeFiles: pack.largeFiles,
          dirPath: pack.dirPath,
          createdAt:
              existing?.createdAt ?? DateTime.now().millisecondsSinceEpoch,
        ),
      );
      if (context.mounted) {
        messenger.showSnackBar(SnackBar(content: Text('技能「${pack.name}」导入成功')));
      }
    } catch (e) {
      if (context.mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              '导入失败：${e.toString().replaceFirst('Exception: ', '')}',
            ),
          ),
        );
      }
    }
  }

  static int _totalLarge(SkillPack p) {
    var total = 0;
    for (final v in p.largeFiles.values) {
      total += v;
    }
    return total;
  }

  // ---------------- 导出 ----------------

  Future<void> _exportSkill(BuildContext context, Skill s) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final safeName = s.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final dir = await _exportDir();
      final zipPath = '$dir/拾忆技能_$safeName.zip';
      await SkillPackIO.exportZip(skill: s, zipPath: zipPath);
      if (context.mounted) {
        messenger.showSnackBar(SnackBar(content: Text('已导出到 $zipPath')));
      }
    } catch (e) {
      if (context.mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              '导出失败：${e.toString().replaceFirst('Exception: ', '')}',
            ),
          ),
        );
      }
    }
  }

  Future<String> _exportDir() async {
    final ext = Directory('/storage/emulated/0/Download');
    try {
      if (await ext.exists()) return ext.path;
    } catch (_) {}
    final doc = await getApplicationDocumentsDirectory();
    return doc.path;
  }

  // ---------------- 操作菜单 ----------------

  Future<void> _showSkillActions(BuildContext context, Skill s) async {
    FocusScope.of(context).unfocus();
    final picked = await showIosFadeModalPopup<String>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, 'edit'),
            child: const Text('编辑'),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, 'copy'),
            child: const Text('复制内容'),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, 'export'),
            child: const Text('导出为 zip'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
      ),
    );
    if (!context.mounted || picked == null) return;
    if (picked == 'edit') {
      _editSkill(context, s);
    } else if (picked == 'copy') {
      _copy(context, s);
    } else if (picked == 'export') {
      await _exportSkill(context, s);
    }
  }

  // ---------------- 查看 ----------------

  void _view(BuildContext context, Skill s) {
    final items = <Widget>[];
    if (s.description.isNotEmpty) {
      items.add(
        const Text('描述', style: TextStyle(fontWeight: FontWeight.w600)),
      );
      items.add(MarkdownText(s.description));
      items.add(const Divider());
    }
    items.add(
      Text(
        s.content.isEmpty ? '（技能内容为空）' : '【SKILL.md】',
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
    );
    if (s.content.isNotEmpty) {
      for (final b in splitMarkdownBlocks(s.content)) {
        items.add(
          MarkdownBlock(b, style: const TextStyle(fontSize: 14, height: 1.5)),
        );
      }
    }
    if (s.files.isNotEmpty) {
      items.add(const Divider());
      items.add(
        Text(
          '辅助文件（${s.files.length}）',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      );
      for (final e in s.files.entries) {
        items.add(
          ExpansionTile(
            title: Text(
              e.key,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: SelectableText(
                  e.value,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ],
          ),
        );
      }
    }
    if (s.largeFiles.isNotEmpty) {
      items.add(const Divider());
      items.add(
        Text(
          '大文件（${s.largeFiles.length}，内容在磁盘）',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      );
      for (final e in s.largeFiles.entries) {
        items.add(
          CupertinoListTile(
            leading: const Icon(CupertinoIcons.doc, size: 18),
            title: Text(
              e.key,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            subtitle: Text(
              _fmtBytes(e.value),
              style: const TextStyle(fontSize: 11),
            ),
          ),
        );
      }
    }
    showIosFadeDialog<void>(
      context: context,
      builder: (ctx) {
        final size = MediaQuery.of(ctx).size;
        return CupertinoAlertDialog(
          title: Text(s.name),
          content: SizedBox(
            width: size.width * 0.9 > 460 ? 460 : size.width * 0.9,
            height: (size.height * 0.56).clamp(240.0, 440.0).toDouble(),
            child: Material(
              type: MaterialType.transparency,
              child: ListView.builder(
                padding: const EdgeInsets.only(right: 4),
                itemCount: items.length,
                itemBuilder: (context, i) => items[i],
              ),
            ),
          ),
          actions: [
            CupertinoDialogAction(
              isDestructiveAction: true,
              onPressed: () {
                Navigator.pop(ctx);
                _deleteConfirm(context, s);
              },
              child: const Text('删除'),
            ),
            CupertinoDialogAction(
              onPressed: () async {
                Navigator.pop(ctx);
                await _exportSkill(context, s);
              },
              child: const Text('导出'),
            ),
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  // ---------------- 删除 / 复制 ----------------

  Future<void> _deleteConfirm(BuildContext context, Skill s) async {
    final ok = await showIosFadeDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('删除技能'),
        content: Text(
          '确定删除技能「${s.name}」吗？${s.dirPath.isEmpty ? '' : '（含磁盘文件）'}',
        ),
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
    );
    if (ok == true) await shiyi.deleteSkill(s.id);
  }

  void _copy(BuildContext context, Skill s) {
    final sb = StringBuffer();
    sb.writeln('# ${s.name}');
    if (s.description.isNotEmpty) sb.writeln('\n${s.description}');
    sb.writeln('\n${s.content}');
    for (final e in s.files.entries) {
      sb.writeln('\n--- ${e.key} ---\n${e.value}');
    }
    if (s.largeFiles.isNotEmpty) {
      sb.writeln('\n【大文件】');
      for (final e in s.largeFiles.entries) {
        sb.writeln('- ${e.key} (${_fmtBytes(e.value)})');
      }
    }
    Clipboard.setData(ClipboardData(text: sb.toString()));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('内容已复制')));
  }

  // ---------------- 新建 / 编辑 ----------------

  void _editSkill(BuildContext context, Skill? s) {
    final nameCtrl = TextEditingController(text: s?.name ?? '');
    final descCtrl = TextEditingController(text: s?.description ?? '');
    final contentCtrl = TextEditingController(text: s?.content ?? '');
    var files = Map<String, String>.from(s?.files ?? const {});
    final largeFiles = Map<String, int>.from(s?.largeFiles ?? const {});

    showIosFadeDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => CupertinoAlertDialog(
          title: Text(s == null ? '新建技能' : '编辑技能'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CupertinoTextField(
                  controller: nameCtrl,
                  placeholder: '技能名称，例如：写周报',
                  padding: const EdgeInsets.all(10),
                ),
                const SizedBox(height: 8),
                CupertinoTextField(
                  controller: descCtrl,
                  placeholder: '描述（可选）',
                  maxLines: 2,
                  padding: const EdgeInsets.all(10),
                ),
                const SizedBox(height: 8),
                CupertinoTextField(
                  controller: contentCtrl,
                  placeholder: '技能内容（SKILL.md / Prompt / 流程）',
                  maxLines: 8,
                  padding: const EdgeInsets.all(10),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(CupertinoIcons.folder, size: 16),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '辅助文件 ${files.length} 个${largeFiles.isEmpty ? '' : ' · 大文件 ${largeFiles.length} 个'}',
                        style: Theme.of(ctx).textTheme.bodySmall,
                      ),
                    ),
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      onPressed: () async {
                        final updated = await _manageFiles(ctx, files);
                        if (updated != null) {
                          setState(() => files = updated);
                        }
                      },
                      child: const Text('管理'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () async {
                final v = nameCtrl.text.trim();
                if (v.isEmpty) return;
                try {
                  await shiyi.saveSkill(
                    Skill(
                      id: s?.id ?? 0,
                      name: v,
                      description: descCtrl.text.trim(),
                      content: contentCtrl.text.trim(),
                      files: files,
                      largeFiles: largeFiles,
                      dirPath: s?.dirPath ?? '',
                      createdAt:
                          s?.createdAt ?? DateTime.now().millisecondsSinceEpoch,
                    ),
                  );
                  if (ctx.mounted) Navigator.pop(ctx);
                } catch (e) {
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(
                        content: Text(
                          '保存失败：${e.toString().replaceFirst('Exception: ', '')}',
                        ),
                      ),
                    );
                  }
                }
              },
              child: Text(s == null ? '创建' : '保存'),
            ),
          ],
        ),
      ),
    );
  }

  Future<Map<String, String>?> _manageFiles(
    BuildContext ctx,
    Map<String, String> files,
  ) async {
    return showIosFadeDialog<Map<String, String>>(
      context: ctx,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (dialogCtx, setState) {
          final entries = files.entries.toList();
          return CupertinoAlertDialog(
            title: const Text('管理辅助文件'),
            content: SizedBox(
              width: 420,
              child: entries.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Text('还没有辅助文件'),
                    )
                  : ListView(
                      shrinkWrap: true,
                      children: entries
                          .map(
                            (e) => CupertinoListTile(
                              title: Text(
                                e.key,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 13,
                                ),
                              ),
                              subtitle: Text(
                                '${e.value.length} 字符',
                                style: const TextStyle(fontSize: 11),
                              ),
                              trailing: CupertinoButton(
                                padding: EdgeInsets.zero,
                                onPressed: () {
                                  setState(() => files.remove(e.key));
                                },
                                child: const Icon(
                                  CupertinoIcons.trash,
                                  color: CupertinoColors.systemRed,
                                  size: 18,
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
            ),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(dialogCtx, files),
                child: const Text('完成'),
              ),
              CupertinoDialogAction(
                onPressed: () async {
                  final added = await _addFileDialog(dialogCtx);
                  if (added != null) {
                    setState(() => files[added.$1] = added.$2);
                  }
                },
                child: const Text('添加文件'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<(String, String)?> _addFileDialog(BuildContext ctx) async {
    final pathCtrl = TextEditingController();
    final contentCtrl = TextEditingController();
    return showIosFadeDialog<(String, String)>(
      context: ctx,
      builder: (dialogCtx) => CupertinoAlertDialog(
        title: const Text('添加辅助文件'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CupertinoTextField(
              controller: pathCtrl,
              placeholder: '文件路径，例如 references/示例.md',
              padding: const EdgeInsets.all(10),
            ),
            const SizedBox(height: 8),
            CupertinoTextField(
              controller: contentCtrl,
              placeholder: '文件内容',
              maxLines: 6,
              padding: const EdgeInsets.all(10),
            ),
          ],
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () {
              final p = pathCtrl.text.trim();
              if (p.isEmpty) return;
              Navigator.pop(dialogCtx, (p, contentCtrl.text.trim()));
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  static String _fmtBytes(int n) {
    if (n >= 1024 * 1024 * 1024) {
      return '${(n / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (n >= 1024 * 1024) return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
    if (n >= 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '$n B';
  }
}

class _SkillTile extends StatelessWidget {
  final Skill skill;
  final VoidCallback onTap;
  final VoidCallback onMore;
  const _SkillTile({
    required this.skill,
    required this.onTap,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    return CupertinoListTile(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 8, 8),
      leadingSize: 30,
      leadingToTitle: 10,
      leading: Container(
        width: 31,
        height: 31,
        decoration: BoxDecoration(
          color: const Color(0xFFAF52DE),
          borderRadius: BorderRadius.circular(7),
        ),
        child: const Icon(
          CupertinoIcons.rocket_fill,
          size: 17,
          color: CupertinoColors.white,
        ),
      ),
      title: Text(
        skill.name,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          skill.description.isEmpty
              ? const Text('（无描述）')
              : MarkdownInlineText(
                  skill.description,
                  style: const TextStyle(fontSize: 12, height: 1.3),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
          Text(
            '${skill.content.isEmpty ? '0' : '1'} 个文档${skill.files.isEmpty ? '' : ' · ${skill.files.length} 个辅助文件'}${skill.largeFiles.isEmpty ? '' : ' · ${skill.largeFiles.length} 个大文件'}',
            style: const TextStyle(fontSize: 11, height: 1.2),
          ),
        ],
      ),
      trailing: CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: onMore,
        child: const Icon(CupertinoIcons.ellipsis),
      ),
      onTap: onTap,
    );
  }
}

class _EmptySkills extends StatelessWidget {
  final VoidCallback onCreate;
  const _EmptySkills({required this.onCreate});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            CupertinoIcons.rocket,
            size: 56,
            color: CupertinoColors.systemGrey3,
          ),
          const SizedBox(height: 12),
          Text(
            '还没有技能',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.label,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '点左上角红绿灯新建，或右上角导入 zip',
            style: const TextStyle(color: CupertinoColors.secondaryLabel),
          ),
          const SizedBox(height: 18),
          CupertinoButton.filled(
            onPressed: onCreate,
            child: const Text('新建技能'),
          ),
        ],
      ),
    );
  }
}

/// macOS Sonoma 风格磨砂玻璃导入胶囊：
/// 与主页右上角设置按钮同款 UI（60x26 圆角胶囊、半透明模糊、单色灰度），
/// 内容为下载图标，作为技能包导入入口。
class _FrostedImportButton extends StatelessWidget {
  final VoidCallback onPressed;
  const _FrostedImportButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final fg = dark
        ? Colors.white.withValues(alpha: 0.85)
        : Colors.black.withValues(alpha: 0.62);
    return Tooltip(
      message: '导入技能包',
      child: GestureDetector(
        onTap: onPressed,
        child: Container(
          width: 60,
          height: 26,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(13),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: dark ? 0.35 : 0.16),
                blurRadius: 12,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(13),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: Container(
                color: Colors.white.withValues(alpha: dark ? 0.10 : 0.40),
                alignment: Alignment.center,
                child: Icon(Icons.file_download_outlined, size: 13, color: fg),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
