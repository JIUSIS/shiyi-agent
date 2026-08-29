import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../services/dsh_endpoint.dart';
import '../services/dsh_plugin_store.dart';
import '../services/dsh_service.dart';
import '../widgets/context_menu.dart';
import '../widgets/ios_style.dart';
import '../widgets/mac_action_button.dart';
import '../widgets/traffic_lights_button.dart';

const _pluginTeal = Color(0xFF30B0C7);
const _pluginPurple = Color(0xFFAF52DE);
const _pluginOrange = Color(0xFFFF9F0A);

/// DS Harness 插件管理页：列出当前 DSH（web profile）已装载的插件——
/// 内置 bundle 与用户/LLM 通过补丁层新增的插件，统一启停 / 删除 / 改配置。
///
/// 本机连接：读写 `~/.dsh/profiles/web/cordis.patch.yml`（DshPluginStore），
/// 不动 DSH npm 安装目录，DSH 对补丁层热重载生效。
/// 局域网 / 公网连接：改走 `pluginInventory/list` 实时清单（只读），
/// 不读本机补丁文件——远端补丁只能登目标服务器修改。
class DshPluginsScreen extends StatefulWidget {
  final DshPluginStore? store;
  final ShiyiState? shiyi;
  const DshPluginsScreen({super.key, this.store, this.shiyi});

  @override
  State<DshPluginsScreen> createState() => _DshPluginsScreenState();
}

class _DshPluginsScreenState extends State<DshPluginsScreen> {
  late DshPluginStore _store =
      widget.store ?? DshPluginStore(''); // homeDir 由 _load 重取
  List<DshPluginEntry> _items = [];
  bool _loading = true;
  String? _error;
  bool _busy = false;
  bool _remote = false;

