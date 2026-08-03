import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/model_presets.dart';
import '../core/models.dart';
import '../services/llm_client.dart';
import '../services/permission_service.dart';
import '../services/settings_service.dart';

class SettingsScreen extends StatefulWidget {
  final ShiyiState shiyi;
  const SettingsScreen({super.key, required this.shiyi});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _baseCtrl;
  late final TextEditingController _keyCtrl;
  late final TextEditingController _modelCtrl;
  late final TextEditingController _promptCtrl;
  double _temperature = 0.7;
  bool _tools = true;
  bool _memory = true;
  bool _autoLearn = true;
  double _ttsRate = 1.0;
  String _themeMode = 'dark';
  int _contextLimit = 1000000;
  double _compressThresholdPercent = 80;
  bool _autoCompress = true;
  String _keyHint = 'sk-...';
  String? _presetName;
  bool _showKey = false;
  bool _profilesLoaded = false;
  List<ApiProfile> _profiles = [];
  bool _fileAccessGranted = false;
  Timer? _saveTimer;

  @override
  void initState() {
    super.initState();
    final s = widget.shiyi.settings;
    _baseCtrl = TextEditingController(text: s.baseUrl);
    _keyCtrl = TextEditingController(text: s.apiKey);
    _modelCtrl = TextEditingController(text: s.model);
    _promptCtrl = TextEditingController(text: s.systemPrompt);
    _temperature = s.temperature;
    _tools = s.enableTools;
    _memory = s.enableMemory;
    _autoLearn = s.enableAutoLearn;
    _ttsRate = s.ttsRate;
    _themeMode = s.themeMode;
    _contextLimit = s.contextLimit;
    _compressThresholdPercent = s.compressThresholdPercent;
    _autoCompress = s.autoCompress;
    for (final preset in modelPresets) {
      if (preset.baseUrl == s.baseUrl.trim()) {
        _presetName = preset.name;
        _keyHint = preset.keyHint;
        break;
      }
    }
    _loadProfiles();
    _checkFileAccess();
  }

  /// 读取已保存的 API 配置（内置预设的密钥/模型 + 自定义接口）。
  Future<void> _loadProfiles() async {
    final profiles = await SettingsService().loadProfiles();
    if (!mounted) return;
    setState(() {
      _profiles = profiles;
      _profilesLoaded = true;
      if (_presetName == null) {
        final cur = _allProfiles
            .where((p) => p.baseUrl == widget.shiyi.settings.baseUrl.trim())
            .toList();
        if (cur.isNotEmpty) _presetName = cur.first.name;
      }
    });
  }

  /// 内置预设 + 自定义配置合并（内置的密钥/模型以已保存为准）。
  List<ApiProfile> get _allProfiles {
    final saved = {for (final p in _profiles) p.name: p};
    final all = <ApiProfile>[];
    for (final p in modelPresets) {
      final sp = saved[p.name];
      all.add(
        ApiProfile(
          name: p.name,
          baseUrl: p.baseUrl,
          apiKey: sp?.apiKey ?? '',
          model: (sp?.model.isNotEmpty ?? false) ? sp!.model : p.model,
        ),
      );
    }
    for (final p in _profiles) {
      if (modelPresets.every((m) => m.name != p.name)) all.add(p);
    }
    return all;
  }

  /// 应用一组配置：一键填接口地址/模型，已保存过密钥就自动带出。
  void _applyPreset(ApiProfile profile) {
    ModelPreset? preset;
    for (final p in modelPresets) {
      if (p.name == profile.name) {
        preset = p;
        break;
      }
    }
    setState(() {
      _presetName = profile.name;
      _keyHint = preset?.keyHint ?? 'sk-...';
    });
    _baseCtrl.text = profile.baseUrl;
    _keyCtrl.text = profile.apiKey;
    _modelCtrl.text = profile.model;
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _baseCtrl.dispose();
    _keyCtrl.dispose();
    _modelCtrl.dispose();
    _promptCtrl.dispose();
    super.dispose();
  }

