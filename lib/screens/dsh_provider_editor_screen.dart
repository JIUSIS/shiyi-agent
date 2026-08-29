import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/models.dart';
import '../services/dsh_provider_config.dart';
import '../services/llm_client.dart';
import '../widgets/ios_style.dart';
import '../widgets/mac_action_button.dart';

class DshProviderEditorResult {
  final String id;
  final String displayName;
  final String protocol;
  final String baseUrl;
  final String credentialRef;
  final String apiKey;
  final List<String> models;
  final Map<String, dynamic> providerValue;

  const DshProviderEditorResult({
    required this.id,
    required this.displayName,
    required this.protocol,
    required this.baseUrl,
    required this.credentialRef,
    required this.apiKey,
    required this.models,
    required this.providerValue,
  });
}

class DshProviderEditorScreen extends StatefulWidget {
  final DshProviderConfig? initial;
  final Set<String> existingIds;

  const DshProviderEditorScreen({
    super.key,
    this.initial,
    this.existingIds = const {},
  });

  @override
  State<DshProviderEditorScreen> createState() =>
      _DshProviderEditorScreenState();
}

class _DshProviderEditorScreenState extends State<DshProviderEditorScreen> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _idCtrl;
  late final TextEditingController _urlCtrl;
  late final TextEditingController _keyCtrl;
  late final TextEditingController _credentialCtrl;
  late String _protocol;
  late final Set<String> _models;
  List<String> _catalog = const [];
  bool _advanced = false;
  bool _showKey = false;
  bool _idAutomatic = true;
  bool _credentialAutomatic = true;
  bool _busy = false;

  bool get _editing => widget.initial != null;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _nameCtrl = TextEditingController(text: initial?.displayName ?? '');
    _idCtrl = TextEditingController(text: initial?.id ?? '');
    _urlCtrl = TextEditingController(text: initial?.baseUrl ?? '');
    _keyCtrl = TextEditingController();
    _credentialCtrl = TextEditingController(text: initial?.credentialRef ?? '');
    _protocol = initial?.protocol ?? 'openai';
    _models = {...?initial?.models};
    _idAutomatic = !_editing;
    _credentialAutomatic = !_editing || _credentialCtrl.text.trim().isEmpty;
    if (_credentialAutomatic && _idCtrl.text.trim().isNotEmpty) {
      _credentialCtrl.text = dshCredentialRefForProvider(_idCtrl.text);
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _idCtrl.dispose();
    _urlCtrl.dispose();
    _keyCtrl.dispose();
    _credentialCtrl.dispose();
    super.dispose();
  }

  void _nameChanged(String value) {
    if (!_idAutomatic) return;
    final id = dshProviderIdFromName(value);
    _idCtrl.text = id;
    if (_credentialAutomatic) {
      _credentialCtrl.text = dshCredentialRefForProvider(id);
    }
    setState(() {});
  }

  void _idChanged(String value) {
    _idAutomatic = false;
    if (_credentialAutomatic) {
      _credentialCtrl.text = dshCredentialRefForProvider(value);
    }
  }

  String _normalizedUrl() {
    final raw = _urlCtrl.text.trim();
    if (raw.isEmpty) return '';
    return _protocol == 'anthropic'
        ? LlmClient.normalizeAnthropicBaseUrl(raw)
        : normalizeOpenAiBaseUrl(raw);
  }

  LlmClient? _client({bool requireModel = false}) {
    final url = _normalizedUrl();
    final key = _keyCtrl.text.trim();
    final model = _models.isEmpty ? '' : _models.first;
    if (url.isEmpty || key.isEmpty || (requireModel && model.isEmpty)) {
      return null;
    }
    return LlmClient(
      baseUrl: url,
      apiKey: key,
      model: model,
      protocol: _protocol,
      temperature: 0,
      maxTokens: 32,
      tools: const [],
    );
  }

  Future<void> _fetchModels() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final client = _client();
    if (client == null) {
      await _alert('请先填写接口地址和 API Key');
      return;
    }
    try {
      setState(() => _busy = true);
      final ids = await showIosProgressDialog<List<String>>(
        context: context,
        message: '正在获取模型目录…',
        task: client.listModels,
      );
      if (!mounted) return;
      final catalog =
          ids.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet().toList()
            ..sort();
      if (catalog.isEmpty) {
        await _alert('接口返回了空模型列表');
        return;
      }
      setState(() => _catalog = catalog);
      await _pickModels(catalog);
    } catch (e) {
      if (mounted) await _alert('获取模型失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickModels(List<String> catalog) async {
    final selected = await Navigator.of(context).push<Set<String>>(
      MaterialPageRoute(
        builder: (_) =>
            _DshModelPickerScreen(models: catalog, selected: _models),
      ),
    );
    if (selected == null || !mounted) return;
    setState(() {
      _models
        ..clear()
        ..addAll(selected);
    });
  }

  Future<void> _addModel() async {
    final ctrl = TextEditingController();
    final value = await showIosFadeDialog<String>(
      context: context,
      builder: (ctx) => CupertinoTheme(
        data: iosCupertinoTheme(ctx),
        child: CupertinoAlertDialog(
          title: const Text('手动添加模型'),
          content: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: CupertinoTextField(
              controller: ctrl,
              autofocus: true,
              autocorrect: false,
              placeholder: '模型 ID',
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
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    if (value == null || value.isEmpty || !mounted) return;
    setState(() => _models.add(value));
  }

  Future<void> _testConnection() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final client = _client(requireModel: true);
    if (client == null) {
      await _alert(
        _editing && _keyCtrl.text.trim().isEmpty
            ? '测试连接需要重新输入 API Key；留空保存仍会保留远端旧密钥'
            : '请先填写接口地址、API Key，并至少选择一个模型',
      );
      return;
    }
    try {
      setState(() => _busy = true);
      final result = await showIosProgressDialog<String>(
        context: context,
        message: '正在测试连接…',
        task: client.testChat,
      );
      if (mounted) await _alert(result);
    } catch (e) {
      if (mounted) await _alert('测试连接失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final name = _nameCtrl.text.trim();
    final id = _idCtrl.text.trim();
    final url = _normalizedUrl();
    final credential = _credentialCtrl.text.trim();
    final models =
        _models.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet().toList()
          ..sort();
    String? error;
    if (name.isEmpty) {
      error = '请填写配置名称';
    } else if (!isValidDshProviderId(id)) {
      error = 'Provider ID 只能包含字母、数字、下划线和短横线';
    } else if (!_editing && widget.existingIds.contains(id)) {
      error = 'Provider ID 已存在：$id';
    } else if (url.isEmpty || Uri.tryParse(url)?.hasScheme != true) {
      error = '请填写有效的 HTTP/HTTPS 接口地址';
    } else if (!isValidDshCredentialRef(credential)) {
      error = '凭据引用只能使用大写字母、数字和下划线，且不能以数字开头';
    } else if (!_editing && _keyCtrl.text.trim().isEmpty) {
      error = '新增 API 必须填写 API Key';
    } else if (_editing &&
        credential != widget.initial!.credentialRef &&
        _keyCtrl.text.trim().isEmpty) {
      error = '修改凭据引用时必须同时填写新的 API Key';
    } else if (models.isEmpty) {
      error = '请获取或手动添加至少一个模型';
    }
    if (error != null) {
      await _alert(error);
      return;
    }
    final base =
        widget.initial ??
        DshProviderConfig(
          id: id,
          displayName: name,
          protocol: _protocol,
          baseUrl: url,
          credentialRef: credential,
          models: models,
        );
    final providerValue = base.toProviderValue(
      displayName: name,
      protocol: _protocol,
      baseUrl: url,
      credentialRef: credential,
      models: models,
    );
    Navigator.pop(
      context,
      DshProviderEditorResult(
        id: id,
        displayName: name,
        protocol: _protocol,
        baseUrl: url,
        credentialRef: credential,
        apiKey: _keyCtrl.text.trim(),
        models: models,
        providerValue: providerValue,
      ),
    );
  }

  Future<void> _alert(String message) => showIosFadeDialog<void>(
    context: context,
    builder: (ctx) => CupertinoTheme(
      data: iosCupertinoTheme(ctx),
      child: CupertinoAlertDialog(
        content: Text(message),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(ctx),
            child: const Text('好'),
          ),
        ],
      ),
    ),
  );

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
                onTap: _busy ? null : () => Navigator.pop(context),
              ),
            ),
          ),
          toolbarHeight: 64,
          centerTitle: true,
          backgroundColor: theme.scaffoldBackgroundColor,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          title: Text(
            _editing ? '编辑 API' : '新增 API',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: MacActionButton(
                icon: CupertinoIcons.checkmark_alt,
                tooltip: '保存',
                onTap: _busy ? null : _save,
              ),
            ),
          ],
        ),
        body: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
          child: ListView(
            padding: const EdgeInsets.only(top: 4, bottom: 32),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            children: [
              CupertinoListSection.insetGrouped(
                header: const Text('接口'),
                footer: Text(
                  _editing
                      ? 'API Key 留空会保留目标 DSH 中的旧密钥。'
                      : '密钥只写入目标 DSH 的凭据存储。',
                ),
                margin: iosSectionMargin,
                decoration: iosSectionDecoration(context),
                children: [
                  _EditorFieldTile(
                    label: '名称',
                    child: CupertinoTextField(
                      key: const Key('dsh-provider-name'),
                      controller: _nameCtrl,
                      placeholder: '例如：硅基流动',
                      onChanged: _nameChanged,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('协议', style: TextStyle(fontSize: 13)),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: CupertinoSlidingSegmentedControl<String>(
                            key: const Key('dsh-provider-protocol'),
                            groupValue: _protocol,
                            children: const {
                              'openai': Padding(
                                padding: EdgeInsets.symmetric(horizontal: 6),
                                child: Text('Chat'),
                              ),
                              'responses': Padding(
                                padding: EdgeInsets.symmetric(horizontal: 6),
                                child: Text('Responses'),
                              ),
                              'anthropic': Padding(
                                padding: EdgeInsets.symmetric(horizontal: 6),
                                child: Text('Claude'),
                              ),
                            },
                            onValueChanged: (value) {
                              if (_busy || value == null) return;
                              setState(() => _protocol = value);
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  _EditorFieldTile(
                    label: '接口地址',
                    child: CupertinoTextField(
                      key: const Key('dsh-provider-url'),
                      controller: _urlCtrl,
                      placeholder: 'https://api.example.com/v1',
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                    ),
                  ),
                  _EditorFieldTile(
                    label: 'API Key',
                    child: CupertinoTextField(
                      key: const Key('dsh-provider-key'),
                      controller: _keyCtrl,
                      placeholder: _editing ? '留空保留旧密钥' : 'sk-…',
                      obscureText: !_showKey,
                      autocorrect: false,
                      suffix: CupertinoButton(
                        minimumSize: const Size(34, 34),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        onPressed: () => setState(() => _showKey = !_showKey),
                        child: Icon(
                          _showKey
                              ? CupertinoIcons.eye_slash
                              : CupertinoIcons.eye,
                          size: 18,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              CupertinoListSection.insetGrouped(
                header: const Text('模型'),
                footer: Text(
                  _catalog.isEmpty
                      ? '可从接口读取模型目录，也可以手动添加。'
                      : '接口返回 ${_catalog.length} 个模型，已选择 ${_models.length} 个。',
                ),
                margin: iosSectionMargin,
                decoration: iosSectionDecoration(context),
                children: [
                  if (_models.isEmpty)
                    const CupertinoListTile(
                      title: Text('尚未选择模型'),
                      subtitle: Text('至少需要一个模型才能保存'),
                    ),
                  for (final model in _models.toList()..sort())
                    CupertinoListTile(
                      key: ValueKey('selected-model-$model'),
                      title: Text(model, maxLines: 2),
                      trailing: CupertinoButton(
                        minimumSize: const Size(34, 34),
                        padding: EdgeInsets.zero,
                        onPressed: _busy
                            ? null
                            : () => setState(() => _models.remove(model)),
                        child: const Icon(
                          CupertinoIcons.minus_circle,
                          color: CupertinoColors.systemRed,
                          size: 20,
                        ),
                      ),
                    ),
                  CupertinoListTile(
                    leading: const Icon(
                      CupertinoIcons.arrow_clockwise,
                      color: CupertinoColors.activeBlue,
                    ),
                    title: const Text('获取模型目录'),
                    subtitle: const Text('使用上方地址和 API Key 请求模型列表'),
                    trailing: const CupertinoListTileChevron(),
                    onTap: _busy ? null : _fetchModels,
                  ),
                  if (_catalog.isNotEmpty)
                    CupertinoListTile(
                      leading: const Icon(
                        CupertinoIcons.list_bullet,
                        color: CupertinoColors.systemIndigo,
                      ),
                      title: const Text('选择模型'),
                      subtitle: Text('已选择 ${_models.length} 个'),
                      trailing: const CupertinoListTileChevron(),
                      onTap: _busy ? null : () => _pickModels(_catalog),
                    ),
                  CupertinoListTile(
                    leading: const Icon(
                      CupertinoIcons.plus_circle,
                      color: CupertinoColors.systemGreen,
                    ),
                    title: const Text('手动添加模型'),
                    trailing: const CupertinoListTileChevron(),
                    onTap: _busy ? null : _addModel,
                  ),
                ],
              ),
              CupertinoListSection.insetGrouped(
                header: const Text('验证'),
                margin: iosSectionMargin,
                decoration: iosSectionDecoration(context),
                children: [
                  CupertinoListTile(
                    leading: const Icon(
                      CupertinoIcons.antenna_radiowaves_left_right,
                      color: CupertinoColors.systemGreen,
                    ),
                    title: const Text('测试连接'),
                    subtitle: const Text('发送最小请求确认接口与模型可用'),
                    trailing: const CupertinoListTileChevron(),
                    onTap: _busy ? null : _testConnection,
                  ),
                ],
              ),
              CupertinoListSection.insetGrouped(
                header: const Text('高级选项'),
                margin: iosSectionMargin,
                decoration: iosSectionDecoration(context),
                children: [
                  CupertinoListTile(
                    title: const Text('底层标识'),
                    subtitle: const Text('普通使用无需修改'),
                    trailing: Icon(
                      _advanced
                          ? CupertinoIcons.chevron_up
                          : CupertinoIcons.chevron_down,
                      size: 18,
                    ),
                    onTap: () => setState(() => _advanced = !_advanced),
                  ),
                  if (_advanced) ...[
                    _EditorFieldTile(
                      label: 'Provider ID',
                      child: CupertinoTextField(
                        key: const Key('dsh-provider-id'),
                        controller: _idCtrl,
                        enabled: !_editing,
                        autocorrect: false,
                        onChanged: _idChanged,
                      ),
                    ),
                    _EditorFieldTile(
                      label: '凭据引用',
                      child: CupertinoTextField(
                        key: const Key('dsh-provider-credential'),
                        controller: _credentialCtrl,
                        autocorrect: false,
                        onChanged: (_) => _credentialAutomatic = false,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EditorFieldTile extends StatelessWidget {
  final String label;
  final Widget child;

  const _EditorFieldTile({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 7),
          child,
        ],
      ),
    );
  }
}

class _DshModelPickerScreen extends StatefulWidget {
  final List<String> models;
  final Set<String> selected;

  const _DshModelPickerScreen({required this.models, required this.selected});

  @override
  State<_DshModelPickerScreen> createState() => _DshModelPickerScreenState();
}

class _DshModelPickerScreenState extends State<_DshModelPickerScreen> {
  final TextEditingController _search = TextEditingController();
  late final Set<String> _selected = {...widget.selected};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final visible = widget.models
        .where((model) => query.isEmpty || model.toLowerCase().contains(query))
        .toList();
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
                onTap: () => Navigator.pop(context),
              ),
            ),
          ),
          centerTitle: true,
          title: Text('选择模型（${_selected.length}）'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: MacActionButton(
                icon: CupertinoIcons.checkmark_alt,
                tooltip: '完成',
                onTap: () => Navigator.pop(context, _selected),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
              child: CupertinoSearchTextField(
                controller: _search,
                placeholder: '搜索模型',
                onChanged: (_) => setState(() {}),
              ),
            ),
            Expanded(
              child: ListView.builder(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                itemCount: visible.length,
                itemBuilder: (context, index) {
                  final model = visible[index];
                  final selected = _selected.contains(model);
                  return CupertinoListTile(
                    title: Text(model),
                    trailing: Icon(
                      selected
                          ? CupertinoIcons.checkmark_circle_fill
                          : CupertinoIcons.circle,
                      color: selected
                          ? CupertinoColors.activeBlue
                          : CupertinoColors.systemGrey,
                    ),
                    onTap: () => setState(() {
                      if (selected) {
                        _selected.remove(model);
                      } else {
                        _selected.add(model);
                      }
                    }),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
