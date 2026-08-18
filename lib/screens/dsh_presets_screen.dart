import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../services/dsh_api.dart';
import '../widgets/ios_style.dart';
import '../widgets/mac_action_button.dart';

/// Agent 预设管理页（Apple HIG Inset Grouped）。
///
/// 选择语义与官方一致：点预设行 = 设为「后续新建会话」的默认预设
/// （`settings.update` 写 `agent-presets.default`）；会话创建后预设锁定，
/// 页面只做只读展示，不调用 `agentPreset.select` 去切换已开始会话。
/// 其余操作：查看 / 复制为自建 / 删除自建。
class DshPresetsScreen extends StatefulWidget {
  final String? sessionId;
  const DshPresetsScreen({super.key, this.sessionId});

  @override
  State<DshPresetsScreen> createState() => _DshPresetsScreenState();
}

class _DshPresetsScreenState extends State<DshPresetsScreen> {
  List<DshPresetInfo> _presets = [];
  bool _authorable = false;
  bool _writable = true;
  String? _sessionPreset;
  bool? _sessionBlank;
  bool _loading = true;
  String? _error;
  bool _busy = false;

  DshApiClient get _api => DshApiClient.instance;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final r = await _api.listPresets();
      var writable = true;
      try {
        final s = await _api.describeSettings();
        writable = s.writable;
      } catch (_) {
        // 描述失败不阻断列表；写默认时仍由宿主拒绝并提示。
      }
      String? sessionPreset;
      bool? sessionBlank;
      final sid = widget.sessionId;
      if (sid != null && sid.isNotEmpty) {
        try {
          final sessions = await _api.listSessions();
          final me = sessions.where((s) => s.sessionId == sid).firstOrNull;
          sessionPreset = me?.agentPreset;
          sessionBlank = me?.blank;
        } catch (_) {
          // 会话信息可选，拉不到时只显示预设目录。
        }
      }
      if (!mounted) return;
      setState(() {
        _presets = r.presets;
        _authorable = r.authorable;
        _writable = writable;
        _sessionPreset = sessionPreset;
        _sessionBlank = sessionBlank;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      if (silent) {
        _toast('刷新失败：$e');
        return;
      }
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _setDefault(DshPresetInfo p) async {
    if (_busy || p.broken != null || !_writable) return;
    if (p.isDefault) {
      _toast('「${p.name ?? p.id}」已是默认预设');
      return;
    }
    setState(() => _busy = true);
    try {
      await _api.setDefaultPreset(p.id);
      if (!mounted) return;
      _toast('已设为默认：${p.name ?? p.id}');
      await _load(silent: true);
    } catch (e) {
      if (!mounted) return;
      _toast('设置失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _view(DshPresetInfo p) async {
    if (p.broken != null) return;
    try {
      final r = await _api.readPreset(p.id);
      if (!mounted) return;
      showIosFadeDialog<void>(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: Text('查看 · ${p.name ?? p.id}'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (p.description != null && p.description!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      p.description!,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                Text(
                  '信任：${r.trust == 'system' ? '系统' : '用户'}',
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 260),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      r.content,
                      style: const TextStyle(
                        fontSize: 10,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } catch (e) {
      _toast('读取失败：$e');
    }
  }

  Future<void> _copy(DshPresetInfo p) async {
    if (p.broken != null) return;
    final idCtrl = TextEditingController(text: '${p.id}-copy');
    final nameCtrl = TextEditingController(text: '${p.id}-copy');
    final id = await showIosFadeDialog<String>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text('复制预设 · 复制自 ${p.name ?? p.id}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('标识符', style: TextStyle(fontSize: 13)),
            ),
            const SizedBox(height: 4),
            CupertinoTextField(
              controller: idCtrl,
              placeholder: 'my-agent',
              autofocus: true,
            ),
            const SizedBox(height: 12),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('显示名称（可选）', style: TextStyle(fontSize: 13)),
            ),
            const SizedBox(height: 4),
            CupertinoTextField(
              controller: nameCtrl,
              placeholder: '选择器中显示的名字，缺省用标识符',
            ),
          ],
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(ctx, idCtrl.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (id == null ||
        id.isEmpty ||
        !RegExp(r'^[a-z0-9][a-z0-9-]*$').hasMatch(id)) {
      _toast('ID 需为小写字母/数字/连字符');
      return;
    }
    try {
      await _api.copyPreset(p.id, id, name: nameCtrl.text.trim());
      if (!mounted) return;
      _toast(
        '已复制为「${nameCtrl.text.trim().isEmpty ? id : nameCtrl.text.trim()}」',
      );
      await _load(silent: true);
    } catch (e) {
      _toast('复制失败：$e');
    }
  }

  Future<void> _remove(DshPresetInfo p) async {
    if (p.trust != 'user') {
      _toast('系统预设不可删除');
      return;
    }
    final ok = await showIosFadeDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('删除预设'),
        content: Text('确定删除「${p.name ?? p.id}」吗？'),
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
    if (ok != true) return;
    try {
      await _api.removePreset(p.id);
      if (!mounted) return;
      _toast('已删除');
      await _load(silent: true);
    } catch (e) {
      _toast('删除失败：$e');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _pop() {
    if (Navigator.canPop(context)) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CupertinoTheme(
      data: iosCupertinoTheme(context),
      child: Scaffold(
        backgroundColor: iosGroupedBackground(context),
        appBar: AppBar(
          leadingWidth: 72,
          leading: Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: MacActionButton(
                icon: CupertinoIcons.chevron_left,
                tooltip: '返回',
                onTap: _pop,
              ),
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
            'Agent 预设',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: MacActionButton(
                icon: CupertinoIcons.refresh,
                tooltip: '刷新',
                onTap: _busy ? null : _load,
              ),
            ),
          ],
        ),
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            CupertinoButton.filled(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_presets.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              CupertinoIcons.person_crop_circle_badge_xmark,
              size: 48,
              color: CupertinoColors.systemGrey,
            ),
            const SizedBox(height: 12),
            const Text('暂无预设'),
          ],
        ),
      );
    }
    final system = _presets
        .where((p) => p.trust == 'system')
        .toList(growable: false);
    final user = _presets
        .where((p) => p.trust == 'user')
        .toList(growable: false);
    return ListView(
      padding: const EdgeInsets.only(top: 4, bottom: 24),
      children: [
        if (widget.sessionId != null && widget.sessionId!.isNotEmpty)
          CupertinoListSection.insetGrouped(
            header: const Text('当前会话'),
            margin: iosSectionMargin,
            decoration: iosSectionDecoration(context),
            children: [
              CupertinoListTile(
                leading: const _PresetIcon(
                  CupertinoIcons.rectangle_stack_person_crop,
                  CupertinoColors.systemIndigo,
                ),
                title: const Text('会话预设'),
                subtitle: Text(
                  _sessionPreset == null || _sessionPreset!.isEmpty
                      ? '未知'
                      : '${_sessionPreset!}'
                            '${_sessionBlank == true ? ' · 空白会话' : ' · 已锁定'}',
                ),
                trailing: _sessionBlank == true
                    ? const Icon(
                        CupertinoIcons.info_circle,
                        size: 18,
                        color: CupertinoColors.systemBlue,
                      )
                    : const Icon(
                        CupertinoIcons.lock_fill,
                        size: 17,
                        color: CupertinoColors.secondaryLabel,
                      ),
              ),
            ],
          ),
        CupertinoListSection.insetGrouped(
          header: const Text('系统预设'),
          margin: iosSectionMargin,
          decoration: iosSectionDecoration(context),
          children: [for (final p in system) _presetTile(p)],
        ),
        if (user.isNotEmpty)
          CupertinoListSection.insetGrouped(
            header: const Text('自定义'),
            margin: iosSectionMargin,
            decoration: iosSectionDecoration(context),
            children: [for (final p in user) _presetTile(p)],
          ),
      ],
    );
  }

  Widget _presetTile(DshPresetInfo p) {
    final broken = p.broken != null && p.broken!.isNotEmpty;
    final isDefault = p.isDefault;
    final subtitle = <Widget>[];
    if (broken) {
      subtitle.add(
        Text(
          '加载失败：${p.broken}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 12,
            color: CupertinoColors.systemRed,
          ),
        ),
      );
      subtitle.add(
        const Text(
          '不可选择',
          style: TextStyle(fontSize: 12, color: CupertinoColors.systemRed),
        ),
      );
    } else {
      if (p.description != null && p.description!.isNotEmpty) {
        subtitle.add(Text(p.description!));
      }
      subtitle.add(
        Text(
          '${p.trust == 'system' ? '系统预设' : '用户预设'}'
          '${isDefault ? ' · 默认' : ''}',
          style: const TextStyle(fontSize: 12),
        ),
      );
    }
    return CupertinoListTile(
      key: ValueKey(p.id),
      leading: broken
          ? const _PresetIcon(
              CupertinoIcons.exclamationmark_triangle_fill,
              CupertinoColors.systemRed,
            )
          : _PresetIcon(
              p.trust == 'system'
                  ? CupertinoIcons.shield_lefthalf_fill
                  : CupertinoIcons.person_crop_circle_fill,
              p.trust == 'system'
                  ? CupertinoColors.systemBlue
                  : CupertinoColors.systemGreen,
            ),
      title: Text(
        p.name ?? p.id,
        style: broken
            ? const TextStyle(color: CupertinoColors.systemRed)
            : null,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: subtitle,
      ),
      trailing: SizedBox(
        width: 72,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (isDefault && !broken)
              const Icon(
                CupertinoIcons.checkmark_circle_fill,
                color: CupertinoColors.activeBlue,
                size: 20,
              ),
            if (_hasActions(p)) ...[
              const SizedBox(width: 6),
              CupertinoButton(
                minimumSize: const Size(32, 32),
                padding: EdgeInsets.zero,
                onPressed: _busy ? null : () => _presetActions(p),
                child: const Icon(CupertinoIcons.ellipsis, size: 20),
              ),
            ],
          ],
        ),
      ),
      onTap: broken || _busy || !_writable ? null : () => _setDefault(p),
    );
  }

  bool _hasActions(DshPresetInfo p) {
    if (p.broken != null && p.broken!.isNotEmpty) return p.trust == 'user';
    return true;
  }

  void _presetActions(DshPresetInfo p) {
    final broken = p.broken != null && p.broken!.isNotEmpty;
    showIosFadeModalPopup<void>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text(p.name ?? p.id),
        message: Text(
          broken
              ? '预设损坏，不能装载'
              : '${p.trust == 'system' ? '系统预设' : '用户预设'}'
                    '${p.isDefault ? ' · 当前默认' : ''}',
        ),
        actions: [
          if (!broken)
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.pop(ctx);
                _view(p);
              },
              child: const Text('查看内容'),
            ),
          if (!broken && _writable && !p.isDefault)
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.pop(ctx);
                _setDefault(p);
              },
              child: const Text('设为默认'),
            ),
          if (!broken && _authorable)
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.pop(ctx);
                _copy(p);
              },
              child: const Text('复制为新预设'),
            ),
          if (p.trust == 'user')
            CupertinoActionSheetAction(
              isDestructiveAction: true,
              onPressed: () {
                Navigator.pop(ctx);
                _remove(p);
              },
              child: const Text('删除'),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
      ),
    );
  }
}

class _PresetIcon extends StatelessWidget {
  final IconData icon;
  final Color color;
  const _PresetIcon(this.icon, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Icon(icon, size: 17, color: CupertinoColors.white),
    );
  }
}
