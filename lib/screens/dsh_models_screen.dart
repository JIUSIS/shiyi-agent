import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../services/dsh_api.dart';
import '../services/dsh_model_sync.dart';
import '../widgets/ios_style.dart';
import '../widgets/mac_action_button.dart';

/// 模型选择页（Apple HIG Inset Grouped）：
/// 当前会话模型 + 提供商分组目录。会话模式直接切换（session.selectModel），
/// 无会话时只读浏览全量目录（llm.models）。
class DshModelsScreen extends StatefulWidget {
  final String? sessionId;
  final ShiyiState? shiyi;
  const DshModelsScreen({super.key, this.sessionId, this.shiyi});

  @override
  State<DshModelsScreen> createState() => _DshModelsScreenState();
}

class _DshModelsScreenState extends State<DshModelsScreen> {
  List<DshModelGroup> _groups = [];
  DshModelSelection? _current;
  Set<String> _deletableModelIds = const {};
  bool _loading = true;
  String? _error;
  bool _selecting = false;

  DshApiClient get _api => DshApiClient.instance;

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
      final sid = widget.sessionId;
      List<DshModelGroup> groups;
      if (sid != null) {
        final r = await _api.sessionModels(sid);
        _current = r.current;
        groups = r.groups;
      } else {
        groups = await _api.llmModels();
      }
      final shiyi = widget.shiyi;
      var injected = groups
          .where((group) => group.id == DshModelSync.providerId)
          .toList();
      if (shiyi != null) {
        final cached = await DshModelSync.cachedModelCatalogFor(shiyi.settings);
        _deletableModelIds = cached.toSet();
        if (injected.isEmpty) {
          final models = await DshModelSync.modelCatalogFor(shiyi.settings);
          if (models.isNotEmpty) {
            final items = models.toList()..sort();
            injected = [
              DshModelGroup(
                id: DshModelSync.providerId,
                name: DshModelSync.displayName,
                models: [
                  for (final id in items)
                    DshModelInfo(
                      id: id,
                      name: id,
                      providerId: DshModelSync.providerId,
                      providerName: DshModelSync.displayName,
                    ),
                ],
              ),
            ];
          }
        }
        // “模型数据”是全局目录页，没有 session.models 可回读当前项；
        // 用拾忆设置里的模型恢复勾选，返回再进入时仍保持选择。
        if (sid == null && shiyi.settings.model.trim().isNotEmpty) {
          _current = DshModelSelection(
            provider: DshModelSync.providerId,
            model: shiyi.settings.model.trim(),
          );
        }
      }
      if (!mounted) return;
      setState(() {
        _groups = injected;
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

  Future<void> _select(DshModelInfo m) async {
    final sid = widget.sessionId;
    if (_selecting) return;
    setState(() => _selecting = true);
    try {
      DshModelSelection sel;
      if (sid != null) {
        sel = await _api.selectModel(sid, m.providerId, m.id);
      } else {
        final shiyi = widget.shiyi;
        if (shiyi == null) return;
        final next = shiyi.settings.copyWith(model: m.id);
        await shiyi.updateSettings(next);
        await DshModelSync.injectNow(next);
        sel = DshModelSelection(provider: m.providerId, model: m.id);
      }
      if (!mounted) return;
      setState(() => _current = sel);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已切换模型：${m.name}')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('切换失败：$e')));
    } finally {
      if (mounted) setState(() => _selecting = false);
    }
  }

  Future<void> _delete(DshModelInfo model) async {
    final shiyi = widget.shiyi;
    if (shiyi == null || !_deletableModelIds.contains(model.id)) return;
    if (model.id == shiyi.settings.model.trim() ||
        model.id == shiyi.settings.visionModel.trim()) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('当前使用中的模型不能删除，请先切换模型')));
      return;
    }
    final confirmed = await showIosFadeDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('删除模型'),
        content: Text('从模型数据中删除「${model.name}」？'),
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
    if (confirmed != true || !mounted) return;
    try {
      final removed = await DshModelSync.removeCachedModel(
        shiyi.settings,
        model.id,
        api: _api,
      );
      if (!mounted) return;
      if (!removed) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('该模型由当前配置或兼容规则提供，不能删除')));
        return;
      }
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('删除失败：$e')));
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
    if (_groups.isEmpty) {
      return const Center(child: Text('暂无已注入模型，请先在设置中获取或填写模型'));
    }
    return ListView(
      padding: const EdgeInsets.only(top: 4, bottom: 24),
      children: [
        if (_current != null)
          CupertinoListSection.insetGrouped(
            margin: iosSectionMargin,
            decoration: iosSectionDecoration(context),
            children: [
              CupertinoListTile(
                leading: const Icon(
                  CupertinoIcons.sparkles,
                  color: CupertinoColors.activeBlue,
                ),
                title: const Text('当前模型'),
                subtitle: Text(
                  '${_current!.provider} / ${_current!.model}'
                  '${_current!.reasoningEffort != null && _current!.reasoningEffort!.isNotEmpty ? ' · ${_current!.reasoningEffort}' : ''}',
                ),
              ),
            ],
          ),
        for (final g in _groups)
          CupertinoListSection.insetGrouped(
            header: Text(g.name),
            margin: iosSectionMargin,
            decoration: iosSectionDecoration(context),
            children: [
              for (final m in g.models)
                CupertinoListTile(
                  key: ValueKey('${g.id}/${m.id}'),
                  title: Text(
                    m.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: m.contextWindow != null
                      ? Text('上下文 ${(m.contextWindow! / 1000).round()}k')
                      : null,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_current != null &&
                          _current!.provider == m.providerId &&
                          _current!.model == m.id)
                        const Icon(
                          CupertinoIcons.checkmark_circle_fill,
                          color: CupertinoColors.activeBlue,
                        ),
                      if (_deletableModelIds.contains(m.id)) ...[
                        const SizedBox(width: 8),
                        CupertinoButton(
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(32, 32),
                          onPressed: _selecting ? null : () => _delete(m),
                          child: const Icon(
                            CupertinoIcons.delete,
                            size: 18,
                            color: CupertinoColors.systemRed,
                          ),
                        ),
                      ],
                    ],
                  ),
                  onTap: _selecting ? null : () => _select(m),
                ),
            ],
          ),
      ],
    );
  }
}