  /// 除系统提示词外的设置自动保存（防抖合并）。
  void _autoSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(
      const Duration(milliseconds: 600),
      () => _applySettings(),
    );
  }

  Future<void> _applySettings({bool includePrompt = false}) async {
    final shiyi = widget.shiyi;
    await shiyi.updateSettings(
      shiyi.settings.copyWith(
        baseUrl: _baseCtrl.text.trim().isEmpty
            ? 'https://api.deepseek.com/v1'
            : _baseCtrl.text.trim(),
        apiKey: _keyCtrl.text.trim(),
        model: _modelCtrl.text.trim(),
        systemPrompt: includePrompt
            ? _promptCtrl.text
            : shiyi.settings.systemPrompt,
        temperature: _temperature,
        enableTools: _tools,
        enableMemory: _memory,
        enableAutoLearn: _autoLearn,
        ttsRate: _ttsRate,
        themeMode: _themeMode,
        contextLimit: _contextLimit,
        compressThresholdPercent: _compressThresholdPercent,
        autoCompress: _autoCompress,
      ),
    );
    // 把当前接口地址/密钥/模型写回所选配置并落盘，切换时自动带出。
    await _persistCurrentProfile();
  }

  Future<void> _persistCurrentProfile() async {
    if (_presetName == null) return;
    if (!_profilesLoaded) {
      _profiles = await SettingsService().loadProfiles();
      _profilesLoaded = true;
    }
    final saved = {for (final p in _profiles) p.name: p};
    saved[_presetName!] = ApiProfile(
      name: _presetName!,
      baseUrl: _baseCtrl.text.trim(),
      apiKey: _keyCtrl.text.trim(),
      model: _modelCtrl.text.trim(),
    );
    _profiles = saved.values.toList();
    await SettingsService().saveProfiles(_profiles);
  }

  /// 系统提示词手动保存。
  Future<void> _savePrompt() async {
    await _applySettings(includePrompt: true);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('系统提示词已保存')));
    }
  }

  /// 新建自定义 OpenAI 兼容接口配置。
  Future<void> _createCustomProfile() async {
    final nameCtrl = TextEditingController();
    final urlCtrl = TextEditingController();
    final keyCtrl = TextEditingController();
    final modelCtrl = TextEditingController();
    final result =
        await showDialog<
          ({String name, String baseUrl, String apiKey, String model})
        >(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('新建自定义接口'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameCtrl,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: '名称',
                      hintText: '例如 我的中转',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: urlCtrl,
                    decoration: const InputDecoration(
                      labelText: '接口地址（OpenAI 协议）',
                      hintText: 'https://api.example.com/v1',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: keyCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'API 密钥',
                      hintText: 'sk-...',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: modelCtrl,
                    decoration: const InputDecoration(
                      labelText: '模型',
                      hintText: '例如 gpt-4o',
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  final name = nameCtrl.text.trim();
                  final url = urlCtrl.text.trim();
                  if (name.isEmpty || url.isEmpty) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(content: Text('名称和接口地址不能为空')),
                    );
                    return;
                  }
                  Navigator.pop(ctx, (
                    name: name,
                    baseUrl: url,
                    apiKey: keyCtrl.text.trim(),
                    model: modelCtrl.text.trim(),
                  ));
                },
                child: const Text('保存'),
              ),
            ],
          ),
        );
    if (result == null || !mounted) return;
    final dup =
        modelPresets.any((p) => p.name == result.name) ||
        _profiles.any((p) => p.name == result.name);
    if (dup) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('该名称已存在，换个名字')));
      return;
    }
    setState(() {
      _profiles.add(
        ApiProfile(
          name: result.name,
          baseUrl: result.baseUrl,
          apiKey: result.apiKey,
          model: result.model,
        ),
      );
      _presetName = result.name;
      _keyHint = 'sk-...';
      _baseCtrl.text = result.baseUrl;
      _keyCtrl.text = result.apiKey;
      _modelCtrl.text = result.model;
    });
    _autoSave();
  }

  /// 把当前接口地址/密钥/模型保存为命名配置（手动保存）。
  Future<void> _saveCurrentProfile() async {
    final nameCtrl = TextEditingController(text: _presetName ?? '自定义配置');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('保存 API 配置'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '配置名称',
            hintText: '例如 我的中转',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, nameCtrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    if (name != _presetName && _profiles.any((p) => p.name == name)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('该名称已存在，换个名字')));
      return;
    }
    setState(() {
      final saved = {for (final p in _profiles) p.name: p};
      saved[name] = ApiProfile(
        name: name,
        baseUrl: _baseCtrl.text.trim(),
        apiKey: _keyCtrl.text.trim(),
        model: _modelCtrl.text.trim(),
      );
      _profiles = saved.values.toList();
      _presetName = name;
      _keyHint = 'sk-...';
    });
    await SettingsService().saveProfiles(_profiles);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('配置「$name」已保存')));
    }
  }

  /// 删除当前选中的配置（内置预设不可删，自定义配置删除后落盘）。
  Future<void> _deleteCurrentProfile() async {
    if (_presetName == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('当前没有选中的配置')));
      return;
    }
    final isBuiltin = modelPresets.any((p) => p.name == _presetName);
    if (isBuiltin) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('内置预设不可删除')));
      return;
    }
    final name = _presetName!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除配置'),
        content: Text('确定删除「$name」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _profiles.removeWhere((p) => p.name == name);
      _presetName = null;
      _keyHint = 'sk-...';
    });
    await SettingsService().saveProfiles(_profiles);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('配置「$name」已删除')));
    }
  }

  /// 查询当前「所有文件访问权限」状态。
  Future<void> _checkFileAccess() async {
    final granted = await PermissionService.isFullAccessGranted();
    if (!mounted) return;
    setState(() => _fileAccessGranted = granted);
  }

  /// 获取模型列表，弹窗展示，点选可直接填入模型字段。
  Future<void> _fetchModels() async {
    final url = _baseCtrl.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先填写接口地址')));
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('正在获取模型列表…')));
    try {
      final client = LlmClient(
        baseUrl: url,
        apiKey: _keyCtrl.text.trim(),
        model: _modelCtrl.text.trim(),
        temperature: 0,
        tools: const [],
      );
      final ids = await client.listModels();
      if (!mounted) return;
      if (ids.isEmpty) {
        messenger.showSnackBar(const SnackBar(content: Text('接口返回了空模型列表')));
        return;
      }
      final picked = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('模型 ID'),
          content: SizedBox(
            width: double.maxFinite,
            height: 380,
            child: ListView.builder(
              itemCount: ids.length,
              itemBuilder: (ctx, i) => ListTile(
                dense: true,
                title: Text(ids[i], style: const TextStyle(fontSize: 13)),
                onTap: () => Navigator.pop(ctx, ids[i]),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
          ],
        ),
      );
      if (picked != null && mounted) {
        setState(() => _modelCtrl.text = picked);
        _autoSave();
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('获取模型失败：$e')));
      }
    }
  }

  /// 发送 hi 测试模型连通性，HTTP 200 即成功。
  Future<void> _testModel() async {
    final url = _baseCtrl.text.trim();
    final model = _modelCtrl.text.trim();
    if (url.isEmpty || model.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先填写接口地址和模型')));
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('正在发送 hi 测试…')));
    try {
      final client = LlmClient(
        baseUrl: url,
        apiKey: _keyCtrl.text.trim(),
        model: model,
        temperature: 0,
        tools: const [],
      );
      final result = await client.testChat();
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(result)));
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('测试失败：$e')));
      }
    }
  }

  Future<void> _requestFullAccess() async {
    await PermissionService.requestFullAccess();
    await _checkFileAccess();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _fileAccessGranted ? '已获得全部文件访问权限' : '请在系统页面中开启「允许访问所有文件」',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.shiyi,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(title: const Text('设置')),
          body: ListView(
            children: [
              _section('模型 API（OpenAI 兼容）'),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.auto_awesome_motion, size: 24),
                        const SizedBox(width: 16),
                        const Text(
                          '模型预设',
                          style: TextStyle(fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 150),
                          child: DropdownButton<String>(
                            value: _presetName,
                            isExpanded: true,
                            hint: const Text(
                              '选择预设',
                              overflow: TextOverflow.ellipsis,
                            ),
                            underline: const SizedBox.shrink(),
                            items: [
                              for (final profile in _allProfiles)
                                DropdownMenuItem(
                                  value: profile.name,
                                  child: Text(
                                    profile.name,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              const DropdownMenuItem(
                                value: '__new__',
                                child: Text('＋ 新建自定义接口（OpenAI 协议）'),
                              ),
                            ],
                            onChanged: (v) {
                              if (v == '__new__') {
                                _createCustomProfile();
                                return;
                              }
                              final profile = _allProfiles.firstWhere(
                                (p) => p.name == v,
                              );
                              _applyPreset(profile);
                              _autoSave();
                            },
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          icon: const Icon(Icons.save_outlined, size: 20),
                          tooltip: '保存配置',
                          onPressed: _saveCurrentProfile,
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 20),
                          tooltip: '删除配置',
                          onPressed: _deleteCurrentProfile,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    const SizedBox(width: 40),
                    Expanded(
                      child: Text(
                        '一键切换，密钥自动带出',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              ListTile(
                leading: const Icon(Icons.link),
                title: const Text('接口地址'),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: TextField(
                    controller: _baseCtrl,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: 'https://api.deepseek.com/v1',
                    ),
                    onChanged: (_) => _autoSave(),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.key),
                title: const Text('API 密钥'),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: TextField(
                    controller: _keyCtrl,
                    obscureText: !_showKey,
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      hintText: _keyHint,
                      suffixIcon: IconButton(
                        icon: Icon(
                          _showKey
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                        ),
                        onPressed: () => setState(() => _showKey = !_showKey),
                        tooltip: _showKey ? '隐藏密钥' : '显示密钥',
                      ),
                    ),
                    onChanged: (_) => _autoSave(),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.model_training),
                title: const Text('模型'),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: TextField(
                    controller: _modelCtrl,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: '例如 deepseek-chat',
                    ),
                    onChanged: (_) => _autoSave(),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _fetchModels,
                        icon: const Icon(Icons.list_alt, size: 18),
                        label: const Text('获取模型 ID'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _testModel,
                        icon: const Icon(Icons.wifi_tethering, size: 18),
                        label: const Text('测试连接'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(),
              _section('能力'),
              SwitchListTile(
                secondary: const Icon(Icons.hub_outlined),
                title: const Text('启用工具调用'),
                subtitle: const Text(
                  '拾忆 可调用 save_memory（保存记忆）/ search_memory（搜索记忆）/ run_skill（运行技能）工具',
                ),
                value: _tools,
                onChanged: (v) {
                  setState(() => _tools = v);
                  _autoSave();
                },
              ),
              SwitchListTile(
                secondary: const Icon(Icons.memory_outlined),
                title: const Text('启用长期记忆'),
                subtitle: const Text('对话前自动注入相关记忆与技能上下文'),
                value: _memory,
                onChanged: (v) {
                  setState(() => _memory = v);
                  _autoSave();
                },
              ),
              SwitchListTile(
                secondary: const Icon(Icons.auto_awesome),
                title: const Text('自动沉淀记忆'),
                subtitle: const Text('每轮对话后自动提炼重要信息存入长期记忆'),
                value: _autoLearn,
                onChanged: (v) {
                  setState(() => _autoLearn = v);
                  _autoSave();
                },
              ),
              const Divider(),
              _section('上下文'),
              ListTile(
                leading: const Icon(Icons.compress_outlined),
                title: const Text('上下文上限'),
                subtitle: const Text('会话上下文最大字符数（最高 100 万）'),
                trailing: SizedBox(
                  width: 110,
                  child: TextFormField(
                    initialValue: _contextLimit.toString(),
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.right,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                    ),
                    onChanged: (v) {
                      final n = int.tryParse(v);
                      if (n != null && n > 0) {
                        setState(
                          () => _contextLimit = n.clamp(10000, 1000000),
                        );
                        _autoSave();
                      }
                    },
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.filter_alt_outlined),
                title: const Text('压缩阈值'),
                subtitle: const Text('上下文达到上下文上限的该百分比时触发手动/自动压缩'),
                trailing: SizedBox(
                  width: 120,
                  child: TextFormField(
                    initialValue: _compressThresholdPercent.toStringAsFixed(0),
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    textAlign: TextAlign.right,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      suffixText: '%',
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                    ),
                    onChanged: (v) {
                      final n = double.tryParse(v);
                      if (n != null && n > 0) {
                        setState(
                          () =>
                              _compressThresholdPercent = n.clamp(1, 100),
                        );
                        _autoSave();
                      }
                    },
                  ),
                ),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.auto_fix_high),
                title: const Text('自动压缩'),
                subtitle: const Text('上下文超过压缩阈值时自动总结压缩历史'),
                value: _autoCompress,
                onChanged: (v) {
                  setState(() => _autoCompress = v);
                  _autoSave();
                },
              ),
              const Divider(),
              _section('外观'),
              ListTile(
                leading: const Icon(Icons.palette_outlined),
                title: const Text('主题模式'),
                subtitle: const Text('macOS 风格，浅色 / 深色可随时切换'),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'light',
                      label: Text('浅色'),
                      icon: Icon(Icons.light_mode_outlined),
                    ),
                    ButtonSegment(
                      value: 'dark',
                      label: Text('深色'),
                      icon: Icon(Icons.dark_mode_outlined),
                    ),
                    ButtonSegment(
                      value: 'system',
                      label: Text('跟随系统'),
                      icon: Icon(Icons.brightness_auto_outlined),
                    ),
                  ],
                  selected: {_themeMode},
                  onSelectionChanged: (v) {
                    setState(() => _themeMode = v.first);
                    _autoSave();
                  },
                ),
              ),
              const Divider(),
              _section('语音'),
              ListTile(
                leading: const Icon(Icons.speed),
                title: const Text('语速'),
                trailing: Text(
                  _ttsRate.toStringAsFixed(1),
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                ),
                subtitle: Slider(
                  value: _ttsRate,
                  min: 0.5,
                  max: 1.5,
                  divisions: 10,
                  label: _ttsRate.toStringAsFixed(1),
                  onChanged: (v) {
                    setState(() => _ttsRate = v);
                    _autoSave();
                  },
                ),
              ),
              const Divider(),
              _section('高级'),
              ListTile(
                leading: const Icon(Icons.thermostat),
                title: const Text('温度'),
                trailing: Text(
                  _temperature.toStringAsFixed(2),
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                ),
                subtitle: Slider(
                  value: _temperature,
                  min: 0,
                  max: 2,
                  divisions: 20,
                  label: _temperature.toStringAsFixed(2),
                  onChanged: (v) {
                    setState(() => _temperature = v);
                    _autoSave();
                  },
                ),
              ),
              ListTile(
                leading: const Icon(Icons.folder_open_outlined),
                title: const Text('文件访问权限'),
                subtitle: Text(
                  _fileAccessGranted
                      ? '已开启，终端可读写手机存储'
                      : '未开启，终端读写 /sdcard 会被拒绝',
                ),
                trailing: _fileAccessGranted
                    ? const Icon(Icons.check_circle, color: Color(0xFF28C840))
                    : const Icon(Icons.chevron_right),
                onTap: _requestFullAccess,
              ),
              ListTile(
                leading: const Icon(Icons.psychology_outlined),
                title: const Text('系统提示词'),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: TextField(
                    controller: _promptCtrl,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: '（留空使用默认拾忆人设）',
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonalIcon(
                    onPressed: _savePrompt,
                    icon: const Icon(Icons.save_outlined, size: 16),
                    label: const Text('保存提示词'),
                  ),
                ),
              ),
              const SizedBox(height: 32),
              Center(
                child: Text(
                  '拾忆 v0.1.0 · Flutter 原生',
                  style: theme.textTheme.bodySmall!.copyWith(
                    color: theme.hintColor,
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }

  Widget _section(String t) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(
      t,
      style: TextStyle(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.bold,
        fontSize: 13,
        letterSpacing: 1,
      ),
    ),
  );
}