  bool get _remoteMode =>
      widget.shiyi != null && !DshEndpoint.isLocal(widget.shiyi!.settings);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (_remoteMode) {
        // 局域网 / 公网：实时清单来自目标 DSH，不读本机文件。
        final api = DshService.instance.apiFor(widget.shiyi!.settings);
        final entries = await api.pluginInventoryList();
        if (!mounted) return;
        setState(() {
          _remote = true;
          _items = [
            for (final e in entries)
              DshPluginEntry(
                id: e.entryId.isEmpty ? e.moduleName : e.entryId,
                name: e.moduleName,
                disabled: !e.enabled,
                source: 'remote',
              ),
          ];
          _loading = false;
        });
        return;
      }
      // 未显式注入 store 时，按 DSH home 实际路径解析。
      final store = widget.store != null && widget.store!.homeDir.isNotEmpty
          ? widget.store!
          : await DshPluginStore.fromHome();
      final items = await store.list();
      if (!mounted) return;
      setState(() {
        _remote = false;
        _store = store;
        _items = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _refresh() async {
    await _load();
  }

  void _readOnlyHint() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('远端插件为实时清单（只读）；启停 / 删除 / 配置需在目标服务器的 cordis.patch.yml 修改'),
      ),
    );
  }

  Future<void> _toggleDisabled(DshPluginEntry entry, bool disabled) async {
    if (_remote) {
      _readOnlyHint();
      return;
    }
    if (_busy) return;
    if (entry.builtin) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('内置组合由 DSH 安装包管理，不支持单独启停')));
      return;
    }
    setState(() => _busy = true);
    try {
      await _store.setDisabled(entry.id, disabled);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(disabled ? '已停用 ${entry.id}' : '已启用 ${entry.id}'),
        ),
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('操作失败：$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(DshPluginEntry entry) async {
    if (_remote) {
      _readOnlyHint();
      return;
    }
    if (entry.builtin) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('内置 bundle 不可删除，可停用或改配置')));
      return;
    }
    final ok = await showIosFadeDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('删除插件'),
        content: Text(
          '确定删除插件「${entry.id}」吗？\n'
          '这将从命令清单中移除该条目。',
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
    if (ok != true || !mounted) return;
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _store.remove(entry.id);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已删除 ${entry.id}')));
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('删除失败：$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editConfig(DshPluginEntry entry) async {
    if (_remote) {
      _readOnlyHint();
      return;
    }
    final result = await showIosFadeDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController(
          text: _configToEditableText(entry.config),
        );
        return AlertDialog(
          title: Text('编辑配置 · ${entry.id}'),
          content: SingleChildScrollView(
            child: TextField(
              controller: controller,
              maxLines: 14,
              minLines: 6,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(
                labelText: 'YAML 配置',
                hintText: '例如：\napiKeyEnv: BING_SEARCH_API_KEY\nprefer: auto',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, {'text': controller.text}),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
    if (result == null || !mounted) return;
    final raw = (result['text'] as String?)?.trim() ?? '';
    final Map<String, dynamic> config;
    try {
      config = _parseConfigText(raw);
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('配置解析失败：$e')));
      return;
    }
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _store.updateConfig(entry.id, config);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已更新 ${entry.id} 配置')));
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('保存配置失败：$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 把配置 Map 序列化为可编辑的多行文本（简单 YAML）。
  static String _configToEditableText(Map<String, dynamic> config) {
    if (config.isEmpty) return '';
    final buf = StringBuffer();
    void emit(Map<String, dynamic> map, int indent) {
      for (final entry in map.entries) {
        final pad = ' ' * indent;
        final value = entry.value;
        if (value is Map) {
          final sub = Map<String, dynamic>.from(value);
          buf.writeln('$pad${entry.key}:');
          emit(sub, indent + 2);
        } else if (value is List) {
          buf.writeln('$pad${entry.key}:');
          for (final item in value) {
            buf.writeln('${' ' * (indent + 2)}- ${_scalar(item)}');
          }
        } else {
          buf.writeln('$pad${entry.key}: ${_scalar(value)}');
        }
      }
    }

    emit(config, 0);
    return buf.toString().trimRight();
  }

  static String _scalar(dynamic value) {
    if (value is bool) return value ? 'true' : 'false';
    if (value is num) return value.toString();
    final s = value.toString();
    if (RegExp(r'^[A-Za-z0-9_./:@-]+$').hasMatch(s)) return s;
    return '"${s.replaceAll('"', r'\"')}"';
  }

  /// 把用户输入的多行文本解析为配置 Map（简单 YAML 子集）。
  static Map<String, dynamic> _parseConfigText(String text) {
    final result = <String, dynamic>{};
    if (text.trim().isEmpty) return result;
    final lines = text.split(RegExp(r'\r?\n'));
    final stack = <Map<String, dynamic>>[result];
    final indents = <int>[0];
    for (final raw in lines) {
      final line = raw.trimRight();
      if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
      final indent = line.length - line.trimLeft().length;
      // 弹出比当前缩进深的层级。
      final trimmed = line.trimLeft();
      while (indents.length > 1 && indent <= indents.last) {
        indents.removeLast();
        stack.removeLast();
      }
      // 列表项
      if (trimmed.startsWith('- ')) {
        final parent = stack.last;
        final key = 'list';
        final list = parent.putIfAbsent(key, () => <dynamic>[]) as List;
        list.add(_scalar(trimmed.substring(2).trim()));
        continue;
      }
      final idx = trimmed.indexOf(':');
      if (idx < 0) continue;
      final key = trimmed.substring(0, idx).trim();
      final value = trimmed.substring(idx + 1).trim();
      if (value.isEmpty) {
        final child = <String, dynamic>{};
        stack.last[key] = child;
        stack.add(child);
        indents.add(indent);
      } else if (value == '[]') {
        stack.last[key] = <dynamic>[];
      } else {
        stack.last[key] = _parseScalar(value);
      }
    }
    return result;
  }

  static dynamic _parseScalar(String s) {
    if (s == 'true') return true;
    if (s == 'false') return false;
    final num = int.tryParse(s) ?? double.tryParse(s);
    if (num != null) return num;
    var cleaned = s;
    if (cleaned.startsWith('"') &&
        cleaned.endsWith('"') &&
        cleaned.length >= 2) {
      cleaned = cleaned.substring(1, cleaned.length - 1);
    }
    return cleaned;
  }

  void _openMenu(DshPluginEntry entry, Offset globalPosition) {
    if (_remote) {
      _readOnlyHint();
      return;
    }
    if (entry.builtin) return;
    final items = <DesktopMenuItem>[
      DesktopMenuItem(
        label: entry.disabled ? '启用' : '停用',
        icon: entry.disabled
            ? CupertinoIcons.play_circle_fill
            : CupertinoIcons.pause_circle_fill,
        iconColor: _pluginTeal,
        onTap: () => _toggleDisabled(entry, !entry.disabled),
      ),
      DesktopMenuItem(
        label: '编辑配置',
        icon: CupertinoIcons.settings,
        iconColor: _pluginOrange,
        onTap: () => _editConfig(entry),
      ),
      DesktopMenuItem(
        label: '删除',
        icon: CupertinoIcons.delete,
        iconColor: CupertinoColors.systemRed,
        onTap: () => _delete(entry),
      ),
    ];
    showDesktopMenu(context, globalPosition: globalPosition, items: items);
  }

  void _pop() {
    if (Navigator.canPop(context)) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: iosGroupedBackground(context),
      appBar: AppBar(
        leadingWidth: 72,
        leading: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Platform.isWindows
                ? MacActionButton(
                    icon: CupertinoIcons.chevron_left,
                    tooltip: '返回',
                    onTap: _pop,
                  )
                : TrafficLightsButton(busy: false, tooltip: '返回', onTap: _pop),
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
          '插件',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Row(
              children: [
                MacActionButton(
                  icon: CupertinoIcons.refresh,
                  tooltip: '刷新',
                  onTap: _refresh,
                ),
                const SizedBox(width: 4),
                MacActionButton(
                  icon: CupertinoIcons.ellipsis,
                  tooltip: '关于',
                  onTap: () => _showAbout(),
                ),
              ],
            ),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  void _showAbout() {
    showIosFadeDialog<void>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('关于插件清单'),
        content: Text(
          _remote
              ? '当前连接的是局域网 / 公网 DSH：\n'
                    '本页展示目标服务器的实时插件清单'
                    '（pluginInventory，含装载相位），只读。\n'
                    '启停 / 删除 / 改配置需登录目标服务器修改 '
                    'cordis.patch.yml。'
              : '本页合并显示 DSH 的内置组合与持久插件：\n'
                    '· 内置组合：由安装包声明，只读展示；\n'
                    '· 持久插件：来自 profile / home 两层补丁，可启停、删除或改配置。\n\n'
                    '全局补丁：${_store.homePatchPath}\n'
                    'Profile 补丁：${_store.profilePatchPath}\n'
                    'DSH 对补丁层热重载，改动即时生效。',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                CupertinoIcons.exclamationmark_triangle,
                size: 40,
                color: CupertinoColors.systemRed,
              ),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 14),
              CupertinoButton.filled(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return const Center(child: Text('还没有可管理的插件'));
    }
    return ListView(
      padding: const EdgeInsets.only(top: 4, bottom: 24),
      children: [
        CupertinoListSection.insetGrouped(
          header: const Text('已装载插件与组合'),
          margin: iosSectionMargin,
          decoration: iosSectionDecoration(context),
          children: [
            for (final e in _items)
              _PluginTile(
                key: ValueKey('plugin-${e.id}'),
                entry: e,
                busy: _busy,
                onToggle: (v) => _toggleDisabled(e, v),
                onEdit: () => _editConfig(e),
                onDelete: () => _delete(e),
                onSecondary: (pos) => _openMenu(e, pos),
              ),
          ],
        ),
      ],
    );
  }
}

class _PluginTile extends StatelessWidget {
  final DshPluginEntry entry;
  final bool busy;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<Offset> onSecondary;
  const _PluginTile({
    super.key,
    required this.entry,
    required this.busy,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
    required this.onSecondary,
  });

  Color get _color {
    switch (entry.id.split('_').first) {
      case 'web':
        return _pluginTeal;
      case 'dsh':
        return _pluginPurple;
      default:
        return _pluginOrange;
    }
  }

  String get _subtitle {
    final parts = <String>[
      entry.name ?? entry.id,
      if (entry.builtin)
        '内置组合'
      else if (entry.source == 'remote')
        '远端实时清单'
      else if (entry.source == 'home')
        '全局补丁'
      else if (entry.source == 'profile')
        'Profile 补丁',
      if (entry.disabled) '已停用',
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      // Windows 桌面右键弹出操作菜单。
      onSecondaryTapDown: (d) => onSecondary(d.globalPosition),
      child: CupertinoListTile(
        leading: Opacity(
          opacity: busy ? 0.5 : 1,
          child: Container(
            width: 31,
            height: 31,
            decoration: BoxDecoration(
              color: _color,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Icon(
              entry.disabled
                  ? CupertinoIcons.slash_circle
                  : CupertinoIcons.chevron_left_slash_chevron_right,
              size: 17,
              color: CupertinoColors.white,
            ),
          ),
        ),
        title: Text(
          entry.id,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: entry.disabled ? TextStyle(color: theme.hintColor) : null,
        ),
        subtitle: Text(
          _subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: entry.disabled ? TextStyle(color: theme.hintColor) : null,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (entry.builtin)
              Icon(CupertinoIcons.lock_fill, size: 17, color: theme.hintColor)
            else
              CupertinoSwitch(
                value: !entry.disabled,
                onChanged: busy ? null : (v) => onToggle(!v),
              ),
          ],
        ),
        onTap: entry.builtin ? null : onEdit,
      ),
    );
  }
}
