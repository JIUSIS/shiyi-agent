import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../services/dsh_api.dart';
import '../services/dsh_service.dart';
import '../widgets/ios_style.dart';
import '../widgets/mac_action_button.dart';

/// DSH 凭据与配置页：凭据可更新/清除，命名空间逐项完整展示。
class DshSettingsScreen extends StatefulWidget {
  const DshSettingsScreen({super.key});

  @override
  State<DshSettingsScreen> createState() => _DshSettingsScreenState();
}

class _DshSettingsScreenState extends State<DshSettingsScreen> {
  bool _loading = true;
  bool _busy = false;
  String? _error;
  bool _writable = false;
  List<DshSettingsNamespace> _namespaces = [];
  List<DshCredentialSlot> _credentials = [];

  DshApiClient get _api => DshService.instance.api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool showLoading = true}) async {
    if (showLoading) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final settings = await _api.describeSettings();
      List<DshCredentialSlot> credentials = [];
      try {
        credentials = await _api.describeCredentials();
      } catch (_) {
        // 凭据域可选，配置仍可浏览。
      }
      if (!mounted) return;
      setState(() {
        _writable = settings.writable;
        _namespaces = settings.namespaces;
        _credentials = credentials;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      if (!showLoading) {
        _toast('刷新失败：$e');
        return;
      }
      setState(() {
        _loading = false;
        _error = '$e';
      });
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
          title: const Text(
            '凭据与配置',
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
    return ListView(
      padding: const EdgeInsets.only(top: 4, bottom: 28),
      children: [
        if (!_writable) _readOnlyBanner(),
        CupertinoListSection.insetGrouped(
          header: const Text('凭据'),
          margin: iosSectionMargin,
          decoration: iosSectionDecoration(context),
          children: _credentials.isEmpty
              ? const [CupertinoListTile(title: Text('暂无凭据槽位'))]
              : [
                  for (final credential in _credentials)
                    _credentialTile(credential),
                ],
        ),
        for (final namespace in _namespaces) _namespaceSection(namespace),
      ],
    );
  }

  Widget _readOnlyBanner() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 2),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: CupertinoColors.systemOrange.withValues(alpha: .14),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Row(
        children: [
          Icon(
            CupertinoIcons.lock_fill,
            size: 17,
            color: CupertinoColors.systemOrange,
          ),
          SizedBox(width: 8),
          Expanded(child: Text('当前 DSH 配置为只读')),
        ],
      ),
    );
  }

  Widget _credentialTile(DshCredentialSlot credential) {
    final color = credential.set
        ? CupertinoColors.systemGreen
        : CupertinoColors.systemOrange;
    return CupertinoListTile(
      key: ValueKey(credential.ref),
      leading: _SettingsIcon(
        icon: credential.set
            ? CupertinoIcons.lock_fill
            : CupertinoIcons.lock_open,
        color: color,
      ),
      title: Text(credential.label),
      subtitle: Text(
        credential.set ? '已安全保存' : '尚未设置',
        style: TextStyle(fontSize: 12, color: color),
      ),
      trailing: CupertinoButton(
        minimumSize: const Size(34, 34),
        padding: EdgeInsets.zero,
        onPressed: _busy || !_writable || !credential.writable
            ? null
            : () => _credentialActions(credential),
        child: const Icon(CupertinoIcons.ellipsis, size: 20),
      ),
      onTap: _busy || !_writable || !credential.writable
          ? null
          : () => _setCredential(credential),
    );
  }

  Widget _namespaceSection(DshSettingsNamespace namespace) {
    final entries = namespace.value.entries.toList();
    return CupertinoListSection.insetGrouped(
      header: Text(namespace.ns),
      margin: iosSectionMargin,
      decoration: iosSectionDecoration(context),
      children: entries.isEmpty
          ? const [CupertinoListTile(title: Text('空命名空间'))]
          : [
              for (final entry in entries)
                CupertinoListTile(
                  leading: const _SettingsIcon(
                    icon: CupertinoIcons.slider_horizontal_3,
                    color: CupertinoColors.systemIndigo,
                  ),
                  title: Text(entry.key),
                  subtitle: SelectableText(
                    _formatValue(entry.value),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
    );
  }

  static String _formatValue(Object? value) {
    if (value is Map || value is List) {
      return const JsonEncoder.withIndent('  ').convert(value);
    }
    return '$value';
  }

  void _credentialActions(DshCredentialSlot credential) {
    showIosFadeModalPopup<void>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text(credential.label),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(ctx);
              _setCredential(credential);
            },
            child: Text(credential.set ? '更新凭据' : '设置凭据'),
          ),
          if (credential.set)
            CupertinoActionSheetAction(
              isDestructiveAction: true,
              onPressed: () {
                Navigator.pop(ctx);
                _unsetCredential(credential);
              },
              child: const Text('清除凭据'),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
      ),
    );
  }

  Future<void> _setCredential(DshCredentialSlot credential) async {
    final ctrl = TextEditingController();
    var obscure = true;
    final value = await showIosFadeDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => CupertinoAlertDialog(
          title: Text(credential.set ? '更新凭据' : '设置凭据'),
          content: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: CupertinoTextField(
              controller: ctrl,
              obscureText: obscure,
              placeholder: credential.label,
              autofocus: true,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
              suffix: CupertinoButton(
                minimumSize: const Size(34, 34),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                onPressed: () => setDialogState(() => obscure = !obscure),
                child: Icon(
                  obscure ? CupertinoIcons.eye : CupertinoIcons.eye_slash,
                  size: 18,
                ),
              ),
            ),
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (value == null || value.isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      await _api.setCredential(credential.ref, value);
      await _load(showLoading: false);
      _toast('凭据已保存');
    } catch (e) {
      _toast('设置失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unsetCredential(DshCredentialSlot credential) async {
    final ok = await showIosFadeDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('清除凭据'),
        content: Text('确定清除「${credential.label}」吗？'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await _api.unsetCredential(credential.ref);
      await _load(showLoading: false);
      _toast('凭据已清除');
    } catch (e) {
      _toast('清除失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _SettingsIcon extends StatelessWidget {
  final IconData icon;
  final Color color;
  const _SettingsIcon({required this.icon, required this.color});

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
