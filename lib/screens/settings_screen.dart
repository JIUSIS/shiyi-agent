import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/model_presets.dart';
import '../core/models.dart';
import '../services/llm_client.dart';
import '../services/permission_service.dart';
import '../services/settings_service.dart';
import '../services/update_service.dart';
import '../widgets/ios_style.dart';
import 'about_screen.dart';
import 'log_screen.dart';

const _iosBlue = Color(0xFF0A84FF);
const _iosGreen = Color(0xFF34C759);
const _iosRed = Color(0xFFFF3B30);
const _iosOrange = Color(0xFFFF9500);
const _iosPurple = Color(0xFFAF52DE);
const _iosIndigo = Color(0xFF5856D6);
const _iosPink = Color(0xFFFF2D55);
const _iosTeal = Color(0xFF64D2FF);
const _iosGray = Color(0xFF8E8E93);

/// iOS Inset Grouped 页面底色：浅色浅灰分组底、深色纯黑。
Color _iosGroupedBackground(bool dark) =>
    dark ? const Color(0xFF000000) : const Color(0xFFF2F2F7);

/// iOS Inset Grouped 卡片底色：浅色纯白、深色深灰。
BoxDecoration _iosSectionDecoration(bool dark) => BoxDecoration(
  color: dark ? const Color(0xFF1C1C1E) : const Color(0xFFFFFFFF),
  borderRadius: BorderRadius.circular(10),
);

bool _isDark(BuildContext context, String themeMode) {
  final platformDark =
      MediaQuery.platformBrightnessOf(context) == Brightness.dark;
  return themeMode == 'dark' || (themeMode == 'system' && platformDark);
}

void _open(BuildContext context, Widget page) {
  Navigator.push(
    context,
    PageRouteBuilder<void>(
      opaque: false,
      pageBuilder: (_, _, _) => page,
      transitionDuration: const Duration(milliseconds: 260),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      transitionsBuilder: (_, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

Future<void> _showIosAlert(BuildContext context, String title, String message) {
  return showIosFadeDialog<void>(
    context: context,
    builder: (ctx) => CupertinoAlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: () => Navigator.pop(ctx),
          child: const Text('好'),
        ),
      ],
    ),
  );
}

Future<T> _runWithLoading<T>(
  BuildContext context,
  String message,
  Future<T> Function() task,
) async {
  FocusScope.of(context).unfocus();
  var open = true;
  unawaited(
    showIosFadeDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => CupertinoAlertDialog(
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CupertinoActivityIndicator(),
            const SizedBox(width: 14),
            Flexible(child: Text(message)),
          ],
        ),
      ),
    ).whenComplete(() => open = false),
  );
  try {
    return await task();
  } finally {
    if (context.mounted && open) {
      Navigator.of(context, rootNavigator: true).pop();
    }
  }
}

