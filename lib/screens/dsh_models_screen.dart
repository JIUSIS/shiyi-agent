import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../services/dsh_api.dart';
import '../services/dsh_model_sync.dart';
import '../services/dsh_provider_config.dart';
import '../services/dsh_service.dart';
import 'dsh_provider_editor_screen.dart';
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
  List<DshProviderConfig> _targetProviders = [];
  Map<String, DshCredentialSlot> _targetCredentials = const {};
  bool _showTargetDsh = false;
  bool _loading = true;
  String? _error;
  bool _deleting = false;
  bool _targetWritable = false;
  String? _targetNotice;

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
      // 本机与局域网 / 公网统一：模型数据永远展示目标 DSH 的 provider 目录。
      List<DshProviderConfig> providers = const [];
      var writable = false;
      String? notice;
      List<Map<String, dynamic>> directory = const [];
      List<DshModelGroup> groups = const [];
      DshSettingsNamespace? namespace;

      // The provider directory is the live source of truth for configured
      // routes. settings.describe may be unavailable remotely or may expose
      // a stale merged snapshot, so it must not decide what is displayed.
      try {
        directory = await _api.llmProviders();
        try {
          groups = await _api.llmModels();
        } catch (_) {
          // A provider list is still useful when the optional model catalog
          // is unavailable.
        }
      } catch (e) {
        if (e is! DshApiException || e.code != 'http-403') rethrow;
      }

      try {
        final settings = await _api.describeSettings();
        namespace = settings.namespaces
            .where((item) => item.ns == DshModelSync.settingsNs)
            .firstOrNull;
        writable = settings.writable && namespace != null;
      } on DshApiException catch (e) {
        if (e.code != 'http-403') rethrow;
        writable = false;
        notice =
            '远端设置读取被拒绝（403），当前仅显示服务器声明的实际 provider。修改或删除需要远端允许 settings.describe/settings.mutate。';
      }
      providers = mergeDshProviderConfigs(
        settings: settingsProviderMaps(namespace),
        directory: directory,
        groups: groups,
      );
      var credentials = const <String, DshCredentialSlot>{};
      final refs = providers
          .map((provider) => provider.credentialRef)
          .where((ref) => ref.isNotEmpty)
          .toSet()
          .toList();
      if (refs.isNotEmpty) {
        try {
          credentials = {
            for (final slot in await _api.describeCredentials(refs: refs))
              if (slot.ref.isNotEmpty) slot.ref: slot,
          };
        } catch (_) {
          // Provider 配置仍可浏览，凭据状态只是辅助信息。
        }
      }
      if (!mounted) return;
      setState(() {
        _targetProviders = providers;
        _targetCredentials = credentials;
        _showTargetDsh = true;
        _targetWritable = writable;
        _targetNotice = notice;
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
          if (_showTargetDsh && _targetWritable)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: MacActionButton(
                icon: CupertinoIcons.add,
                tooltip: '新增远端 API',
                onTap: !_targetWritable || _deleting
                    ? null
                    : () => _editTargetProvider(null),
              ),
            ),
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
    if (_showTargetDsh) return _buildTargetDshBody();
    return const Center(child: Text('暂无已注入配置，请先在设置中保存并注入'));
  }

  Widget _buildTargetDshBody() {
    return ListView(
      padding: const EdgeInsets.only(top: 4, bottom: 24),
      children: [
        CupertinoListSection.insetGrouped(
          header: const Text('目标 DSH 的 API'),
          footer: DefaultTextStyle.merge(
            style: const TextStyle(
              fontSize: 12,
              height: 1.35,
              fontWeight: FontWeight.w400,
              color: CupertinoColors.secondaryLabel,
            ),
            child: Text(
              _targetNotice ??
                  (_targetWritable
                      ? '这里显示当前 DSH 的实际 provider 配置。密钥写入目标 DSH 的凭据槽，不会保存到拾忆本地配置。'
                      : '当前 DSH 的设置接口为只读，无法新增、修改或删除配置。请在服务器端开启可写设置。'),
            ),
          ),
          margin: iosSectionMargin,
          decoration: iosSectionDecoration(context),
          children: [
            if (_targetProviders.isEmpty)
              const CupertinoListTile(
                title: Text('暂无远端 API 配置'),
                subtitle: Text('当前连接没有可显示的已声明 provider'),
              ),
            for (final provider in _targetProviders)
              _targetProviderTile(provider),
          ],
        ),
      ],
    );
  }

  Widget _targetProviderTile(DshProviderConfig provider) {
    final credential = _targetCredentials[provider.credentialRef];
    final secondary = CupertinoDynamicColor.resolve(
      CupertinoColors.secondaryLabel,
      context,
    );
    Widget detail(String text, {int maxLines = 2}) => Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Text(
        text,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 13, height: 1.22, color: secondary),
      ),
    );
    return Padding(
      key: ValueKey('target-${provider.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 3),
            child: Icon(
              CupertinoIcons.desktopcomputer,
              color: CupertinoColors.activeBlue,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  provider.displayName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 17,
                    height: 1.18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                detail(
                  '${_protocolLabel(provider.protocol)} · ${provider.models.length} 个模型',
                  maxLines: 1,
                ),
                if (provider.isBuiltinDeclared)
                  detail('内置声明 · ${provider.settingsNs}', maxLines: 1),
                if (provider.baseUrl.isNotEmpty)
                  detail(provider.baseUrl, maxLines: 2),
                if (provider.models.isNotEmpty)
                  detail('模型：${_modelSummary(provider.models)}'),
                if (provider.credentialRef.isNotEmpty)
                  detail(
                    credential == null
                        ? '凭据：状态未知'
                        : credential.set
                        ? '凭据：已配置'
                        : '凭据：未配置',
                    maxLines: 1,
                  ),
              ],
            ),
          ),
          if (_targetWritable) ...[
            const SizedBox(width: 4),
            Column(
              children: [
                if (!provider.isBuiltinDeclared)
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(36, 36),
                    onPressed: provider.id.isEmpty || _deleting
                        ? null
                        : () => _editTargetProvider(provider),
                    child: const Icon(CupertinoIcons.pencil, size: 19),
                  )
                else
                  const Icon(
                    CupertinoIcons.lock_fill,
                    size: 15,
                    color: CupertinoColors.systemGrey,
                  ),
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(36, 36),
                  onPressed: provider.id.isEmpty || _deleting
                      ? null
                      : () => _deleteTargetProvider(provider),
                  child: const Icon(
                    CupertinoIcons.delete,
                    size: 18,
                    color: CupertinoColors.systemRed,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static List<String> _providerModels(Map<String, dynamic> provider) {
    final raw = provider['models'];
    if (raw is! List) return const [];
    final result = [
      for (final item in raw)
        if (item is Map)
          (item['id'] ?? item['name'] ?? '').toString().trim()
        else
          item.toString().trim(),
    ].where((e) => e.isNotEmpty).toList();
    return result.toSet().toList();
  }

  static String _modelSummary(List<String> models) {
    const previewCount = 4;
    final preview = models.take(previewCount).join('、');
    if (models.length <= previewCount) return preview;
    return '$preview 等共 ${models.length} 个';
  }

  static String _protocolLabel(String protocol) => switch (protocol) {
    'responses' => 'Responses',
    'anthropic' => 'Claude Messages',
    _ => 'Chat Completions',
  };

  Future<void> _editTargetProvider(DshProviderConfig? source) async {
    if (!_targetWritable) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('当前 DSH 设置为只读，无法修改 API')));
      return;
    }
    final editing = source != null;
    final result = await Navigator.of(context).push<DshProviderEditorResult>(
      MaterialPageRoute(
        builder: (_) => DshProviderEditorScreen(
          initial: source,
          existingIds: _targetProviders.map((item) => item.id).toSet(),
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() => _deleting = true);
    var providerWritten = false;
    try {
      await _api.mutateSettings(DshModelSync.settingsNs, [
        {
          'op': 'set',
          'path': ['providers', result.id],
          'value': result.providerValue,
        },
      ]);
      providerWritten = true;
      if (result.apiKey.isNotEmpty) {
        await _api.setCredential(result.credentialRef, result.apiKey);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(editing ? '远端 API 已修改' : '远端 API 已新增')),
      );
      await _load();
    } catch (e) {
      if (providerWritten) {
        try {
          if (source == null) {
            await _api.mutateSettings(
              DshModelSync.settingsNs,
              DshModelSync.unsetProviderOps(result.id),
            );
          } else {
            await _api.mutateSettings(DshModelSync.settingsNs, [
              {
                'op': 'set',
                'path': ['providers', source.id],
                'value': source.toProviderValue(
                  displayName: source.displayName,
                  protocol: source.protocol,
                  baseUrl: source.baseUrl,
                  credentialRef: source.credentialRef,
                  models: source.models,
                ),
              },
            ]);
          }
        } catch (_) {}
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_targetMutationError('保存', e))));
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  /// 兼容不同 DSH 版本返回的空 id、重复 id 和备用 id 字段，避免列表
  /// 使用相同 ValueKey 时触发 Flutter 红屏。
  static List<Map<String, dynamic>> _normalizeTargetProviders(
    Iterable<Map<String, dynamic>> source,
  ) {
    final byId = <String, Map<String, dynamic>>{};
    for (final raw in source) {
      final provider = Map<String, dynamic>.from(raw);
      final id =
          (provider['id'] ??
                  provider['providerId'] ??
                  provider['provider'] ??
                  provider['key'] ??
                  '')
              .toString()
              .trim();
      if (id.isEmpty) continue;
      provider['id'] = id;
      final previous = byId[id];
      if (previous == null) {
        byId[id] = provider;
        continue;
      }
      final merged = <String, dynamic>{...previous, ...provider};
      final models = <dynamic>[];
      for (final model in [
        ..._providerModels(previous),
        ..._providerModels(provider),
      ]) {
        if (!models.any((item) => item is Map && item['id'] == model)) {
          models.add({'id': model, 'name': model});
        }
      }
      if (models.isNotEmpty) merged['models'] = models;
      byId[id] = merged;
    }
    return byId.values.toList();
  }

  /// `llm.providers` 是全量目录，实际配置必须从 settings.describe 取。
  // ignore: unused_element
  static List<Map<String, dynamic>> _configuredTargetProviders(
    DshSettingsNamespace? namespace,
  ) {
    if (namespace == null) return const [];
    dynamic raw = namespace.user['providers'];
    if (raw is! Map || raw.isEmpty) raw = namespace.value['providers'];
    if (raw is! Map) return const [];
    return _normalizeTargetProviders([
      for (final entry in raw.entries)
        if (entry.value is Map)
          {
            'id': entry.key.toString(),
            ...(entry.value as Map).cast<String, dynamic>(),
          },
    ]);
  }

  /// 设置快照不可用时，从官方 provider 目录筛出当前已注册的配置路由。
  // ignore: unused_element
  static List<Map<String, dynamic>> _configuredTargetProvidersFromDirectory(
    Iterable<Map<String, dynamic>> directory,
    Iterable<DshModelGroup> groups,
  ) {
    final modelsByProvider = <String, List<Map<String, dynamic>>>{};
    for (final group in groups) {
      final models = [
        for (final model in group.models) {'id': model.id, 'name': model.name},
      ];
      if (models.isNotEmpty) modelsByProvider[group.id] = models;
    }
    final rows = <Map<String, dynamic>>[];
    for (final raw in directory) {
      final provider = Map<String, dynamic>.from(raw);
      final id =
          (provider['id'] ??
                  provider['provider'] ??
                  provider['providerId'] ??
                  provider['key'] ??
                  '')
              .toString()
              .trim();
      final settingsNs = (provider['settingsNs'] ?? '').toString().trim();
      final settingsPath =
          (provider['settingsPath'] as List?)
              ?.map((item) => item.toString())
              .toList() ??
          const <String>[];
      final declared = provider['declared'] == true;
      if (id.isEmpty ||
          settingsNs != DshModelSync.settingsNs ||
          settingsPath.length < 2 ||
          !declared) {
        continue;
      }
      provider['id'] = id;
      final models = modelsByProvider[id];
      if (models != null && models.isNotEmpty) provider['models'] = models;
      rows.add(provider);
    }
    return _normalizeTargetProviders(rows);
  }

  // ignore: unused_element
  Future<void> _legacyEditTargetProvider(Map<String, dynamic>? source) async {
    if (!_targetWritable) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('当前 DSH 设置为只读，无法修改 API')));
      return;
    }
    final editing = source != null;
    final existingId = (source?['id'] ?? source?['providerId'] ?? '')
        .toString()
        .trim();
    final idCtrl = TextEditingController(text: existingId);
    final nameCtrl = TextEditingController(
      text: (source?['displayName'] ?? source?['name'] ?? '').toString(),
    );
    final apiCtrl = TextEditingController(
      text: (source?['api'] ?? 'openai-completions').toString(),
    );
    final urlCtrl = TextEditingController(
      text: (source?['baseURL'] ?? source?['baseUrl'] ?? '').toString(),
    );
    final envCtrl = TextEditingController(
      text: (source?['apiKeyEnv'] ?? '').toString(),
    );
    final keyCtrl = TextEditingController();
    final modelsCtrl = TextEditingController(
      text: source == null ? '' : _providerModels(source).join(', '),
    );
    final result = await showIosFadeDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text(editing ? '修改远端 API' : '新增远端 API'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CupertinoTextField(
              controller: idCtrl,
              enabled: !editing,
              placeholder: 'Provider ID，例如 my_gateway',
              autocorrect: false,
            ),
            const SizedBox(height: 8),
            CupertinoTextField(controller: nameCtrl, placeholder: '名称'),
            const SizedBox(height: 8),
            CupertinoTextField(
              controller: apiCtrl,
              placeholder: '协议，例如 openai-completions',
            ),
            const SizedBox(height: 8),
            CupertinoTextField(controller: urlCtrl, placeholder: '接口地址'),
            const SizedBox(height: 8),
            CupertinoTextField(
              controller: envCtrl,
              placeholder: '凭据槽，例如 MY_GATEWAY_API_KEY',
              autocorrect: false,
            ),
            const SizedBox(height: 8),
            CupertinoTextField(
              controller: keyCtrl,
              placeholder: editing ? '新 API Key（留空保留旧值）' : 'API Key',
              obscureText: true,
              autocorrect: false,
            ),
            const SizedBox(height: 8),
            CupertinoTextField(
              controller: modelsCtrl,
              placeholder: '模型 ID，逗号分隔',
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
            onPressed: () {
              final id = idCtrl.text.trim();
              final models = [
                for (final model in modelsCtrl.text.split(','))
                  if (model.trim().isNotEmpty)
                    {'id': model.trim(), 'name': model.trim()},
              ];
              if (!_validProviderId(id) ||
                  apiCtrl.text.trim().isEmpty ||
                  urlCtrl.text.trim().isEmpty ||
                  models.isEmpty) {
                return;
              }
              final env = envCtrl.text.trim().isEmpty
                  ? _defaultCredentialRef(id)
                  : envCtrl.text.trim();
              if (!_validCredentialRef(env)) return;
              final next = source == null
                  ? <String, dynamic>{}
                  : Map<String, dynamic>.from(source);
              next
                ..remove('id')
                ..remove('providerId')
                ..remove('name')
                ..['displayName'] = nameCtrl.text.trim().isEmpty
                    ? id
                    : nameCtrl.text.trim()
                ..['api'] = apiCtrl.text.trim()
                ..['baseURL'] = urlCtrl.text.trim()
                ..['apiKeyEnv'] = env
                ..['models'] = models;
              Navigator.pop(ctx, {
                'id': id,
                'provider': next,
                'credential': keyCtrl.text.trim(),
              });
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    idCtrl.dispose();
    nameCtrl.dispose();
    apiCtrl.dispose();
    urlCtrl.dispose();
    envCtrl.dispose();
    keyCtrl.dispose();
    modelsCtrl.dispose();
    if (result == null || !mounted) return;
    final id = result['id'].toString();
    if (!editing && _targetProviders.any((item) => item.id == id)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Provider ID 已存在：$id')));
      return;
    }
    final provider = (result['provider'] as Map).cast<String, dynamic>();
    final credential = result['credential'].toString();
    try {
      await _api.mutateSettings('llm-pi-ai', [
        {
          'op': 'set',
          'path': ['providers', id],
          'value': provider,
        },
      ]);
      if (credential.isNotEmpty) {
        await _api.setCredential(provider['apiKeyEnv'].toString(), credential);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(editing ? '远端 API 已修改' : '远端 API 已新增')),
      );
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存远端 API 失败：$e')));
      }
    }
  }

  Future<void> _deleteTargetProvider(DshProviderConfig provider) async {
    if (!_targetWritable) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('当前 DSH 设置为只读，无法删除 API')));
      return;
    }
    final id = provider.id.trim();
    if (id.isEmpty || _deleting) return;
    final credential = provider.credentialRef.trim();
    final hasRoute =
        provider.settingsNs.isNotEmpty && provider.settingsPath.isNotEmpty;
    if (provider.isBuiltinDeclared && !hasRoute && credential.isEmpty) {
      // 内置声明且没有任何可清除项（如 deepseek-official / llm-deepseek）：
      // 不发无意义的 mutate，向用户说明边界。
      showIosFadeDialog<void>(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: Text('「${provider.displayName}」是内置 provider'),
          content: Text(
            '它由 DSH 的 ${provider.settingsNs} 命名空间内置声明，'
            '设置层面没有可清除的路由或凭据。\n'
            '其模型仍会出现在模型选择器中。',
          ),
          actions: [
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () => Navigator.pop(ctx),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      return;
    }
    final confirmed = await showIosConfirmDialog(
      context: context,
      title: '清除远端 API？',
      message: hasRoute
          ? '将从当前 DSH 删除 provider「$id」'
                '${credential.isNotEmpty ? '并清空其凭据' : ''}。'
                '使用它的会话需要重新选择模型。'
          : '将清空「$id」的远端凭据'
                '${credential.isEmpty ? '（该 provider 没有可清除的凭据）' : ''}。',
      confirmLabel: '清除',
      isDestructiveAction: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _deleting = true);
    try {
      if (hasRoute) {
        if (provider.settingsNs == DshModelSync.settingsNs) {
          await _api.mutateSettings(
            DshModelSync.settingsNs,
            DshModelSync.unsetProviderOps(id),
          );
        } else {
          // 非 llm-pi-ai 命名空间的路由（如内置插件的 providers.<id>）
          // 按其声明路径原位清除。
          await _api.mutateSettings(provider.settingsNs, [
            {'op': 'unset', 'path': provider.settingsPath},
          ]);
        }
      }
      if (credential.isNotEmpty) {
        try {
          await _api.unsetCredential(credential);
        } on DshApiException catch (e) {
          throw DshApiException(
            'provider 已清除，但远端凭据清理被拒绝：${e.message}',
            code: e.code,
          );
        }
      }
      if (!mounted) return;
      await _load();
    } catch (e) {
      if (mounted) {
        final message = _targetMutationError('清除', e);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  static bool _validProviderId(String value) =>
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]*$').hasMatch(value);

  static bool _validCredentialRef(String value) =>
      RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(value);

  static String _defaultCredentialRef(String providerId) =>
      '${providerId.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]+'), '_')}_API_KEY';

  static String _targetMutationError(String action, Object error) {
    if (error is DshApiException &&
        (error.code == 'http-403' || error.code == 'forbidden')) {
      return '$action失败：远端 DSH 的设置/凭据接口只允许服务器本机回环访问（403）。拾忆不能绕过这条安全限制，请在服务器本机管理配置，或部署受保护的管理插件。';
    }
    return '$action远端 API 失败：$error';
  }
}
