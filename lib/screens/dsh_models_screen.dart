import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../services/dsh_api.dart';
import '../services/dsh_model_sync.dart';
import '../services/dsh_service.dart';
import '../widgets/ios_style.dart';
import '../widgets/mac_action_button.dart';

/// 已注入 API 配置页：只列出、删除注入到 DSH 的多份配置，不再勾选模型 ID。
class DshModelsScreen extends StatefulWidget {
  final String? sessionId;
  final ShiyiState? shiyi;
  const DshModelsScreen({super.key, this.sessionId, this.shiyi});

  @override
  State<DshModelsScreen> createState() => _DshModelsScreenState();
}

class _DshModelsScreenState extends State<DshModelsScreen> {
  List<DshInjectedConfig> _configs = [];
  bool _loading = true;
  String? _error;
  bool _deleting = false;

  DshApiClient get _api => DshService.instance.api;

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
      final scopeKey = DshService.instance.currentScopeKey;
      final stored = await DshModelSync.listInjectedConfigs(scopeKey: scopeKey);
      var configs = DshModelSync.configsForDisplay(
        stored: stored,
        settings: widget.shiyi?.settings,
      );
      if (configs.isEmpty) {
        try {
          final groups = widget.sessionId != null
              ? (await _api.sessionModels(widget.sessionId!)).groups
              : await _api.llmModels();
          configs = [
            for (final group in groups)
              if (DshModelSync.isManagedProviderId(group.id))
                DshInjectedConfig(
                  id: group.id,
                  name: group.name.trim().isEmpty
                      ? DshModelSync.displayName
                      : group.name.trim(),
                  baseUrl: '',
                  apiProtocol: 'openai',
                  model: group.models.isEmpty ? '' : group.models.first.id,
                  credentialEnv: DshModelSync.credentialEnvFor(group.id),
                ),
          ];
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _configs = configs;
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

  Future<void> _delete(DshInjectedConfig config) async {
    if (_deleting) return;
    final confirmed = await showIosConfirmDialog(
      context: context,
      title: '删除配置？',
      message: '从模型数据中删除「${config.name}」。会话选择不会再看到这份接口。',
      confirmLabel: '删除',
      isDestructiveAction: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _deleting = true);
    try {
      await DshModelSync.removeInjectedConfig(
        config.id,
        api: _api,
        scopeKey: DshService.instance.currentScopeKey,
      );
      if (!mounted) return;
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('删除失败：$e')));
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
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
        leadingWidth: 104,
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
          '模型数据',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: MacActionButton(
              icon: CupertinoIcons.refresh,
              tooltip: '刷新',
              onTap: _load,
            ),
          ),
        ],
      ),
      body: _buildBody(),
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
    if (_configs.isEmpty) {
      return const Center(child: Text('暂无已注入配置，请先在设置中保存并注入'));
    }
    return ListView(
      padding: const EdgeInsets.only(top: 4, bottom: 24),
      children: [
        CupertinoListSection.insetGrouped(
          header: const Text('已注入 API 配置'),
          margin: iosSectionMargin,
          decoration: iosSectionDecoration(context),
          children: [
            for (final config in _configs)
              CupertinoListTile(
                key: ValueKey(config.id),
                title: Text(
                  config.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  [
                    if (config.baseUrl.isNotEmpty) config.baseUrl,
                    if (config.model.isNotEmpty) config.model,
                  ].join('\n'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: CupertinoButton(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(32, 32),
                  onPressed: _deleting ? null : () => _delete(config),
                  child: const Icon(
                    CupertinoIcons.delete,
                    size: 18,
                    color: CupertinoColors.systemRed,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