/// 设置根页：iOS 风格 Inset Grouped 分组列表，点击行进入独立二级页。
class SettingsScreen extends StatelessWidget {
  final ShiyiState shiyi;
  const SettingsScreen({super.key, required this.shiyi});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: shiyi,
      builder: (context, _) {
        final dark = _isDark(context, shiyi.settings.themeMode);
        final s = shiyi.settings;
        return CupertinoTheme(
          data: CupertinoThemeData(
            brightness: dark ? Brightness.dark : Brightness.light,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: CupertinoPageScaffold(
              backgroundColor: _iosGroupedBackground(dark),
              child: SafeArea(
                bottom: false,
                child: ColoredBox(
                  color: _iosGroupedBackground(dark),
                  child: ListView(
                    padding: const EdgeInsets.only(top: 8, bottom: 36),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                        child: Text(
                          '设置',
                          style: TextStyle(
                            fontSize: 34,
                            fontWeight: FontWeight.w700,
                            color: dark
                                ? CupertinoColors.white
                                : CupertinoColors.black,
                          ),
                        ),
                      ),
                      CupertinoListSection.insetGrouped(
                        decoration: _iosSectionDecoration(dark),
                        backgroundColor: _iosGroupedBackground(dark),
                        header: const Text('模型'),
                        children: [
                          _navTile(
                            icon: CupertinoIcons.square_stack_3d_up_fill,
                            color: _iosBlue,
                            title: '模型 API',
                            subtitle: s.model.isEmpty
                                ? '接口地址 / 密钥 / 模型与预设'
                                : '${s.model} · ${_shortUrl(s.baseUrl)}',
                            onTap: () =>
                                _open(context, _ApiSectionPage(shiyi: shiyi)),
                          ),
                          _navTile(
                            icon: CupertinoIcons.photo_fill,
                            color: _iosPurple,
                            title: '视觉模型',
                            subtitle: s.visionEnabled ? '已开启，支持辅助看图' : '已关闭',
                            onTap: () => _open(
                              context,
                              _VisionSectionPage(shiyi: shiyi),
                            ),
                          ),
                        ],
                      ),
                      CupertinoListSection.insetGrouped(
                        decoration: _iosSectionDecoration(dark),
                        backgroundColor: _iosGroupedBackground(dark),
                        header: const Text('对话'),
                        children: [
                          _navTile(
                            icon: CupertinoIcons.chat_bubble_2_fill,
                            color: _iosIndigo,
                            title: '对话与功能',
                            subtitle: '工具调用 / 记忆 / 通知 / 回车发送',
                            onTap: () => _open(
                              context,
                              _InteractionSectionPage(shiyi: shiyi),
                            ),
                          ),
                          _navTile(
                            icon: CupertinoIcons.square_on_square,
                            color: _iosTeal,
                            title: '上下文',
                            subtitle:
                                '${_tokenLabel(s.contextLimit)} · 自动压缩${s.autoCompress ? '开' : '关'}',
                            onTap: () => _open(
                              context,
                              _ContextSectionPage(shiyi: shiyi),
                            ),
                          ),
                        ],
                      ),
                      CupertinoListSection.insetGrouped(
                        decoration: _iosSectionDecoration(dark),
                        backgroundColor: _iosGroupedBackground(dark),
                        header: const Text('通用'),
                        children: [
                          _navTile(
                            icon: CupertinoIcons.paintbrush_fill,
                            color: _iosPurple,
                            title: '外观',
                            subtitle: _themeLabel(s.themeMode),
                            onTap: () => _open(
                              context,
                              _AppearanceSectionPage(shiyi: shiyi),
                            ),
                          ),
                          _navTile(
                            icon: CupertinoIcons.speaker_3_fill,
                            color: _iosPink,
                            title: '语音',
                            subtitle: '朗读语速 ${s.ttsRate.toStringAsFixed(1)}',
                            onTap: () =>
                                _open(context, _VoiceSectionPage(shiyi: shiyi)),
                          ),
                          _navTile(
                            icon: CupertinoIcons.slider_horizontal_3,
                            color: _iosGray,
                            title: '高级',
                            subtitle: '温度 / 文件权限 / 系统提示词',
                            onTap: () => _open(
                              context,
                              _AdvancedSectionPage(shiyi: shiyi),
                            ),
                          ),
                        ],
                      ),
                      CupertinoListSection.insetGrouped(
                        decoration: _iosSectionDecoration(dark),
                        backgroundColor: _iosGroupedBackground(dark),
                        header: const Text('支持'),
                        children: [
                          _navTile(
                            icon: CupertinoIcons.info_circle_fill,
                            color: _iosBlue,
                            title: '关于',
                            subtitle: '版本、检查更新与功能特性',
                            onTap: () =>
                                _open(context, AboutScreen(shiyi: shiyi)),
                          ),
                          _navTile(
                            icon: CupertinoIcons.doc_text_fill,
                            color: _iosGray,
                            title: '日志',
                            subtitle: '查看智能体运行与错误日志',
                            onTap: () => _open(context, const LogScreen()),
                          ),
                        ],
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 18),
                        child: FutureBuilder<String>(
                          future: UpdateService.currentVersion(),
                          builder: (context, snap) => Center(
                            child: Text(
                              '拾忆 v${snap.data ?? UpdateService.appVersion} · Flutter 原生',
                              style: TextStyle(
                                fontSize: 13,
                                color: dark
                                    ? CupertinoColors.white.withValues(
                                        alpha: .6,
                                      )
                                    : CupertinoColors.black.withValues(
                                        alpha: .55,
                                      ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

Widget _navTile({
  required IconData icon,
  required Color color,
  required String title,
  required String subtitle,
  required VoidCallback onTap,
}) {
  return CupertinoListTile(
    leading: _IosIconTile(icon: icon, color: color),
    title: Text(title),
    subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
    trailing: const CupertinoListTileChevron(),
    onTap: onTap,
  );
}

String _shortUrl(String url) {
  var trimmed = url.trim();
  trimmed = trimmed.replaceFirst(RegExp(r'^https?://'), '');
  trimmed = trimmed.replaceFirst(RegExp(r'/$'), '');
  return trimmed.isEmpty ? '未设置接口' : trimmed;
}

String _tokenLabel(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(0)}K';
  return '$n';
}

String _themeLabel(String mode) {
  switch (mode) {
    case 'light':
      return '浅色';
    case 'dark':
      return '深色';
    default:
      return '跟随系统';
  }
}

/// 二级设置页外壳：iOS 导航栏 + Inset Grouped 列表。
class _IosSettingsPage extends StatelessWidget {
  final String title;
  final ShiyiState shiyi;
  final List<Widget> children;
  const _IosSettingsPage({
    required this.title,
    required this.shiyi,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: shiyi,
      builder: (context, _) {
        final dark = _isDark(context, shiyi.settings.themeMode);
        return CupertinoTheme(
          data: CupertinoThemeData(
            brightness: dark ? Brightness.dark : Brightness.light,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: CupertinoPageScaffold(
              navigationBar: CupertinoNavigationBar(middle: Text(title)),
              backgroundColor: _iosGroupedBackground(dark),
              child: SafeArea(
                bottom: false,
                child: ColoredBox(
                  color: _iosGroupedBackground(dark),
                  child: ListView(
                    padding: const EdgeInsets.only(top: 4, bottom: 36),
                    children: children,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 设置防抖保存：停止输入 600ms 后写入一次设置。
class _DebouncedSave {
  _DebouncedSave(this.shiyi, this._build, {this.after});

  final ShiyiState shiyi;
  final AppSettings Function() _build;
  final Future<void> Function()? after;
  Timer? _timer;

  /// 是否有尚未落盘的编辑。
  bool get hasPending => _timer != null;

  void schedule() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 600), () async {
      _timer = null;
      await shiyi.updateSettings(_build());
      await after?.call();
    });
  }

  /// 立即保存未落盘的编辑（页面 dispose 时调用，防快速返回丢改动）。
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    await shiyi.updateSettings(_build());
    await after?.call();
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}

class _ApiSectionPage extends StatefulWidget {
  final ShiyiState shiyi;
  const _ApiSectionPage({required this.shiyi});

  @override
  State<_ApiSectionPage> createState() => _ApiSectionPageState();
}

class _ApiSectionPageState extends State<_ApiSectionPage> {
  late final TextEditingController _baseCtrl;
  late final TextEditingController _keyCtrl;
  late final TextEditingController _modelCtrl;
  late final _DebouncedSave _save;
  late String _protocol;
  String _keyHint = 'sk-...';
  String? _presetName;
  bool _showKey = false;
  bool _profilesLoaded = false;
  List<ApiProfile> _profiles = [];

  @override
  void initState() {
    super.initState();
    final s = widget.shiyi.settings;
    _baseCtrl = TextEditingController(text: s.baseUrl);
    _keyCtrl = TextEditingController(text: s.apiKey);
    _modelCtrl = TextEditingController(text: s.model);
    _protocol = s.apiProtocol;
    for (final preset in modelPresets) {
      if (preset.baseUrl == s.baseUrl.trim()) {
        _presetName = preset.name;
        _keyHint = preset.keyHint;
        _protocol = preset.apiProtocol;
        break;
      }
    }
    _save = _DebouncedSave(
      widget.shiyi,
      () => widget.shiyi.settings.copyWith(
        baseUrl: _currentBaseUrl().isEmpty
            ? 'https://api.deepseek.com/v1'
            : _currentBaseUrl(),
        apiKey: _keyCtrl.text.trim(),
        model: _modelCtrl.text.trim(),
        apiProtocol: _protocol,
      ),
      after: _persistCurrentProfile,
    );
    _loadProfiles();
  }

  @override
  void dispose() {
    // 先把未落盘编辑保存（flush 的 _build 会读 controller.text），再释放 controller。
    if (_save.hasPending) unawaited(_save.flush());
    _save.dispose();
    _baseCtrl.dispose();
    _keyCtrl.dispose();
    _modelCtrl.dispose();
    super.dispose();
  }

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
          apiProtocol: p.apiProtocol,
        ),
      );
    }
    for (final p in _profiles) {
      if (modelPresets.every((m) => m.name != p.name)) all.add(p);
    }
    return all;
  }

  bool get _isBuiltinPreset =>
      _presetName != null && modelPresets.any((p) => p.name == _presetName);

  /// 自定义 OpenAI 兼容接口自动补 /v1；内置预设和 Anthropic 原样保留。
  String _currentBaseUrl() {
    final raw = _baseCtrl.text.trim();
    if (_isBuiltinPreset || _protocol != 'openai') return raw;
    return normalizeOpenAiBaseUrl(raw);
  }

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
      _protocol = profile.apiProtocol;
    });
    _baseCtrl.text = profile.baseUrl;
    _keyCtrl.text = profile.apiKey;
    _modelCtrl.text = profile.model;
    final suggested = preset?.suggestedMaxTokens;
    if (suggested != null &&
        suggested != widget.shiyi.settings.maxOutputTokens) {
      unawaited(
        widget.shiyi.updateSettings(
          widget.shiyi.settings.copyWith(
            baseUrl: profile.baseUrl,
            model: profile.model,
            apiProtocol: profile.apiProtocol,
            maxOutputTokens: suggested,
          ),
        ),
      );
    }
  }

  Future<void> _persistCurrentProfile() async {
    if (!mounted) return;
    if (_presetName == null) return;
    if (!_profilesLoaded) {
      _profiles = await SettingsService().loadProfiles();
      _profilesLoaded = true;
    }
    if (!mounted) return;
    final saved = {for (final p in _profiles) p.name: p};
    saved[_presetName!] = ApiProfile(
      name: _presetName!,
      baseUrl: _currentBaseUrl(),
      apiKey: _keyCtrl.text.trim(),
      model: _modelCtrl.text.trim(),
      apiProtocol: _protocol,
    );
    _profiles = saved.values.toList();
    await SettingsService().saveProfiles(_profiles);
  }

  Future<void> _pickProfile() async {
    final all = _allProfiles;
    FocusScope.of(context).unfocus();
    final picked = await showIosFadeModalPopup<String>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('模型预设'),
        actions: [
          for (final profile in all)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(ctx, profile.name),
              child: Text(
                profile.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    FocusScope.of(context).unfocus();
    final profile = all.firstWhere((p) => p.name == picked);
    _applyPreset(profile);
    _save.schedule();
  }

  void _setProtocol(String v) {
    if (_protocol == v) return;
    FocusScope.of(context).unfocus();
    setState(() => _protocol = v);
    unawaited(
      widget.shiyi.updateSettings(
        widget.shiyi.settings.copyWith(apiProtocol: v),
      ),
    );
    _save.schedule();
  }

  Future<void> _createCustomProfile() async {
    final nameCtrl = TextEditingController();
    final urlCtrl = TextEditingController();
    final keyCtrl = TextEditingController();
    final modelCtrl = TextEditingController();
    var dialogProtocol = 'openai';
    final result =
        await showIosFadeDialog<
          ({
            String name,
            String baseUrl,
            String apiKey,
            String model,
            String apiProtocol,
          })
        >(
          context: context,
          builder: (ctx) => StatefulBuilder(
            builder: (ctx, setDialogState) => CupertinoAlertDialog(
              title: const Text('新建自定义接口'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CupertinoTextField(
                    controller: nameCtrl,
                    autofocus: true,
                    placeholder: '名称',
                  ),
                  const SizedBox(height: 8),
                  CupertinoButton(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    onPressed: () =>
                        setDialogState(() => dialogProtocol = 'openai'),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text('OpenAI 兼容', textAlign: TextAlign.left),
                        ),
                        if (dialogProtocol == 'openai')
                          const Icon(
                            CupertinoIcons.checkmark_circle_fill,
                            color: CupertinoColors.activeBlue,
                          ),
                      ],
                    ),
                  ),
                  CupertinoButton(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    onPressed: () =>
                        setDialogState(() => dialogProtocol = 'anthropic'),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Anthropic Messages',
                            textAlign: TextAlign.left,
                          ),
                        ),
                        if (dialogProtocol == 'anthropic')
                          const Icon(
                            CupertinoIcons.checkmark_circle_fill,
                            color: CupertinoColors.activeBlue,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  CupertinoTextField(
                    controller: urlCtrl,
                    placeholder: '接口地址，例如 https://api.anthropic.com',
                  ),
                  const SizedBox(height: 8),
                  CupertinoTextField(
                    controller: keyCtrl,
                    obscureText: true,
                    placeholder: 'API 密钥',
                  ),
                  const SizedBox(height: 8),
                  CupertinoTextField(
                    controller: modelCtrl,
                    placeholder: '模型，例如 claude-sonnet-4-5',
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
                    final name = nameCtrl.text.trim();
                    final url = urlCtrl.text.trim();
                    if (name.isEmpty || url.isEmpty) {
                      _showIosAlert(ctx, '提示', '名称和接口地址不能为空');
                      return;
                    }
                    Navigator.pop(ctx, (
                      name: name,
                      baseUrl: url,
                      apiKey: keyCtrl.text.trim(),
                      model: modelCtrl.text.trim(),
                      apiProtocol: dialogProtocol,
                    ));
                  },
                  child: const Text('保存'),
                ),
              ],
            ),
          ),
        );
    if (result == null || !mounted) return;
    final baseUrl = result.apiProtocol == 'openai'
        ? normalizeOpenAiBaseUrl(result.baseUrl)
        : LlmClient.normalizeAnthropicBaseUrl(result.baseUrl.trim());
    final dup =
        modelPresets.any((p) => p.name == result.name) ||
        _profiles.any((p) => p.name == result.name);
    if (dup) {
      await _showIosAlert(context, '提示', '该名称已存在，换个名字');
      return;
    }
    setState(() {
      _profiles.add(
        ApiProfile(
          name: result.name,
          baseUrl: baseUrl,
          apiKey: result.apiKey,
          model: result.model,
          apiProtocol: result.apiProtocol,
        ),
      );
      _presetName = result.name;
      _keyHint = 'sk-...';
      _baseCtrl.text = baseUrl;
      _keyCtrl.text = result.apiKey;
      _modelCtrl.text = result.model;
      _protocol = result.apiProtocol;
    });
    unawaited(
      widget.shiyi.updateSettings(
        widget.shiyi.settings.copyWith(
          baseUrl: baseUrl,
          model: result.model,
          apiProtocol: result.apiProtocol,
        ),
      ),
    );
    _save.schedule();
  }

  Future<void> _saveCurrentProfile() async {
    final nameCtrl = TextEditingController(text: _presetName ?? '自定义配置');
    final name = await showIosFadeDialog<String>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('保存 API 配置'),
        content: CupertinoTextField(
          controller: nameCtrl,
          autofocus: true,
          placeholder: '配置名称',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(ctx, nameCtrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    if (name != _presetName && _profiles.any((p) => p.name == name)) {
      await _showIosAlert(context, '提示', '该名称已存在，换个名字');
      return;
    }
    final baseUrl = _currentBaseUrl();
    setState(() {
      final saved = {for (final p in _profiles) p.name: p};
      saved[name] = ApiProfile(
        name: name,
        baseUrl: baseUrl,
        apiKey: _keyCtrl.text.trim(),
        model: _modelCtrl.text.trim(),
        apiProtocol: _protocol,
      );
      _profiles = saved.values.toList();
      _presetName = name;
      _keyHint = 'sk-...';
      _baseCtrl.text = baseUrl;
    });
    await SettingsService().saveProfiles(_profiles);
    if (mounted) {
      await _showIosAlert(context, '完成', '配置「$name」已保存');
    }
  }

  Future<void> _deleteCurrentProfile() async {
    if (_presetName == null) {
      await _showIosAlert(context, '提示', '当前没有选中的配置');
      return;
    }
    final isBuiltin = modelPresets.any((p) => p.name == _presetName);
    if (isBuiltin) {
      await _showIosAlert(context, '提示', '内置预设不可删除');
      return;
    }
    final name = _presetName!;
    final ok = await showIosFadeDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('删除配置'),
        content: Text('确定删除「$name」吗？'),
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
    setState(() {
      _profiles.removeWhere((p) => p.name == name);
      _presetName = null;
      _keyHint = 'sk-...';
    });
    await SettingsService().saveProfiles(_profiles);
    if (mounted) {
      await _showIosAlert(context, '完成', '配置「$name」已删除');
    }
  }

  Future<void> _fetchModels() async {
    FocusScope.of(context).unfocus();
    final url = _currentBaseUrl();
    if (url != _baseCtrl.text.trim()) {
      setState(() => _baseCtrl.text = url);
    }
    if (url.isEmpty) {
      await _showIosAlert(context, '提示', '请先填写接口地址');
      return;
    }
    try {
      final ids = await _runWithLoading<List<String>>(
        context,
        '正在获取模型 ID，请稍后…',
        () async {
          final client = LlmClient(
            baseUrl: url,
            apiKey: _keyCtrl.text.trim(),
            model: _modelCtrl.text.trim(),
            protocol: _protocol,
            temperature: 0,
            tools: const [],
          );
          return client.listModels();
        },
      );
      if (!mounted) return;
      if (ids.isEmpty) {
        await _showIosAlert(context, '提示', '接口返回了空模型列表');
        return;
      }
      final picked = await showIosFadeModalPopup<String>(
        context: context,
        builder: (ctx) => CupertinoActionSheet(
          title: const Text('模型 ID'),
          actions: [
            for (final id in ids)
              CupertinoActionSheetAction(
                onPressed: () => Navigator.pop(ctx, id),
                child: Text(id, maxLines: 2, overflow: TextOverflow.ellipsis),
              ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ),
      );
      if (picked != null && mounted) {
        setState(() => _modelCtrl.text = picked);
        _save.schedule();
      }
    } catch (e) {
      if (mounted) await _showIosAlert(context, '获取模型失败', '$e');
    }
  }

  Future<void> _testModel() async {
    FocusScope.of(context).unfocus();
    final url = _currentBaseUrl();
    if (url != _baseCtrl.text.trim()) {
      setState(() => _baseCtrl.text = url);
    }
    final model = _modelCtrl.text.trim();
    if (url.isEmpty || model.isEmpty) {
      await _showIosAlert(context, '提示', '请先填写接口地址和模型');
      return;
    }
    try {
      final result = await _runWithLoading<String>(
        context,
        '正在测试连接，请稍后…',
        () async {
          final client = LlmClient(
            baseUrl: url,
            apiKey: _keyCtrl.text.trim(),
            model: model,
            protocol: _protocol,
            temperature: 0,
            tools: const [],
          );
          return client.testChat();
        },
      );
      if (mounted) await _showIosAlert(context, '测试结果', result);
    } catch (e) {
      if (mounted) await _showIosAlert(context, '测试失败', '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return _IosSettingsPage(
      shiyi: widget.shiyi,
      title: '模型 API',
      children: [
        CupertinoListSection.insetGrouped(
          decoration: _iosSectionDecoration(
            _isDark(context, widget.shiyi.settings.themeMode),
          ),
          backgroundColor: _iosGroupedBackground(
            _isDark(context, widget.shiyi.settings.themeMode),
          ),
          header: const Text('接口配置'),
          children: [
            CupertinoListTile(
              leading: _IosIconTile(
                icon: CupertinoIcons.square_stack_3d_up_fill,
                color: _iosIndigo,
              ),
              title: const Text('模型预设'),
              subtitle: Text(
                _presetName == null ? '选择预设或新建自定义接口' : '当前：$_presetName',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const CupertinoListTileChevron(),
              onTap: _pickProfile,
            ),
            _IosTextFieldTile(
              icon: CupertinoIcons.link,
              color: _iosBlue,
              title: '接口地址',
              controller: _baseCtrl,
              placeholder: 'https://api.deepseek.com/v1',
              onChanged: (_) => _save.schedule(),
            ),
            _IosSecretFieldTile(
              icon: CupertinoIcons.lock_fill,
              color: _iosOrange,
              title: 'API 密钥',
              controller: _keyCtrl,
              placeholder: _keyHint,
              obscure: !_showKey,
              onToggleVisibility: () => setState(() => _showKey = !_showKey),
              onChanged: (_) => _save.schedule(),
            ),
            _IosTextFieldTile(
              icon: CupertinoIcons.bolt_fill,
              color: _iosGreen,
              title: '模型',
              controller: _modelCtrl,
              placeholder: '例如 deepseek-chat',
              onChanged: (_) => _save.schedule(),
            ),
          ],
        ),
        CupertinoListSection.insetGrouped(
          decoration: _iosSectionDecoration(
            _isDark(context, widget.shiyi.settings.themeMode),
          ),
          backgroundColor: _iosGroupedBackground(
            _isDark(context, widget.shiyi.settings.themeMode),
          ),
          header: const Text('协议'),
          children: [
            CupertinoListTile(
              leading: _IosIconTile(
                icon: CupertinoIcons.chat_bubble_2_fill,
                color: _iosBlue,
              ),
              title: const Text('OpenAI 兼容'),
              subtitle: const Text('OpenAI / DeepSeek / 各类兼容网关'),
              trailing: _protocol == 'openai'
                  ? const Icon(
                      CupertinoIcons.checkmark_circle_fill,
                      color: CupertinoColors.activeBlue,
                    )
                  : null,
              onTap: () => _setProtocol('openai'),
            ),
            CupertinoListTile(
              leading: _IosIconTile(
                icon: CupertinoIcons.sparkles,
                color: _iosOrange,
              ),
              title: const Text('Anthropic Messages'),
              subtitle: const Text('Claude 系列原生 Messages API'),
              trailing: _protocol == 'anthropic'
                  ? const Icon(
                      CupertinoIcons.checkmark_circle_fill,
                      color: CupertinoColors.activeBlue,
                    )
                  : null,
              onTap: () => _setProtocol('anthropic'),
            ),
          ],
        ),
        CupertinoListSection.insetGrouped(
          decoration: _iosSectionDecoration(
            _isDark(context, widget.shiyi.settings.themeMode),
          ),
          backgroundColor: _iosGroupedBackground(
            _isDark(context, widget.shiyi.settings.themeMode),
          ),
          header: const Text('操作'),
          children: [
            CupertinoListTile(
              leading: _IosIconTile(
                icon: CupertinoIcons.list_bullet,
                color: _iosBlue,
              ),
              title: const Text(
                '获取模型 ID',
                style: TextStyle(color: CupertinoColors.activeBlue),
              ),
              trailing: const CupertinoListTileChevron(),
              onTap: _fetchModels,
            ),
            CupertinoListTile(
              leading: _IosIconTile(
                icon: CupertinoIcons.antenna_radiowaves_left_right,
                color: _iosGreen,
              ),
              title: const Text(
                '测试连接',
                style: TextStyle(color: CupertinoColors.activeBlue),
              ),
              trailing: const CupertinoListTileChevron(),
              onTap: _testModel,
            ),
          ],
        ),
        CupertinoListSection.insetGrouped(
          decoration: _iosSectionDecoration(
            _isDark(context, widget.shiyi.settings.themeMode),
          ),
          backgroundColor: _iosGroupedBackground(
            _isDark(context, widget.shiyi.settings.themeMode),
          ),
          header: const Text('配置管理'),
          children: [
            CupertinoListTile(
              leading: _IosIconTile(
                icon: CupertinoIcons.plus_circle_fill,
                color: _iosGreen,
              ),
              title: const Text('新建接口'),
              subtitle: const Text('添加自定义 OpenAI / Anthropic 接口'),
              trailing: const CupertinoListTileChevron(),
              onTap: _createCustomProfile,
            ),
            CupertinoListTile(
              leading: _IosIconTile(
                icon: CupertinoIcons.checkmark_circle_fill,
                color: _iosBlue,
              ),
              title: const Text('保存当前配置'),
              subtitle: const Text('把当前接口 / 密钥 / 模型保存为命名配置'),
              trailing: const CupertinoListTileChevron(),
              onTap: _saveCurrentProfile,
            ),
            CupertinoListTile(
              leading: _IosIconTile(
                icon: CupertinoIcons.trash_fill,
                color: _iosRed,
              ),
              title: const Text(
                '删除当前配置',
                style: TextStyle(color: CupertinoColors.systemRed),
              ),
              subtitle: const Text('删除选中的自定义接口配置'),
              trailing: const CupertinoListTileChevron(),
              onTap: _deleteCurrentProfile,
            ),
          ],
        ),
      ],
    );
  }
}

class _VisionSectionPage extends StatefulWidget {
  final ShiyiState shiyi;
  const _VisionSectionPage({required this.shiyi});

  @override
  State<_VisionSectionPage> createState() => _VisionSectionPageState();
}

class _VisionSectionPageState extends State<_VisionSectionPage> {
  late bool _enabled;
  late final TextEditingController _urlCtrl;
  late final TextEditingController _keyCtrl;
  late final TextEditingController _modelCtrl;
  bool _showKey = false;
  late final _DebouncedSave _save;

  @override
  void initState() {
    super.initState();
    final s = widget.shiyi.settings;
    _enabled = s.visionEnabled;
    _urlCtrl = TextEditingController(text: s.visionBaseUrl);
    _keyCtrl = TextEditingController(text: s.visionApiKey);
    _modelCtrl = TextEditingController(text: s.visionModel);
    _save = _DebouncedSave(
      widget.shiyi,
      () => widget.shiyi.settings.copyWith(
        visionEnabled: _enabled,
        visionBaseUrl: _urlCtrl.text.trim(),
        visionApiKey: _keyCtrl.text.trim(),
        visionModel: _modelCtrl.text.trim(),
      ),
    );
  }

  @override
  void dispose() {
    // 先把未落盘编辑保存（flush 的 _build 会读 controller.text），再释放 controller。
    if (_save.hasPending) unawaited(_save.flush());
    _save.dispose();
    _urlCtrl.dispose();
    _keyCtrl.dispose();
    _modelCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _IosSettingsPage(
      shiyi: widget.shiyi,
      title: '视觉模型',
      children: [
        CupertinoListSection.insetGrouped(
          decoration: _iosSectionDecoration(
            _isDark(context, widget.shiyi.settings.themeMode),
          ),
          backgroundColor: _iosGroupedBackground(
            _isDark(context, widget.shiyi.settings.themeMode),
          ),
          children: [
            CupertinoListTile(
              leading: _IosIconTile(
                icon: CupertinoIcons.photo_fill,
                color: _iosPurple,
              ),
              title: const Text('启用视觉模型'),
              subtitle: const Text('主模型不支持图片时，自动调用视觉模型描述图片后再继续对话'),
              trailing: CupertinoSwitch(
                value: _enabled,
                onChanged: (v) {
                  setState(() => _enabled = v);
                  _save.schedule();
                },
              ),
            ),
          ],
        ),
        if (_enabled)
          CupertinoListSection.insetGrouped(
            decoration: _iosSectionDecoration(
              _isDark(context, widget.shiyi.settings.themeMode),
            ),
            backgroundColor: _iosGroupedBackground(
              _isDark(context, widget.shiyi.settings.themeMode),
            ),
            header: const Text('模型配置'),
            children: [
              _IosTextFieldTile(
                icon: CupertinoIcons.link,
                color: _iosBlue,
                title: '接口地址',
                controller: _urlCtrl,
                placeholder: '留空则与主模型同接口',
                onChanged: (_) => _save.schedule(),
              ),
              _IosSecretFieldTile(
                icon: CupertinoIcons.lock_fill,
                color: _iosOrange,
                title: '密钥',
                controller: _keyCtrl,
                placeholder: '留空则与主模型同密钥',
                obscure: !_showKey,
                onToggleVisibility: () => setState(() => _showKey = !_showKey),
                onChanged: (_) => _save.schedule(),
              ),
              _IosTextFieldTile(
                icon: CupertinoIcons.bolt_fill,
                color: _iosGreen,
                title: '模型',
                controller: _modelCtrl,
                placeholder: '例如 gpt-4o-mini / qwen-vl-max',
                onChanged: (_) => _save.schedule(),
              ),
            ],
          ),
      ],
    );
  }
}

class _InteractionSectionPage extends StatefulWidget {
  final ShiyiState shiyi;
  const _InteractionSectionPage({required this.shiyi});

  @override
  State<_InteractionSectionPage> createState() =>
      _InteractionSectionPageState();
}

class _InteractionSectionPageState extends State<_InteractionSectionPage> {
  late bool _tools;
  late bool _memory;
  late bool _autoLearn;
  late bool _notifications;
  late bool _enterToSend;
  late final _DebouncedSave _save;

  @override
  void initState() {
    super.initState();
    final s = widget.shiyi.settings;
    _tools = s.enableTools;
    _memory = s.enableMemory;
    _autoLearn = s.enableAutoLearn;
    _notifications = s.enableNotifications;
    _enterToSend = s.enterToSend;
    _save = _DebouncedSave(
      widget.shiyi,
      () => widget.shiyi.settings.copyWith(
        enableTools: _tools,
        enableMemory: _memory,
        enableAutoLearn: _autoLearn,
        enableNotifications: _notifications,
        enterToSend: _enterToSend,
      ),
    );
  }

  @override
  void dispose() {
    // 快速返回时把未落盘的编辑立即保存，避免丢改动。
    if (_save.hasPending) unawaited(_save.flush());
    _save.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _IosSettingsPage(
      shiyi: widget.shiyi,
      title: '对话与功能',
      children: [
        CupertinoListSection.insetGrouped(
          decoration: _iosSectionDecoration(
            _isDark(context, widget.shiyi.settings.themeMode),
          ),
          backgroundColor: _iosGroupedBackground(
            _isDark(context, widget.shiyi.settings.themeMode),
          ),
          children: [
            _switchTile(
              icon: CupertinoIcons.chat_bubble_2_fill,
              color: _iosIndigo,
              title: '启用工具调用',
              subtitle:
                  '拾忆 可调用 save_memory（保存记忆）/ search_memory（搜索记忆）/ run_skill（运行技能）工具',
              value: _tools,
              onChanged: (v) {
                setState(() => _tools = v);
                _save.schedule();
              },
            ),
            _switchTile(
              icon: CupertinoIcons.bookmark_fill,
              color: _iosOrange,
              title: '启用长期记忆',
              subtitle: '对话前自动注入相关记忆与技能上下文',
              value: _memory,
              onChanged: (v) {
                setState(() => _memory = v);
                _save.schedule();
              },
            ),
            _switchTile(
              icon: CupertinoIcons.sparkles,
              color: _iosPink,
              title: '自动沉淀记忆',
              subtitle: '每轮对话后自动提炼重要信息存入长期记忆',
              value: _autoLearn,
              onChanged: (v) {
                setState(() => _autoLearn = v);
                _save.schedule();
              },
            ),
            _switchTile(
              icon: CupertinoIcons.bell_fill,
              color: _iosRed,
              title: '任务完成通知',
              subtitle: '切走会话/后台运行时，任务完成后推送系统通知',
              value: _notifications,
              onChanged: (v) {
                setState(() => _notifications = v);
                _save.schedule();
              },
            ),
            _switchTile(
              icon: CupertinoIcons.return_icon,
              color: _iosGreen,
              title: '回车键发送',
              subtitle: '开启后按回车直接发送消息，关闭后回车换行',
              value: _enterToSend,
              onChanged: (v) {
                setState(() => _enterToSend = v);
                _save.schedule();
              },
            ),
          ],
        ),
      ],
    );
  }
}

Widget _switchTile({
  required IconData icon,
  required Color color,
  required String title,
  required String subtitle,
  required bool value,
  required ValueChanged<bool> onChanged,
}) {
  return CupertinoListTile(
    leading: _IosIconTile(icon: icon, color: color),
    title: Text(title),
    subtitle: Text(subtitle),
    trailing: CupertinoSwitch(value: value, onChanged: onChanged),
  );
}

class _ContextSectionPage extends StatefulWidget {
  final ShiyiState shiyi;
  const _ContextSectionPage({required this.shiyi});

  @override
  State<_ContextSectionPage> createState() => _ContextSectionPageState();
}

class _ContextSectionPageState extends State<_ContextSectionPage> {
  late int _contextLimit;
  late int _maxOutputTokens;
  late double _threshold;
  late bool _autoCompress;
  late final TextEditingController _contextLimitCtrl;
  late final TextEditingController _maxOutputTokensCtrl;
  late final TextEditingController _thresholdCtrl;
  late final _DebouncedSave _save;

  @override
  void initState() {
    super.initState();
    final s = widget.shiyi.settings;
    _contextLimit = s.contextLimit;
    _maxOutputTokens = s.maxOutputTokens;
    _threshold = s.compressThresholdPercent;
    _autoCompress = s.autoCompress;
    _contextLimitCtrl = TextEditingController(text: _contextLimit.toString());
    _maxOutputTokensCtrl = TextEditingController(
      text: _maxOutputTokens.toString(),
    );
    _thresholdCtrl = TextEditingController(text: _threshold.toStringAsFixed(0));
    _save = _DebouncedSave(
      widget.shiyi,
      () => widget.shiyi.settings.copyWith(
        contextLimit: _contextLimit,
        maxOutputTokens: _maxOutputTokens,
        compressThresholdPercent: _threshold,
        autoCompress: _autoCompress,
      ),
    );
  }

  @override
  void dispose() {
    _contextLimitCtrl.dispose();
    _maxOutputTokensCtrl.dispose();
    _thresholdCtrl.dispose();
    // 快速返回时把未落盘的编辑立即保存，避免丢改动。
    if (_save.hasPending) unawaited(_save.flush());
    _save.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _IosSettingsPage(
      shiyi: widget.shiyi,
      title: '上下文',
      children: [
        CupertinoListSection.insetGrouped(
          decoration: _iosSectionDecoration(
            _isDark(context, widget.shiyi.settings.themeMode),
          ),
          backgroundColor: _iosGroupedBackground(
            _isDark(context, widget.shiyi.settings.themeMode),
          ),
          children: [
            CupertinoListTile(
              leading: _IosIconTile(
                icon: CupertinoIcons.textformat,
                color: _iosBlue,
              ),
              title: const Text('输出上限'),
              subtitle: const Text('单次请求最大输出 token，思考型模型建议调大'),
              trailing: _IosValueField(
                controller: _maxOutputTokensCtrl,
                keyboardType: TextInputType.number,
                width: 120,
                onChanged: (v) {
                  final n = int.tryParse(v);
                  if (n != null && n > 0) {
                    setState(() => _maxOutputTokens = n.clamp(512, 384000));
                    _save.schedule();
                  }
                },
              ),
            ),
            CupertinoListTile(
              leading: _IosIconTile(
                icon: CupertinoIcons.square_on_square,
                color: _iosTeal,
              ),
              title: const Text('上下文上限'),
              subtitle: const Text('会话上下文最大 token 数（默认 128k，最高 200w）'),
              trailing: _IosValueField(
                controller: _contextLimitCtrl,
                keyboardType: TextInputType.number,
                width: 120,
                onChanged: (v) {
                  final n = int.tryParse(v);
                  if (n != null && n > 0) {
                    setState(() => _contextLimit = n.clamp(1000, 2000000));
                    _save.schedule();
                  }
                },
              ),
            ),
            CupertinoListTile(
              leading: _IosIconTile(
                icon: CupertinoIcons.percent,
                color: _iosPurple,
              ),
              title: const Text('压缩阈值'),
              subtitle: const Text('上下文达到上下文上限的该百分比时触发手动/自动压缩'),
              trailing: _IosValueField(
                controller: _thresholdCtrl,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                width: 130,
                suffix: '%',
                onChanged: (v) {
                  final n = double.tryParse(v);
                  if (n != null && n > 0) {
                    setState(() => _threshold = n.clamp(1, 100));
                    _save.schedule();
                  }
                },
              ),
            ),
            _switchTile(
              icon: CupertinoIcons.wand_stars,
              color: _iosIndigo,
              title: '自动压缩',
              subtitle: '上下文超过压缩阈值时自动总结压缩历史',
              value: _autoCompress,
              onChanged: (v) {
                setState(() => _autoCompress = v);
                _save.schedule();
              },
            ),
          ],
        ),
      ],
    );
  }
}

class _AppearanceSectionPage extends StatefulWidget {
  final ShiyiState shiyi;
  const _AppearanceSectionPage({required this.shiyi});

  @override
  State<_AppearanceSectionPage> createState() => _AppearanceSectionPageState();
}

class _AppearanceSectionPageState extends State<_AppearanceSectionPage> {
  late String _themeMode;
  late final _DebouncedSave _save;

  @override
  void initState() {
    super.initState();
    _themeMode = widget.shiyi.settings.themeMode;
    _save = _DebouncedSave(
      widget.shiyi,
      () => widget.shiyi.settings.copyWith(themeMode: _themeMode),
    );
  }

  @override
  void dispose() {
    // 快速返回时把未落盘的编辑立即保存，避免丢改动。
    if (_save.hasPending) unawaited(_save.flush());
    _save.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _IosSettingsPage(
      shiyi: widget.shiyi,
      title: '外观',
      children: [
        CupertinoListSection.insetGrouped(
          decoration: _iosSectionDecoration(
            _isDark(context, widget.shiyi.settings.themeMode),
          ),
          backgroundColor: _iosGroupedBackground(
            _isDark(context, widget.shiyi.settings.themeMode),
          ),
          header: const Text('主题模式'),
          children: [
            _ThemeRow(
              icon: CupertinoIcons.sun_max_fill,
              color: _iosOrange,
              title: '浅色',
              selected: _themeMode == 'light',
              onTap: () => _setThemeMode('light'),
            ),
            _ThemeRow(
              icon: CupertinoIcons.moon_fill,
              color: _iosIndigo,
              title: '深色',
              selected: _themeMode == 'dark',
              onTap: () => _setThemeMode('dark'),
            ),
            _ThemeRow(
              icon: CupertinoIcons.circle_lefthalf_fill,
              color: _iosBlue,
              title: '跟随系统',
              selected: _themeMode == 'system',
              onTap: () => _setThemeMode('system'),
            ),
          ],
        ),
      ],
    );
  }

  void _setThemeMode(String v) {
    if (_themeMode == v) return;
    FocusScope.of(context).unfocus();
    setState(() => _themeMode = v);
    unawaited(
      widget.shiyi.updateSettings(widget.shiyi.settings.copyWith(themeMode: v)),
    );
    _save.schedule();
  }
}

class _ThemeRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final bool selected;
  final VoidCallback onTap;
  const _ThemeRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return CupertinoListTile(
      leading: _IosIconTile(icon: icon, color: color),
      title: Text(title),
      trailing: selected
          ? const Icon(
              CupertinoIcons.checkmark_circle_fill,
              color: CupertinoColors.activeBlue,
            )
          : null,
      onTap: onTap,
    );
  }
}

class _VoiceSectionPage extends StatefulWidget {
  final ShiyiState shiyi;
  const _VoiceSectionPage({required this.shiyi});

  @override
  State<_VoiceSectionPage> createState() => _VoiceSectionPageState();
}

class _VoiceSectionPageState extends State<_VoiceSectionPage> {
  late double _ttsRate;
  late final _DebouncedSave _save;

  @override
  void initState() {
    super.initState();
    _ttsRate = widget.shiyi.settings.ttsRate;
    _save = _DebouncedSave(
      widget.shiyi,
      () => widget.shiyi.settings.copyWith(ttsRate: _ttsRate),
    );
  }

  @override
  void dispose() {
    // 快速返回时把未落盘的编辑立即保存，避免丢改动。
    if (_save.hasPending) unawaited(_save.flush());
    _save.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = _isDark(context, widget.shiyi.settings.themeMode);
    return _IosSettingsPage(
      shiyi: widget.shiyi,
      title: '语音',
      children: [
        CupertinoListSection.insetGrouped(
          decoration: _iosSectionDecoration(dark),
          backgroundColor: _iosGroupedBackground(dark),
          header: const Text('语速'),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
              child: Row(
                children: [
                  const Icon(
                    CupertinoIcons.speaker_3_fill,
                    color: CupertinoColors.systemPink,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(child: Text('朗读速度')),
                  Text(
                    _ttsRate.toStringAsFixed(1),
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: dark
                          ? CupertinoColors.white.withValues(alpha: .6)
                          : CupertinoColors.black.withValues(alpha: .55),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: SizedBox(
                width: double.infinity,
                child: _IosSlider(
                  value: _ttsRate,
                  min: 0.5,
                  max: 1.5,
                  divisions: 10,
                  onChanged: (v) {
                    setState(() => _ttsRate = v);
                    _save.schedule();
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Row(
                children: [
                  Text(
                    '0.5×',
                    style: TextStyle(
                      fontSize: 12,
                      color: CupertinoColors.secondaryLabel,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '1.5×',
                    style: TextStyle(
                      fontSize: 12,
                      color: CupertinoColors.secondaryLabel,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 统一 iOS 细滑块：细轨道、小圆钮，避免 CupertinoSlider 的大钮占用版面。
class _IosSlider extends StatelessWidget {
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double> onChanged;

  const _IosSlider({
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SliderTheme(
      data: SliderThemeData(
        trackHeight: 6,
        activeTrackColor: CupertinoColors.activeBlue,
        inactiveTrackColor: dark
            ? const Color(0xFF3A3A3C)
            : const Color(0xFFE5E5EA),
        thumbColor: Colors.white,
        thumbShape: const RoundSliderThumbShape(
          enabledThumbRadius: 7,
          elevation: 1,
        ),
        overlayShape: SliderComponentShape.noOverlay,
        activeTickMarkColor: Colors.transparent,
        inactiveTickMarkColor: Colors.transparent,
      ),
      child: Slider(
        value: value,
        min: min,
        max: max,
        divisions: divisions,
        onChanged: onChanged,
      ),
    );
  }
}

class _AdvancedSectionPage extends StatefulWidget {
  final ShiyiState shiyi;
  const _AdvancedSectionPage({required this.shiyi});

  @override
  State<_AdvancedSectionPage> createState() => _AdvancedSectionPageState();
}

class _AdvancedSectionPageState extends State<_AdvancedSectionPage> {
  /// 自定义系统提示词上限（字符）：防止超长提示词每轮烧 token / 撑爆上下文窗口。
  static const int _maxPromptChars = 32768;

  late double _temperature;
  late final TextEditingController _promptCtrl;
  late final _DebouncedSave _save;
  bool _fileAccessGranted = false;

  @override
  void initState() {
    super.initState();
    _temperature = widget.shiyi.settings.temperature;
    _promptCtrl = TextEditingController(
      text: widget.shiyi.settings.systemPrompt,
    );
    _save = _DebouncedSave(
      widget.shiyi,
      () => widget.shiyi.settings.copyWith(temperature: _temperature),
    );
    _checkFileAccess();
  }

  @override
  void dispose() {
    // 先把未落盘编辑保存（flush 的 _build 会读 controller.text），再释放 controller。
    if (_save.hasPending) unawaited(_save.flush());
    _save.dispose();
    _promptCtrl.dispose();
    super.dispose();
  }

  Future<void> _checkFileAccess() async {
    final granted = await PermissionService.isFullAccessGranted();
    if (!mounted) return;
    setState(() => _fileAccessGranted = granted);
  }

  Future<void> _requestFullAccess() async {
    await PermissionService.requestFullAccess();
    await _checkFileAccess();
    if (!mounted) return;
    await _showIosAlert(
      context,
      '文件访问权限',
      _fileAccessGranted ? '已获得全部文件访问权限' : '请在系统页面中开启「允许访问所有文件」',
    );
  }

  Future<void> _savePrompt() async {
    final text = _promptCtrl.text;
    if (text.length > _maxPromptChars) {
      if (mounted) {
        await _showIosAlert(
          context,
          '提示词过长',
          '系统提示词最多 $_maxPromptChars 字符，当前 ${text.length} 字符。'
          '请删减后再保存（超长提示词会占用大量上下文并拖慢每轮请求）。',
        );
      }
      return;
    }
    await widget.shiyi.updateSettings(
      widget.shiyi.settings.copyWith(systemPrompt: text),
    );
    if (mounted) await _showIosAlert(context, '完成', '系统提示词已保存');
  }

  @override
  Widget build(BuildContext context) {
    final dark = _isDark(context, widget.shiyi.settings.themeMode);
    return _IosSettingsPage(
      shiyi: widget.shiyi,
      title: '高级',
      children: [
        CupertinoListSection.insetGrouped(
          decoration: _iosSectionDecoration(dark),
          backgroundColor: _iosGroupedBackground(dark),
          header: const Text('温度'),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
              child: Row(
                children: [
                  const Icon(
                    CupertinoIcons.thermometer,
                    color: CupertinoColors.systemRed,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(child: Text('随机性')),
                  Text(
                    _temperature.toStringAsFixed(2),
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: dark
                          ? CupertinoColors.white.withValues(alpha: .6)
                          : CupertinoColors.black.withValues(alpha: .55),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: SizedBox(
                width: double.infinity,
                child: _IosSlider(
                  value: _temperature,
                  min: 0,
                  max: 2,
                  divisions: 20,
                  onChanged: (v) {
                    setState(() => _temperature = v);
                    _save.schedule();
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Row(
                children: [
                  Text(
                    '0',
                    style: TextStyle(
                      fontSize: 12,
                      color: CupertinoColors.secondaryLabel,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '2',
                    style: TextStyle(
                      fontSize: 12,
                      color: CupertinoColors.secondaryLabel,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        CupertinoListSection.insetGrouped(
          decoration: _iosSectionDecoration(dark),
          backgroundColor: _iosGroupedBackground(dark),
          children: [
            CupertinoListTile(
              leading: _IosIconTile(
                icon: CupertinoIcons.folder_fill,
                color: _iosBlue,
              ),
              title: const Text('文件访问权限'),
              subtitle: Text(
                _fileAccessGranted ? '已开启，终端可读写手机存储' : '未开启，终端读写 /sdcard 会被拒绝',
              ),
              trailing: _fileAccessGranted
                  ? const Icon(
                      CupertinoIcons.checkmark_circle_fill,
                      color: CupertinoColors.systemGreen,
                    )
                  : const CupertinoListTileChevron(),
              onTap: _requestFullAccess,
            ),
          ],
        ),
        CupertinoListSection.insetGrouped(
          decoration: _iosSectionDecoration(dark),
          backgroundColor: _iosGroupedBackground(dark),
          header: const Text('系统提示词'),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: CupertinoTextField(
                controller: _promptCtrl,
                maxLines: 4,
                placeholder: '（留空使用默认拾忆人设）',
                padding: const EdgeInsets.all(10),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerRight,
                // 只刷新计数文本，不整页重建。
                child: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _promptCtrl,
                  builder: (context, value, _) {
                    final len = value.text.length;
                    final over = len > _maxPromptChars;
                    return Text(
                      over
                          ? '$len / $_maxPromptChars（超出上限，无法保存）'
                          : '$len / $_maxPromptChars',
                      style: TextStyle(
                        fontSize: 12,
                        color: over
                            ? CupertinoColors.systemRed
                            : (dark
                                ? CupertinoColors.white.withValues(alpha: .5)
                                : CupertinoColors.black.withValues(alpha: .45)),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
          child: CupertinoButton.filled(
            onPressed: _savePrompt,
            child: const Text('保存提示词'),
          ),
        ),
      ],
    );
  }
}

class _IosTextFieldTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final TextEditingController controller;
  final String placeholder;
  final ValueChanged<String> onChanged;
  const _IosTextFieldTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.controller,
    required this.placeholder,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return CupertinoListTile(
      leading: _IosIconTile(icon: icon, color: color),
      title: Text(title),
      trailing: SizedBox(
        width: 230,
        child: CupertinoTextField(
          controller: controller,
          placeholder: placeholder,
          textAlign: TextAlign.right,
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: null,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _IosSecretFieldTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final TextEditingController controller;
  final String placeholder;
  final bool obscure;
  final VoidCallback onToggleVisibility;
  final ValueChanged<String> onChanged;
  const _IosSecretFieldTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.controller,
    required this.placeholder,
    required this.obscure,
    required this.onToggleVisibility,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return CupertinoListTile(
      leading: _IosIconTile(icon: icon, color: color),
      title: Text(title),
      trailing: SizedBox(
        width: 230,
        child: CupertinoTextField(
          controller: controller,
          placeholder: placeholder,
          obscureText: obscure,
          textAlign: TextAlign.right,
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: null,
          suffix: CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: onToggleVisibility,
            child: Text(
              obscure ? '显示' : '隐藏',
              style: const TextStyle(
                fontSize: 13,
                color: CupertinoColors.activeBlue,
              ),
            ),
          ),
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _IosValueField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final TextInputType? keyboardType;
  final String? suffix;
  final double width;
  const _IosValueField({
    required this.controller,
    required this.onChanged,
    this.keyboardType,
    this.suffix,
    this.width = 120,
  });

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    return SizedBox(
      width: width,
      child: CupertinoTextField(
        controller: controller,
        keyboardType: keyboardType,
        textAlign: TextAlign.right,
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: null,
        suffix: suffix == null
            ? null
            : Text(
                suffix!,
                style: TextStyle(
                  fontSize: 15,
                  color: dark
                      ? CupertinoColors.white.withValues(alpha: .6)
                      : CupertinoColors.black.withValues(alpha: .55),
                ),
              ),
        onChanged: onChanged,
      ),
    );
  }
}

class _IosIconTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  const _IosIconTile({required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 31,
      height: 31,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Icon(icon, size: 17, color: CupertinoColors.white),
    );
  }
}
