import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/mac_page_route.dart';
import '../core/model_presets.dart';
import '../core/models.dart';
import '../services/dsh_model_sync.dart';
import '../services/dsh_service.dart';
import '../services/llm_client.dart';
import '../services/network_proxy.dart';
import '../services/permission_service.dart';
import '../services/socks5_config.dart';
import '../services/settings_service.dart';
import '../services/termux_runtime.dart';
import '../services/update_service.dart';
import '../widgets/ios_style.dart';
import '../widgets/laap_service_panel.dart';
import 'about_screen.dart';
import 'dsh_center_screen.dart';
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

Future<void> _settleInputFocusBeforeOverlay(BuildContext context) async {
  final focus = FocusManager.instance.primaryFocus;
  if (focus == null || !focus.hasFocus) return;
  focus.unfocus(disposition: UnfocusDisposition.scope);
  await WidgetsBinding.instance.endOfFrame;
  if (Platform.isAndroid) {
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
}

Future<void> _showIosAlert(
  BuildContext context,
  String title,
  String message,
) async {
  await _settleInputFocusBeforeOverlay(context);
  if (!context.mounted) return;
  await showIosFadeDialog<void>(
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
  await _settleInputFocusBeforeOverlay(context);
  if (!context.mounted) return await task();
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
          data: iosCupertinoTheme(context),
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
                        padding: const EdgeInsets.fromLTRB(12, 8, 20, 4),
                        child: Row(
                          children: [
                            // Windows 桌面没有系统返回手势：标题左侧补返回入口。
                            if (Platform.isWindows) ...[
                              Tooltip(
                                message: '返回',
                                child: CupertinoButton(
                                  padding: const EdgeInsets.all(6),
                                  onPressed: () =>
                                      Navigator.of(context).maybePop(),
                                  child: const Icon(
                                    CupertinoIcons.back,
                                    size: 22,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                            ],
                            Text(
                              '设置',
                              style: TextStyle(
                                fontSize: 34,
                                fontWeight: FontWeight.w700,
                                color: dark
                                    ? CupertinoColors.white
                                    : CupertinoColors.black,
                              ),
                            ),
                          ],
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
                                '新建默认 ${_tokenLabel(s.contextLimit)} · 自动压缩${s.autoCompress ? '开' : '关'}',
                            onTap: () => _open(
                              context,
                              _ContextSectionPage(shiyi: shiyi),
                            ),
                          ),
                          // Agent 引擎切换（拾忆 / DSH），两端都显示。
                          _navTile(
                            icon: CupertinoIcons.sparkles,
                            color: _iosIndigo,
                            title: 'Agent 引擎',
                            subtitle: s.agentEngine == 'dsh'
                                ? 'DeepSeek Harness'
                                : '拾忆（本地引擎）',
                            onTap: () =>
                                _open(context, AgentEnginePage(shiyi: shiyi)),
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
                          if (Platform.isWindows)
                            _navTile(
                              icon: CupertinoIcons
                                  .chevron_left_slash_chevron_right,
                              color: _iosTeal,
                              title: '终端',
                              subtitle: _terminalBackendLabel(
                                s.terminalBackend,
                              ),
                              onTap: () => _open(
                                context,
                                _TerminalSectionPage(shiyi: shiyi),
                              ),
                            ),
                          _navTile(
                            icon: CupertinoIcons.lock_shield_fill,
                            color: _iosTeal,
                            title: 'SOCKS5 代理',
                            subtitle: _socks5Subtitle(s),
                            onTap: () => _open(
                              context,
                              _Socks5SectionPage(shiyi: shiyi),
                            ),
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

/// 设置分组底部说明：12 号次要色，只当提示。
Widget _iosSectionFooter(String text) {
  return DefaultTextStyle.merge(
    style: const TextStyle(
      fontSize: 12,
      height: 1.35,
      fontWeight: FontWeight.w400,
      color: CupertinoColors.secondaryLabel,
    ),
    child: Text(text),
  );
}

String _socks5Subtitle(AppSettings s) {
  final mode = Socks5Endpoint.modeOf(s);
  if (mode == 'auto') return '自动检测本机 Clash / V2Ray';
  if (mode == 'custom') {
    Socks5Server? active;
    for (final e in s.socks5Servers) {
      if (e.id == s.socks5ActiveId) {
        active = e;
        break;
      }
    }
    if (active != null && active.host.isNotEmpty) {
      return '${active.label}  ${active.host}:${active.port}';
    }
    if (s.socks5Host.isNotEmpty) return '${s.socks5Host}:${s.socks5Port}';
    return '自定义（未选服务器）';
  }
  return '关闭（直连）';
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
    subtitle: Text(subtitle),
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

String _tokenLabel(int n) => formatContextLimitLabel(n);

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

/// DSH 设置根页复用拾忆外观二级页。
String shiyiThemeModeLabel(String mode) => _themeLabel(mode);

Widget shiyiAppearanceSettingsPage(ShiyiState shiyi) =>
    _AppearanceSectionPage(shiyi: shiyi);

/// DSH 设置根页复用拾忆模型 API 二级页。改这里会同步到 DSH。
Widget shiyiModelApiSettingsPage(ShiyiState shiyi) =>
    _ApiSectionPage(shiyi: shiyi);

String _terminalBackendLabel(String backend) {
  switch (backend) {
    case 'wsl2':
      return 'WSL2（Linux 环境）';
    case 'gitbash':
      return 'Git Bash';
    case 'pwsh':
      return 'PowerShell 7';
    case 'cmd':
      return 'cmd';
    default:
      return '自动（WSL2 → Git Bash → PowerShell）';
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
          data: iosCupertinoTheme(context),
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
  late final TextEditingController _searchKeyCtrl;
  late final _DebouncedSave _save;
  late String _protocol;
  late String _searchProvider;
  String _keyHint = 'sk-...';
  String? _presetName;
  bool _showKey = false;
  bool _showSearchKey = false;
  bool _profilesLoaded = false;
  List<ApiProfile> _profiles = [];
  List<String> _cachedModelIds = [];

  @override
  void initState() {
    super.initState();
    final s = widget.shiyi.settings;
    _baseCtrl = TextEditingController(text: s.baseUrl);
    _keyCtrl = TextEditingController(text: s.apiKey);
    _modelCtrl = TextEditingController(text: s.model);
    _searchKeyCtrl = TextEditingController(text: s.dshSearchKey);
    _protocol = s.apiProtocol;
    _searchProvider = s.dshSearchProvider;
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
        dshSearchProvider: _searchProvider,
        dshSearchKey: _searchKeyCtrl.text.trim(),
      ),
      after: _persistCurrentProfile,
    );
    _loadProfiles();
    unawaited(_loadCachedModels());
  }

  @override
  void dispose() {
    // 先把未落盘编辑保存（flush 的 _build 会读 controller.text），再释放 controller。
    if (_save.hasPending) unawaited(_save.flush());
    _save.dispose();
    _baseCtrl.dispose();
    _keyCtrl.dispose();
    _modelCtrl.dispose();
    _searchKeyCtrl.dispose();
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

  AppSettings _modelCatalogSettings() => widget.shiyi.settings.copyWith(
    baseUrl: _currentBaseUrl(),
    model: _modelCtrl.text.trim(),
    apiProtocol: _protocol,
  );

  Future<void> _loadCachedModels() async {
    final ids = await DshModelSync.cachedModelCatalogFor(
      _modelCatalogSettings(),
    );
    if (!mounted) return;
    setState(() => _cachedModelIds = ids);
  }

  List<ApiProfile> get _allProfiles => mergeApiProfiles(_profiles);

  bool get _isBuiltinPreset =>
      _presetName != null && modelPresets.any((p) => p.name == _presetName);

  /// 自定义 OpenAI 兼容接口自动补 /v1；内置预设和 Anthropic 原样保留。
  String _currentBaseUrl() {
    final raw = _baseCtrl.text.trim();
    if (_isBuiltinPreset || _protocol == 'anthropic') return raw;
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
    unawaited(_loadCachedModels());
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
    await widget.shiyi.reloadApiProfiles();
  }

  Future<void> _pickProfile() async {
    final all = _allProfiles;
    await _settleInputFocusBeforeOverlay(context);
    if (!mounted) return;
    final picked = await showIosFadeModalPopup<String>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('模型预设'),
        actions: [
          for (final profile in all)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(ctx, profile.name),
              child: Text(profile.name),
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
    unawaited(_loadCachedModels());
    unawaited(
      widget.shiyi.updateSettings(
        widget.shiyi.settings.copyWith(apiProtocol: v),
      ),
    );
    _save.schedule();
  }

  static String _searchProviderLabel(String provider) {
    switch (provider) {
      case 'bing':
        return 'Bing RSS（免费）';
      case 'ddg':
        return 'DuckDuckGo（免费）';
      case 'ddg-lite':
        return 'DuckDuckGo Lite（免费）';
      case 'deepseek':
        return 'DeepSeek 官方（API Key）';
      default:
        return '自动切换（推荐）';
    }
  }

  Future<void> _pickSearchProvider() async {
    await _settleInputFocusBeforeOverlay(context);
    if (!mounted) return;
    final picked = await showIosFadeModalPopup<String>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('DSH 联网搜索'),
        actions: [
          for (final provider in const [
            'auto',
            'bing',
            'ddg',
            'ddg-lite',
            'deepseek',
          ])
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(ctx, provider),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_searchProvider == provider) ...[
                    const Icon(
                      CupertinoIcons.checkmark_alt,
                      size: 16,
                      color: CupertinoColors.activeBlue,
                    ),
                    const SizedBox(width: 8),
                  ],
                  Text(_searchProviderLabel(provider)),
                ],
              ),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
      ),
    );
    if (picked == null || !mounted || picked == _searchProvider) return;
    setState(() => _searchProvider = picked);
    _save.schedule();
  }

  Future<void> _createCustomProfile() async {
    final nameCtrl = TextEditingController();
    final urlCtrl = TextEditingController();
    final keyCtrl = TextEditingController();
    final modelCtrl = TextEditingController();
    var dialogProtocol = 'openai';
    await _settleInputFocusBeforeOverlay(context);
    if (!mounted) return;
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
                        setDialogState(() => dialogProtocol = 'responses'),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'OpenAI Responses',
                            textAlign: TextAlign.left,
                          ),
                        ),
                        if (dialogProtocol == 'responses')
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
    final baseUrl = result.apiProtocol == 'anthropic'
        ? LlmClient.normalizeAnthropicBaseUrl(result.baseUrl.trim())
        : normalizeOpenAiBaseUrl(result.baseUrl);
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
    await _settleInputFocusBeforeOverlay(context);
    if (!mounted) return;
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
    await widget.shiyi.reloadApiProfiles();
    if (mounted) {
      if (_save.hasPending) await _save.flush();
      final next = widget.shiyi.settings.copyWith(
        baseUrl: baseUrl,
        apiKey: _keyCtrl.text.trim(),
        model: _modelCtrl.text.trim(),
        apiProtocol: _protocol,
      );
      await widget.shiyi.updateSettings(next);
      await DshModelSync.injectNow(next, name: name);
      if (!mounted) return;
      await _showIosAlert(context, '完成', '配置「$name」已保存，并已注入到 DeepSeek Harness');
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
    await _settleInputFocusBeforeOverlay(context);
    if (!mounted) return;
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
    await widget.shiyi.reloadApiProfiles();
    if (mounted) {
      await _showIosAlert(context, '完成', '配置「$name」已删除');
    }
  }

  Future<void> _pickModelId(List<String> ids, {required String title}) async {
    if (ids.isEmpty || !mounted) return;
    await _settleInputFocusBeforeOverlay(context);
    if (!mounted) return;
    final picked = await showIosFadeModalPopup<String>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text(title),
        actions: [
          for (final id in ids)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(ctx, id),
              child: Text(id),
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
  }

  Future<void> _pickCachedModels() async {
    await _loadCachedModels();
    if (!mounted) return;
    if (_cachedModelIds.isEmpty) {
      await _showIosAlert(context, '提示', '还没有缓存模型，请先获取一次模型目录');
      return;
    }
    await _pickModelId(_cachedModelIds, title: '已缓存模型');
  }

  Future<void> _fetchModels() async {
    await _settleInputFocusBeforeOverlay(context);
    if (!mounted) return;
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
      final settings = _modelCatalogSettings();
      await DshModelSync.rememberModelCatalog(settings, ids);
      await widget.shiyi.reloadModelCatalogs();
      if (!mounted) return;
      setState(() => _cachedModelIds = [...ids]..sort());
      unawaited(DshModelSync.syncFromShiyi(settings));
      await _pickModelId(_cachedModelIds, title: '模型 ID');
    } catch (e) {
      if (mounted) await _showIosAlert(context, '获取模型失败', '$e');
    }
  }

  Future<void> _testModel() async {
    await _settleInputFocusBeforeOverlay(context);
    if (!mounted) return;
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
              onChanged: (_) {
                if (_cachedModelIds.isNotEmpty) {
                  setState(() => _cachedModelIds = []);
                }
                _save.schedule();
              },
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
          header: _SectionHeader(
            title: 'DSH 联网搜索',
            subtitle: _searchProvider == 'deepseek'
                ? 'DeepSeek 官方搜索需要 API Key；主接口为 DeepSeek 官方时，留空可复用主密钥。'
                : '自动模式按 Bing RSS → DuckDuckGo → DuckDuckGo Lite 回退，均无需 API Key。',
          ),
          children: [
            CupertinoListTile(
              leading: _IosIconTile(
                icon: CupertinoIcons.globe,
                color: _iosGreen,
              ),
              title: const Text('搜索引擎'),
              subtitle: Text(_searchProviderLabel(_searchProvider)),
              trailing: const CupertinoListTileChevron(),
              onTap: _pickSearchProvider,
            ),
            if (_searchProvider == 'deepseek')
              _IosSecretFieldTile(
                icon: CupertinoIcons.lock_fill,
                color: _iosGreen,
                title: '搜索 API Key',
                controller: _searchKeyCtrl,
                placeholder: 'sk-...（留空自动复用）',
                obscure: !_showSearchKey,
                onToggleVisibility: () =>
                    setState(() => _showSearchKey = !_showSearchKey),
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
                icon: CupertinoIcons.arrow_2_squarepath,
                color: _iosGreen,
              ),
              title: const Text('OpenAI Responses'),
              subtitle: const Text(
                'OpenAI / DeepSeek / 百炼 / OpenRouter 原生 Responses',
              ),
              trailing: _protocol == 'responses'
                  ? const Icon(
                      CupertinoIcons.checkmark_circle_fill,
                      color: CupertinoColors.activeBlue,
                    )
                  : null,
              onTap: () => _setProtocol('responses'),
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
                icon: CupertinoIcons.checkmark_alt_circle_fill,
                color: _iosGreen,
              ),
              title: const Text('选择缓存模型'),
              subtitle: Text(
                _cachedModelIds.isEmpty
                    ? '获取一次后即可直接选择，不再重复请求'
                    : '已缓存 ${_cachedModelIds.length} 个模型',
              ),
              trailing: const CupertinoListTileChevron(),
              onTap: _pickCachedModels,
            ),
            CupertinoListTile(
              leading: _IosIconTile(
                icon: CupertinoIcons.list_bullet,
                color: _iosBlue,
              ),
              title: const Text(
                '刷新模型目录',
                style: TextStyle(color: CupertinoColors.activeBlue),
              ),
              subtitle: const Text('重新从接口获取全部模型并更新缓存'),
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
              subtitle: const Text('保存命名配置，并手动注入到 DeepSeek Harness'),
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
              title: const Text('新建会话默认上下文'),
              subtitle: const Text(
                '只作用于之后新建的会话（默认 128k，最高 200w）。已有会话可在聊天页单独改。',
              ),
              trailing: _IosValueField(
                controller: _contextLimitCtrl,
                keyboardType: TextInputType.number,
                width: 120,
                onChanged: (v) {
                  final n = int.tryParse(v);
                  if (n != null && n > 0) {
                    setState(
                      () => _contextLimit = n.clamp(
                        kMinContextLimit,
                        kMaxContextLimit,
                      ),
                    );
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

class _TerminalSectionPage extends StatefulWidget {
  final ShiyiState shiyi;
  const _TerminalSectionPage({required this.shiyi});

  @override
  State<_TerminalSectionPage> createState() => _TerminalSectionPageState();
}

class _TerminalSectionPageState extends State<_TerminalSectionPage> {
  late String _backend;
  late final _DebouncedSave _save;
  String _wslStatus = '';
  bool _probing = true;

  @override
  void initState() {
    super.initState();
    _backend = widget.shiyi.settings.terminalBackend;
    _save = _DebouncedSave(
      widget.shiyi,
      () => widget.shiyi.settings.copyWith(terminalBackend: _backend),
    );
    unawaited(_probeWsl());
  }

  Future<void> _probeWsl() async {
    String status;
    try {
      final v = await TermuxRuntime.wslVariant();
      status = switch (v) {
        'wsl2' => '可用（WSL2）',
        'wsl1' => '可用（WSL1，建议升级 WSL2）',
        _ => '不可用（未安装 WSL2 或没有默认发行版）',
      };
    } catch (_) {
      status = '不可用';
    }
    if (!mounted) return;
    setState(() {
      _wslStatus = status;
      _probing = false;
    });
  }

  void _select(String v) {
    if (_backend == v) return;
    FocusScope.of(context).unfocus();
    setState(() => _backend = v);
    _save.schedule();
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
      title: '终端',
      children: [
        CupertinoListSection.insetGrouped(
          decoration: _iosSectionDecoration(dark),
          backgroundColor: _iosGroupedBackground(dark),
          header: const Text('命令执行后端'),
          children: [
            _BackendRow(
              icon: CupertinoIcons.sparkles,
              color: _iosPurple,
              title: '自动',
              subtitle: 'WSL2 → Git Bash → PowerShell 7 → cmd',
              selected: _backend == 'auto',
              onTap: () => _select('auto'),
            ),
            _BackendRow(
              icon: CupertinoIcons.chevron_left_slash_chevron_right,
              color: _iosBlue,
              title: 'WSL2（Linux）',
              subtitle: '完整 Linux 环境（bash/apt/python），需要安装 WSL2',
              selected: _backend == 'wsl2',
              onTap: () => _select('wsl2'),
            ),
            _BackendRow(
              icon: CupertinoIcons.chevron_left_slash_chevron_right,
              color: _iosOrange,
              title: 'Git Bash',
              subtitle: '本机 Git for Windows 的 bash.exe',
              selected: _backend == 'gitbash',
              onTap: () => _select('gitbash'),
            ),
            _BackendRow(
              icon: CupertinoIcons.bolt_fill,
              color: _iosTeal,
              title: 'PowerShell 7',
              subtitle: 'Windows 原生 PowerShell（pwsh）',
              selected: _backend == 'pwsh',
              onTap: () => _select('pwsh'),
            ),
            _BackendRow(
              icon: CupertinoIcons.chevron_right_2,
              color: _iosGray,
              title: 'cmd',
              subtitle: '传统命令提示符（兜底）',
              selected: _backend == 'cmd',
              onTap: () => _select('cmd'),
            ),
          ],
        ),
        CupertinoListSection.insetGrouped(
          decoration: _iosSectionDecoration(dark),
          backgroundColor: _iosGroupedBackground(dark),
          header: const Text('WSL2 检测'),
          children: [
            CupertinoListTile(
              leading: _IosIconTile(
                icon: CupertinoIcons.checkmark_seal_fill,
                color: _probing
                    ? _iosGray
                    : (_wslStatus.startsWith('可用') ? _iosGreen : _iosRed),
              ),
              title: Text(_probing ? '检测中…' : _wslStatus),
              subtitle: const Text('基于 wsl.exe 运行 uname -r 判定内核版本'),
            ),
          ],
        ),
        CupertinoListSection.insetGrouped(
          decoration: _iosSectionDecoration(dark),
          backgroundColor: _iosGroupedBackground(dark),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Text(
                'Windows 终端走本机 WSL2 / Git Bash / PowerShell / cmd。'
                'WSL2 下 Windows 路径 C:\\... 在 Linux 侧为 /mnt/c/...。'
                '未安装 WSL2 时「自动」会改用 Git Bash 或 PowerShell。'
                '默认工作目录是「文档\\agent」。',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: dark
                      ? CupertinoColors.white.withValues(alpha: .6)
                      : CupertinoColors.black.withValues(alpha: .55),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _BackendRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  const _BackendRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return CupertinoListTile(
      leading: _IosIconTile(icon: icon, color: color),
      title: Text(title),
      subtitle: Text(subtitle),
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

/// Agent 引擎切换页：拾忆（本地引擎）/ DeepSeek Harness。
/// 切换后会话 tab 与聊天页使用对应数据源；两套数据完全独立。
/// 附带 DeepSeek Harness 服务管理（版本检测 / 安装更新 / 启动停止）。
/// 公开类：拾忆设置与 DS Harness 中心共用此页。
class AgentEnginePage extends StatefulWidget {
  final ShiyiState shiyi;
  const AgentEnginePage({super.key, required this.shiyi});

  @override
  State<AgentEnginePage> createState() => AgentEnginePageState();
}

class AgentEnginePageState extends State<AgentEnginePage> {
  late String _engine;
  late final _DebouncedSave _save;
  String? _localVersion;
  String? _latestVersion;
  bool _checking = false;
  bool _working = false;
  bool _checkingFullRuntime = false;
  bool? _fullRuntimeReady;
  bool _showInstallOutput = false;
  String? _workError;
  final ScrollController _installOutputScroll = ScrollController();

  DshService get _dsh => DshService.instance;

  @override
  void initState() {
    super.initState();
    _engine = widget.shiyi.settings.agentEngine;
    _save = _DebouncedSave(
      widget.shiyi,
      () => widget.shiyi.settings.copyWith(agentEngine: _engine),
    );
    _dsh.status.addListener(_onDshTick);
    _dsh.progress.addListener(_onDshTick);
    _dsh.statusMessage.addListener(_onDshTick);
    _dsh.installOutput.addListener(_onDshTick);
    // 引擎切换落盘后刷新本页（开关读的是 shiyi.settings）。
    // 返回路径不动：主页（HomeScreen）自己监听引擎变化切换 tab 套件。
    widget.shiyi.addListener(_onShiyiEngineChanged);
    unawaited(_initVersions());
  }

  @override
  void dispose() {
    widget.shiyi.removeListener(_onShiyiEngineChanged);
    _dsh.status.removeListener(_onDshTick);
    _dsh.progress.removeListener(_onDshTick);
    _dsh.statusMessage.removeListener(_onDshTick);
    _dsh.installOutput.removeListener(_onDshTick);
    _installOutputScroll.dispose();
    if (_save.hasPending) unawaited(_save.flush());
    _save.dispose();
    super.dispose();
  }

  void _onDshTick() {
    if (!mounted) return;
    setState(() {});
    if (_showInstallOutput) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_installOutputScroll.hasClients) return;
        _installOutputScroll.jumpTo(
          _installOutputScroll.position.maxScrollExtent,
        );
      });
    }
    final s = _dsh.status.value;
    if (s == DshStatus.idle || s == DshStatus.running) {
      unawaited(_refreshLocalFromService());
    }
  }

  Future<void> _refreshLocalFromService() async {
    try {
      final local = await _dsh.localVersion();
      if (!mounted || local == _localVersion) return;
      setState(() => _localVersion = local);
      if (local != null && local.isNotEmpty) {
        unawaited(_refreshFullRuntimeStatus());
      }
    } catch (_) {}
  }

  /// 任意设置变更都要刷新本页（开关读的是 shiyi.settings）。
  void _onShiyiEngineChanged() {
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _initVersions() async {
    String? local;
    try {
      local = await _dsh.localVersion();
    } catch (_) {}
    if (!mounted) return;
    // 先落本地安装状态，再异步查运行与最新版本，避免状态行等网络检查。
    setState(() => _localVersion = local);
    unawaited(_refreshStatus());
    if (local != null && local.isNotEmpty) {
      unawaited(_refreshFullRuntimeStatus());
    }
    String? latest;
    try {
      latest = await _dsh.checkLatestVersion();
    } catch (_) {}
    // 代理检测（供网络行显示）。
    try {
      await NetworkProxyDetector.instance.detect();
    } catch (_) {}
    if (!mounted) return;
    setState(() => _latestVersion = latest);
  }

  Future<void> _refreshStatus() async {
    await _dsh.refreshStatus();
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _refreshFullRuntimeStatus() async {
    if (!Platform.isAndroid ||
        _localVersion == null ||
        _localVersion!.isEmpty ||
        _checkingFullRuntime) {
      return;
    }
    setState(() => _checkingFullRuntime = true);
    var ready = false;
    try {
      ready = await _dsh.isFullAndroidRuntimeReady();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _checkingFullRuntime = false;
      _fullRuntimeReady = ready;
    });
  }

  String get _proxyLabel {
    final p = NetworkProxyDetector.instance.detected.value;
    if (p == null) return '未检测到（直连 + 镜像兜底）';
    return '${p.url}（${p.source == 'system' ? '系统代理' : '端口探测'}）';
  }

  Future<void> _checkUpdate() async {
    setState(() {
      _checking = true;
      _workError = null;
    });
    try {
      final latest = await _dsh.checkLatestVersion();
      final local = await _dsh.localVersion();
      if (!mounted) return;
      setState(() {
        _latestVersion = latest;
        _localVersion = local;
        _checking = false;
      });
      if (latest == null) {
        _showInfo('无法连接 npm registry，请稍后再试');
        return;
      }
      if (local == null) {
        _showInfo('检测到最新版本 $latest，点击「立即安装」开始安装');
        return;
      }
      if (DshService.compareSemver(latest, local) > 0) {
        _showInfo('发现新版本 $latest（当前 $local）');
      } else {
        _showInfo('当前已是最新版本 $local');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _workError = '$e';
      });
    }
  }

  Future<void> _installOrUpdate() async {
    var latest = _latestVersion;
    if (latest == null) {
      // 未检测到版本时先查一次，避免点了「立即安装」后只弹提示还要再点。
      setState(() {
        _working = true;
        _workError = null;
        _showInstallOutput = true;
      });
      try {
        latest = await _dsh.checkLatestVersion();
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _working = false;
          _workError = '$e';
          _showInstallOutput = true;
        });
        return;
      }
      if (latest == null) {
        if (!mounted) return;
        setState(() => _working = false);
        _showInfo('无法连接 npm registry，请稍后再试');
        return;
      }
      if (!mounted) return;
      setState(() => _latestVersion = latest);
    }
    final isUpdate =
        _localVersion != null &&
        DshService.compareSemver(latest, _localVersion!) > 0;
    setState(() {
      _working = true;
      _workError = null;
      _showInstallOutput = true;
    });
    try {
      await _dsh.installOrUpdate(latest, isUpdate: isUpdate);
      if (!mounted) return;
      setState(() {
        _localVersion = latest;
        _working = false;
      });
      if (_engine != 'dsh') _select('dsh');
      unawaited(_refreshFullRuntimeStatus());
      unawaited(_refreshStatus());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _workError = '$e';
        _showInstallOutput = true;
      });
    }
  }

  Future<void> _startService() async {
    setState(() {
      _workError = null;
      _showInstallOutput = true;
    });
    // 启动前先落盘合法配置：修复上次残留的非法 credentials/settings
    // YAML（如 API key 含换行），否则 DSH 启动即崩（invalid document）。
    await DshModelSync.syncFromShiyi(widget.shiyi.settings);
    await _dsh.start();
  }

  Future<void> _repairFullMode() async {
    setState(() {
      _working = true;
      _workError = null;
      _showInstallOutput = true;
    });
    try {
      final repaired = await _dsh.repairFullAndroidRuntime();
      if (!mounted) return;
      setState(() {
        _working = false;
        _fullRuntimeReady = true;
      });
      _showInfo(
        repaired ? '完整运行环境已修复，可重新启动 DeepSeek Harness' : '完整运行环境正常，无需修复',
      );
      unawaited(_refreshStatus());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _fullRuntimeReady = false;
        _workError = '$e';
      });
    }
  }

  Future<void> _stopService() async {
    await _dsh.stop();
  }

  void _confirmUninstall() {
    if (!mounted) return;
    showIosFadeDialog<void>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('卸载 DeepSeek Harness'),
        content: const Text('将卸载 npm 全局包，数据目录 .dsh 会保留。确定继续吗？'),
        actions: [
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.pop(ctx);
              unawaited(_uninstallDsh());
            },
            child: const Text('卸载'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Future<void> _uninstallDsh() async {
    setState(() {
      _working = true;
      _workError = null;
    });
    try {
      await _dsh.uninstall();
      if (!mounted) return;
      setState(() {
        _localVersion = null;
        _latestVersion = null;
        _fullRuntimeReady = null;
        _working = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _workError = '$e';
      });
    }
  }

  void _showInfo(String msg) {
    if (!mounted) return;
    showIosFadeDialog<void>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('DeepSeek Harness 服务'),
        content: Text(msg),
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

  void _select(String v) {
    if (_engine == v) return;
    FocusScope.of(context).unfocus();
    setState(() => _engine = v);
    _save.schedule();
    // 上级菜单也跟随引擎：把设置页路由换成对应引擎的设置根页，
    // 返回时直接看到新引擎的菜单，而不是旧引擎的设置中心。
    final route = ModalRoute.of(context);
    final nav = Navigator.of(context);
    if (route != null && nav.canPop()) {
      nav.replaceRouteBelow<dynamic>(
        anchorRoute: route,
        newRoute: MacPageRoute(
          builder: (_) => v == 'dsh'
              ? DshCenterScreen(shiyi: widget.shiyi)
              : SettingsScreen(shiyi: widget.shiyi),
        ),
      );
    }
    // 引擎切换需立即落盘，不等防抖；返回主页后由主页按新引擎渲染 tab。
    unawaited(() async {
      await _save.flush();
      if (widget.shiyi.settings.agentEngine == 'dsh') {
        await DshModelSync.injectNow(widget.shiyi.settings);
      }
    }());
  }

  String _statusLabel(DshStatus s) {
    switch (s) {
      case DshStatus.installing:
        return '安装中…';
      case DshStatus.updating:
        return '更新中…';
      case DshStatus.starting:
        return '启动中…';
      case DshStatus.running:
        return '运行中';
      case DshStatus.stopping:
        return '停止中…';
      case DshStatus.uninstalling:
        return '卸载中…';
      case DshStatus.error:
        return '异常';
      default:
        return '未运行';
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = _isDark(context, widget.shiyi.settings.themeMode);
    final s = widget.shiyi.settings;
    final dshStatus = _dsh.status.value;
    final busy =
        dshStatus == DshStatus.installing ||
        dshStatus == DshStatus.updating ||
        dshStatus == DshStatus.starting ||
        dshStatus == DshStatus.stopping ||
        dshStatus == DshStatus.uninstalling ||
        _checking ||
        _working;
    final hasUpdate =
        _latestVersion != null &&
        _localVersion != null &&
        DshService.compareSemver(_latestVersion!, _localVersion!) > 0;
    final installed = _localVersion != null && _localVersion!.isNotEmpty;
    final fullRuntimeSubtitle = _checkingFullRuntime
        ? '正在检查 node-pty 与 koffi…'
        : _fullRuntimeReady == true
        ? '运行环境正常，无需修复'
        : _fullRuntimeReady == false
        ? '运行环境异常，点击修复'
        : '检查并修复 node-pty、koffi 与旧禁用补丁';
    return _IosSettingsPage(
      shiyi: widget.shiyi,
      title: 'Agent 引擎',
      children: [
        CupertinoListSection.insetGrouped(
          decoration: _iosSectionDecoration(dark),
          backgroundColor: _iosGroupedBackground(dark),
          header: const Text('选择引擎'),
          children: [
            _BackendRow(
              icon: CupertinoIcons.chat_bubble_2_fill,
              color: _iosBlue,
              title: '拾忆（本地引擎）',
              subtitle: '跨会话记忆、技能沉淀与工具调用',
              selected: _engine == 'shiyi',
              onTap: () => _select('shiyi'),
            ),
            _BackendRow(
              icon: CupertinoIcons.sparkles,
              color: _iosIndigo,
              title: 'DeepSeek Harness',
              subtitle: '连接本机 DeepSeek Harness 服务（127.0.0.1:3080）',
              selected: _engine == 'dsh',
              onTap: () => _select('dsh'),
            ),
          ],
        ),
        CupertinoListSection.insetGrouped(
          decoration: _iosSectionDecoration(dark),
          backgroundColor: _iosGroupedBackground(dark),
          header: const Text('DeepSeek Harness 服务'),
          children: [
            _ServiceRow(label: '本地版本', value: _localVersion ?? '未安装'),
            _ServiceRow(
              label: '最新版本',
              value: _checking ? '检查中…' : (_latestVersion ?? '未检测'),
            ),
            _ServiceRow(
              label: '服务状态',
              value: installed ? _statusLabel(dshStatus) : '未安装',
            ),
            _ServiceRow(label: '网络代理', value: _proxyLabel),
            if (busy || _workError != null || _showInstallOutput)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (busy) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: _dsh.progress.value > 0
                              ? _dsh.progress.value.clamp(0.0, 1.0)
                              : null,
                          minHeight: 6,
                          backgroundColor: dark
                              ? const Color(0xFF3A3A3C)
                              : const Color(0xFFE5E5EA),
                          color: _iosBlue,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _dsh.statusMessage.value.isEmpty
                                  ? '准备中…'
                                  : _dsh.statusMessage.value,
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.3,
                                color: dark
                                    ? CupertinoColors.white.withValues(
                                        alpha: .65,
                                      )
                                    : CupertinoColors.black.withValues(
                                        alpha: .55,
                                      ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${(_dsh.progress.value * 100).round()}%',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: dark
                                  ? CupertinoColors.white.withValues(alpha: .8)
                                  : CupertinoColors.black.withValues(alpha: .7),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                    ],
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(
                        () => _showInstallOutput = !_showInstallOutput,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _showInstallOutput
                                ? CupertinoIcons.chevron_down
                                : CupertinoIcons.chevron_right,
                            size: 13,
                            color: CupertinoColors.systemGrey,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _showInstallOutput ? '隐藏终端输出' : '显示终端输出',
                            style: const TextStyle(
                              fontSize: 13,
                              color: CupertinoColors.systemGrey,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_showInstallOutput) ...[
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        constraints: const BoxConstraints(maxHeight: 240),
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                        decoration: BoxDecoration(
                          color: dark
                              ? const Color(0xFF1C1C1E)
                              : const Color(0xFFF2F2F7),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: SingleChildScrollView(
                          controller: _installOutputScroll,
                          child: Text(
                            _dsh.installOutput.value.isEmpty
                                ? '等待终端输出…'
                                : _dsh.installOutput.value,
                            style: TextStyle(
                              fontFamily: 'Menlo',
                              fontFamilyFallback: const [
                                'Courier',
                                'monospace',
                              ],
                              fontSize: 11,
                              height: 1.45,
                              color: dark
                                  ? const Color(0xFFD1D1D6)
                                  : const Color(0xFF3A3A3C),
                            ),
                          ),
                        ),
                      ),
                    ],
                    if (_workError != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _workError!,
                        style: const TextStyle(
                          fontSize: 13,
                          color: CupertinoColors.systemRed,
                        ),
                      ),
                    ],
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
                icon: installed
                    ? CupertinoIcons.trash_fill
                    : CupertinoIcons.arrow_down_circle,
                color: installed ? _iosRed : _iosBlue,
              ),
              // 未安装 = 安装；安装完成后同一入口变为卸载（保留 .dsh 数据）。
              title: Text(installed ? '卸载 DeepSeek Harness' : '立即安装'),
              subtitle: Text(
                installed
                    ? '卸载 npm 全局包，保留 .dsh 数据'
                    : '从 npm 拉取安装，首次含 Node.js 与编译工具链，可能要几分钟',
              ),
              onTap: busy
                  ? null
                  : installed
                  ? _confirmUninstall
                  : _installOrUpdate,
            ),
            if (installed)
              CupertinoListTile(
                leading: _IosIconTile(
                  icon: CupertinoIcons.refresh,
                  color: _iosTeal,
                ),
                // 已安装时检测新版；有新版本时同一入口变为「立即更新」。
                title: Text(hasUpdate ? '立即更新到 $_latestVersion' : '检查更新'),
                subtitle: Text(hasUpdate ? '有新版本可用' : '检测 npm 最新版本'),
                onTap: busy
                    ? null
                    : hasUpdate
                    ? _installOrUpdate
                    : _checkUpdate,
              ),
            CupertinoListTile(
              leading: _IosIconTile(
                icon: CupertinoIcons.power,
                color: dshStatus == DshStatus.running ? _iosGreen : _iosGray,
              ),
              title: Text(dshStatus == DshStatus.running ? '停止服务' : '启动服务'),
              subtitle: Text(
                installed
                    ? 'dsh web（127.0.0.1:3080）'
                    : '未安装 DeepSeek Harness，请先安装',
              ),
              onTap: busy
                  ? null
                  : !installed
                  ? () => _showInfo('DeepSeek Harness 未安装，请先点击「立即安装」')
                  : dshStatus == DshStatus.running
                  ? _stopService
                  : _startService,
            ),
            if (installed && Platform.isAndroid)
              CupertinoListTile(
                leading: _IosIconTile(
                  icon: CupertinoIcons.wrench,
                  color: _iosOrange,
                ),
                title: const Text('修复完整运行环境'),
                subtitle: Text(fullRuntimeSubtitle),
                onTap: busy || _checkingFullRuntime ? null : _repairFullMode,
              ),
            CupertinoListTile(
              leading: const Icon(
                CupertinoIcons.bell_fill,
                color: CupertinoColors.systemGrey,
              ),
              title: const Text('自动检查更新'),
              subtitle: const Text('进入 DeepSeek Harness 模式时检测，发现新版会提示'),
              trailing: CupertinoSwitch(
                value: s.dshAutoCheckUpdate,
                onChanged: (v) {
                  unawaited(
                    widget.shiyi.updateSettings(
                      s.copyWith(dshAutoCheckUpdate: v),
                    ),
                  );
                },
              ),
            ),
            CupertinoListTile(
              leading: const Icon(
                CupertinoIcons.globe,
                color: CupertinoColors.systemGreen,
              ),
              title: const Text('自动使用代理'),
              subtitle: const Text('安装/更新 DeepSeek Harness 时自动检测系统代理或本地代理端口'),
              trailing: CupertinoSwitch(
                value: s.dshUseProxy,
                onChanged: (v) {
                  DshService.instance.useProxyEnabled = v;
                  unawaited(
                    widget.shiyi.updateSettings(s.copyWith(dshUseProxy: v)),
                  );
                },
              ),
            ),
          ],
        ),
        LaapServicePanel(
          enablePresence: s.enablePresence,
          onPresenceChanged: (v) {
            unawaited(
              widget.shiyi.updateSettings(s.copyWith(enablePresence: v)),
            );
          },
        ),
        CupertinoListSection.insetGrouped(
          decoration: _iosSectionDecoration(dark),
          backgroundColor: _iosGroupedBackground(dark),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Text(
                '切换引擎后，会话页将使用对应引擎的会话与对话数据，'
                '两套数据完全独立、互不影响。DeepSeek Harness 通过 npm 官方包安装与更新'
                '（与 deepseek-harness 源码同步发布）。',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: dark
                      ? CupertinoColors.white.withValues(alpha: .6)
                      : CupertinoColors.black.withValues(alpha: .55),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// DeepSeek Harness 服务信息行（标签 + 值）。
class _ServiceRow extends StatelessWidget {
  final String label;
  final String value;
  const _ServiceRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Text(label, style: const TextStyle(fontSize: 15)),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).brightness == Brightness.dark
                  ? CupertinoColors.white.withValues(alpha: .8)
                  : CupertinoColors.black.withValues(alpha: .7),
            ),
          ),
        ],
      ),
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

class _Socks5SectionPage extends StatefulWidget {
  final ShiyiState shiyi;
  const _Socks5SectionPage({required this.shiyi});

  @override
  State<_Socks5SectionPage> createState() => _Socks5SectionPageState();
}

class _Socks5SectionPageState extends State<_Socks5SectionPage> {
  late String _mode;
  late List<Socks5Server> _servers;
  late String _activeId;
  late final TextEditingController _hostCtrl;
  late final TextEditingController _portCtrl;
  late final TextEditingController _userCtrl;
  late final TextEditingController _passCtrl;
  late final _DebouncedSave _save;
  bool _showPass = false;
  bool _detecting = false;
  String? _detectHint;

  @override
  void initState() {
    super.initState();
    final s = widget.shiyi.settings;
    _mode = Socks5Endpoint.modeOf(s);
    _servers = [...s.socks5Servers];
    _activeId = s.socks5ActiveId;
    _hostCtrl = TextEditingController(text: s.socks5Host);
    _portCtrl = TextEditingController(text: '${s.socks5Port}');
    _userCtrl = TextEditingController(text: s.socks5User);
    _passCtrl = TextEditingController(text: s.socks5Password);
    _save = _DebouncedSave(widget.shiyi, _build);
    if (_mode == 'auto') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_detect(silent: true));
      });
    }
  }

  AppSettings _build() {
    final parsed = int.tryParse(_portCtrl.text.trim()) ?? 1080;
    return widget.shiyi.settings.copyWith(
      socks5Enabled: _mode != 'off',
      socks5Mode: _mode,
      socks5Host: _hostCtrl.text.trim(),
      socks5Port: parsed.clamp(1, 65535),
      socks5User: _userCtrl.text.trim(),
      socks5Password: _passCtrl.text,
      socks5Servers: _servers,
      socks5ActiveId: _activeId,
    );
  }

  @override
  void dispose() {
    if (_save.hasPending) unawaited(_save.flush());
    _save.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  void _setMode(String mode) {
    setState(() {
      _mode = mode;
      if (mode == 'auto') _detectHint = null;
    });
    _save.schedule();
    if (mode == 'auto') unawaited(_detect());
  }

  Future<void> _detect({bool silent = false}) async {
    if (_detecting) return;
    setState(() {
      _detecting = true;
      if (!silent) _detectHint = '正在扫描本机 Clash / V2Ray / SS…';
    });
    final found = await Socks5LocalProbe.detect();
    if (!mounted) return;
    setState(() {
      _detecting = false;
      if (found == null) {
        _detectHint = '没扫到本机 SOCKS5。确认 Clash 已开，mixed/socks 口在 7890/7891。';
      } else {
        _detectHint = '已检测到 127.0.0.1:${found.port}，对话和搜索会走它。';
      }
    });
  }

  void _applyPasted(String raw) {
    final ep = Socks5Endpoint.parse(raw);
    if (ep == null) return;
    setState(() {
      _hostCtrl.text = ep.host;
      _portCtrl.text = '${ep.port}';
      if (ep.username != null) _userCtrl.text = ep.username!;
      if (ep.password != null) _passCtrl.text = ep.password!;
    });
    _syncActiveFromFields();
    _save.schedule();
  }

  void _syncActiveFromFields() {
    if (_activeId.isEmpty) return;
    final port = int.tryParse(_portCtrl.text.trim()) ?? 1080;
    setState(() {
      _servers = [
        for (final e in _servers)
          if (e.id == _activeId)
            e.copyWith(
              host: _hostCtrl.text.trim(),
              port: port.clamp(1, 65535),
              user: _userCtrl.text.trim(),
              password: _passCtrl.text,
            )
          else
            e,
      ];
    });
  }

  Future<void> _addOrEditServer({Socks5Server? existing}) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final hostCtrl = TextEditingController(text: existing?.host ?? '');
    final portCtrl = TextEditingController(text: '${existing?.port ?? 1080}');
    final userCtrl = TextEditingController(text: existing?.user ?? '');
    final passCtrl = TextEditingController(text: existing?.password ?? '');
    var showPass = false;
    final ok = await showIosFadeDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) {
          final dark = CupertinoTheme.brightnessOf(ctx) == Brightness.dark;
          final fieldFill = dark
              ? const Color(0xFF2C2C2E)
              : const Color(0xFFF2F2F7);
          Widget field(
            String placeholder,
            TextEditingController c, {
            bool obscure = false,
            TextInputType? keyboard,
            ValueChanged<String>? onChanged,
          }) {
            return Padding(
              padding: const EdgeInsets.only(top: 8),
              child: CupertinoTextField(
                controller: c,
                placeholder: placeholder,
                obscureText: obscure,
                keyboardType: keyboard,
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: fieldFill,
                  borderRadius: BorderRadius.circular(8),
                ),
                onChanged: onChanged,
              ),
            );
          }

          return CupertinoAlertDialog(
            title: Text(existing == null ? '添加代理服务器' : '编辑代理服务器'),
            content: Column(
              children: [
                const SizedBox(height: 8),
                field('名称（可空，如 机场 A）', nameCtrl),
                field(
                  '主机 或 socks5://user:pass@host:port',
                  hostCtrl,
                  onChanged: (v) {
                    final ep = Socks5Endpoint.parse(v);
                    if (ep == null) return;
                    hostCtrl.text = ep.host;
                    portCtrl.text = '${ep.port}';
                    if (ep.username != null) userCtrl.text = ep.username!;
                    if (ep.password != null) passCtrl.text = ep.password!;
                  },
                ),
                field('端口', portCtrl, keyboard: TextInputType.number),
                field('用户名（可空）', userCtrl),
                field('密码（可空）', passCtrl, obscure: !showPass),
                Align(
                  alignment: Alignment.centerRight,
                  child: CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () => setDlg(() => showPass = !showPass),
                    child: Text(showPass ? '隐藏密码' : '显示密码'),
                  ),
                ),
              ],
            ),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              CupertinoDialogAction(
                isDefaultAction: true,
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('保存'),
              ),
            ],
          );
        },
      ),
    );
    final name = nameCtrl.text;
    final hostRaw = hostCtrl.text;
    final portRaw = portCtrl.text;
    final user = userCtrl.text;
    final pass = passCtrl.text;
    nameCtrl.dispose();
    hostCtrl.dispose();
    portCtrl.dispose();
    userCtrl.dispose();
    passCtrl.dispose();
    if (ok != true || !mounted) return;
    var host = hostRaw.trim();
    var port = int.tryParse(portRaw.trim()) ?? 1080;
    var username = user.trim();
    var password = pass;
    final pasted = Socks5Endpoint.parse(host);
    if (pasted != null) {
      host = pasted.host;
      port = pasted.port;
      username = pasted.username ?? username;
      password = pasted.password ?? password;
    }
    if (host.isEmpty) {
      await _showIosAlert(context, '提示', '请填写主机，例如 127.0.0.1 或代理域名');
      return;
    }
    final server = Socks5Server(
      id:
          existing?.id ??
          DateTime.now().microsecondsSinceEpoch.toRadixString(16),
      name: name.trim(),
      host: host,
      port: port.clamp(1, 65535),
      user: username,
      password: password,
    );
    setState(() {
      if (existing == null) {
        _servers = [..._servers, server];
      } else {
        _servers = [for (final e in _servers) e.id == server.id ? server : e];
      }
      _activeId = server.id;
      _hostCtrl.text = server.host;
      _portCtrl.text = '${server.port}';
      _userCtrl.text = server.user;
      _passCtrl.text = server.password;
      _mode = 'custom';
    });
    _save.schedule();
  }

  void _selectServer(Socks5Server server) {
    setState(() {
      _activeId = server.id;
      _hostCtrl.text = server.host;
      _portCtrl.text = '${server.port}';
      _userCtrl.text = server.user;
      _passCtrl.text = server.password;
      _mode = 'custom';
    });
    _save.schedule();
  }

  Future<void> _deleteServer(Socks5Server server) async {
    final ok = await showIosFadeDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('删除这台代理？'),
        content: Text(server.label),
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
      _servers = [
        for (final e in _servers)
          if (e.id != server.id) e,
      ];
      if (_activeId == server.id) {
        _activeId = _servers.isEmpty ? '' : _servers.first.id;
        if (_servers.isNotEmpty) {
          final n = _servers.first;
          _hostCtrl.text = n.host;
          _portCtrl.text = '${n.port}';
          _userCtrl.text = n.user;
          _passCtrl.text = n.password;
        }
      }
    });
    _save.schedule();
  }

  @override
  Widget build(BuildContext context) {
    final dark = _isDark(context, widget.shiyi.settings.themeMode);
    return _IosSettingsPage(
      shiyi: widget.shiyi,
      title: 'SOCKS5 代理',
      children: [
        CupertinoListSection.insetGrouped(
          decoration: _iosSectionDecoration(dark),
          backgroundColor: _iosGroupedBackground(dark),
          header: const Text('通道'),
          footer: _iosSectionFooter(
            '国内 IP 被中转站拦截时走 SOCKS5。本机开了 Clash / FlClash / V2RayN 选自动检测；'
            '境外代理填自定义。对话、拉模型和联网搜索都会走这条通道。',
          ),
          children: [
            CupertinoListTile(
              leading: const _IosIconTile(
                icon: CupertinoIcons.xmark_circle_fill,
                color: _iosGray,
              ),
              title: const Text('关闭（直连）'),
              trailing: _mode == 'off'
                  ? const Icon(
                      CupertinoIcons.checkmark_circle_fill,
                      color: CupertinoColors.activeBlue,
                    )
                  : null,
              onTap: () => _setMode('off'),
            ),
            CupertinoListTile(
              leading: const _IosIconTile(
                icon: CupertinoIcons.antenna_radiowaves_left_right,
                color: _iosTeal,
              ),
              title: const Text('自动检测本机代理'),
              subtitle: const Text('扫描 Clash mixed/socks、V2RayN、SS 常见端口'),
              trailing: _mode == 'auto'
                  ? const Icon(
                      CupertinoIcons.checkmark_circle_fill,
                      color: CupertinoColors.activeBlue,
                    )
                  : null,
              onTap: () => _setMode('auto'),
            ),
            CupertinoListTile(
              leading: const _IosIconTile(
                icon: CupertinoIcons.lock_shield_fill,
                color: _iosBlue,
              ),
              title: const Text('自定义代理服务器'),
              subtitle: const Text('手动填写或粘贴 socks5://…'),
              trailing: _mode == 'custom'
                  ? const Icon(
                      CupertinoIcons.checkmark_circle_fill,
                      color: CupertinoColors.activeBlue,
                    )
                  : null,
              onTap: () => _setMode('custom'),
            ),
          ],
        ),
        if (_mode == 'auto')
          CupertinoListSection.insetGrouped(
            decoration: _iosSectionDecoration(dark),
            backgroundColor: _iosGroupedBackground(dark),
            header: const Text('本机'),
            footer: _iosSectionFooter(
              _detectHint ??
                  '会探测 127.0.0.1 的 7890 / 7891 / 7897 / 10808 / 1080。'
                      '手机上 Clash 需开允许局域网，地址填电脑 IP。',
            ),
            children: [
              CupertinoListTile(
                leading: _IosIconTile(
                  icon: _detecting
                      ? CupertinoIcons.hourglass
                      : CupertinoIcons.search,
                  color: _iosTeal,
                ),
                title: Text(_detecting ? '正在扫描…' : '重新扫描'),
                subtitle: const Text('Clash 改端口后点这里刷新'),
                onTap: _detecting ? null : () => _detect(),
              ),
            ],
          ),
        if (_mode == 'custom') ...[
          CupertinoListSection.insetGrouped(
            decoration: _iosSectionDecoration(dark),
            backgroundColor: _iosGroupedBackground(dark),
            header: const Text('已保存的服务器'),
            children: [
              if (_servers.isEmpty)
                const CupertinoListTile(
                  title: Text('还没有服务器'),
                  subtitle: Text('点下面添加，或直接填主机端口当临时通道'),
                ),
              for (final server in _servers)
                CupertinoListTile(
                  leading: _IosIconTile(
                    icon: server.id == _activeId
                        ? CupertinoIcons.checkmark_seal_fill
                        : CupertinoIcons.globe,
                    color: server.id == _activeId ? _iosGreen : _iosBlue,
                  ),
                  title: Text(server.label),
                  subtitle: Text(
                    '${server.host}:${server.port}'
                    '${server.user.isEmpty ? '' : '  ·  ${server.user}'}',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CupertinoButton(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(28, 28),
                        onPressed: () => _addOrEditServer(existing: server),
                        child: const Icon(
                          CupertinoIcons.pencil,
                          size: 20,
                          color: CupertinoColors.activeBlue,
                        ),
                      ),
                      CupertinoButton(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(28, 28),
                        onPressed: () => _deleteServer(server),
                        child: const Icon(
                          CupertinoIcons.delete,
                          size: 20,
                          color: CupertinoColors.systemRed,
                        ),
                      ),
                    ],
                  ),
                  onTap: () => _selectServer(server),
                ),
              CupertinoListTile(
                leading: const _IosIconTile(
                  icon: CupertinoIcons.add_circled_solid,
                  color: _iosGreen,
                ),
                title: const Text('添加代理服务器'),
                subtitle: const Text('支持粘贴 socks5://user:pass@host:port'),
                onTap: () => _addOrEditServer(),
              ),
            ],
          ),
          CupertinoListSection.insetGrouped(
            decoration: _iosSectionDecoration(dark),
            backgroundColor: _iosGroupedBackground(dark),
            header: const Text('当前通道'),
            footer: _iosSectionFooter('没选已保存服务器时，用下面这组临时填写。也可直接把完整 URL 贴进主机栏。'),
            children: [
              _IosTextFieldTile(
                icon: CupertinoIcons.globe,
                color: _iosBlue,
                title: '主机',
                controller: _hostCtrl,
                placeholder: '127.0.0.1 或 socks5://user:pass@host:1080',
                onChanged: (v) {
                  _applyPasted(v);
                  _save.schedule();
                },
              ),
              CupertinoListTile(
                leading: const _IosIconTile(
                  icon: CupertinoIcons.number,
                  color: _iosIndigo,
                ),
                title: const Text('端口'),
                trailing: _IosValueField(
                  controller: _portCtrl,
                  keyboardType: TextInputType.number,
                  width: 90,
                  onChanged: (_) {
                    _syncActiveFromFields();
                    _save.schedule();
                  },
                ),
              ),
              _IosTextFieldTile(
                icon: CupertinoIcons.person,
                color: _iosPurple,
                title: '用户名',
                controller: _userCtrl,
                placeholder: '可空',
                onChanged: (_) {
                  _syncActiveFromFields();
                  _save.schedule();
                },
              ),
              _IosSecretFieldTile(
                icon: CupertinoIcons.lock,
                color: _iosOrange,
                title: '密码',
                controller: _passCtrl,
                placeholder: '可空',
                obscure: !_showPass,
                onToggleVisibility: () =>
                    setState(() => _showPass = !_showPass),
                onChanged: (_) {
                  _syncActiveFromFields();
                  _save.schedule();
                },
              ),
            ],
          ),
        ],
      ],
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
                                  : CupertinoColors.black.withValues(
                                      alpha: .45,
                                    )),
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
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final secondary = dark
        ? CupertinoColors.white.withValues(alpha: .58)
        : CupertinoColors.black.withValues(alpha: .52);
    final fieldFill = dark ? const Color(0xFF2C2C2E) : const Color(0xFFF2F2F7);
    return CupertinoListTile(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      leading: _IosIconTile(icon: icon, color: color),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: dark ? CupertinoColors.white : CupertinoColors.black,
            ),
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: CupertinoTextField(
              controller: controller,
              placeholder: placeholder,
              style: TextStyle(
                color: dark ? CupertinoColors.white : CupertinoColors.black,
              ),
              placeholderStyle: TextStyle(color: secondary),
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
              decoration: BoxDecoration(
                color: fieldFill,
                borderRadius: BorderRadius.circular(8),
              ),
              onChanged: onChanged,
            ),
          ),
        ],
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
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final secondary = dark
        ? CupertinoColors.white.withValues(alpha: .58)
        : CupertinoColors.black.withValues(alpha: .52);
    final fieldFill = dark ? const Color(0xFF2C2C2E) : const Color(0xFFF2F2F7);
    return CupertinoListTile(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      leading: _IosIconTile(icon: icon, color: color),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: dark ? CupertinoColors.white : CupertinoColors.black,
            ),
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: CupertinoTextField(
              controller: controller,
              placeholder: placeholder,
              obscureText: obscure,
              style: TextStyle(
                color: dark ? CupertinoColors.white : CupertinoColors.black,
              ),
              placeholderStyle: TextStyle(color: secondary),
              padding: const EdgeInsets.fromLTRB(11, 10, 62, 10),
              decoration: BoxDecoration(
                color: fieldFill,
                borderRadius: BorderRadius.circular(8),
              ),
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
        ],
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

class _SectionHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  const _SectionHeader({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final secondary = dark
        ? CupertinoColors.white.withValues(alpha: .52)
        : CupertinoColors.black.withValues(alpha: .48);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: dark
                  ? CupertinoColors.white.withValues(alpha: .72)
                  : CupertinoColors.black.withValues(alpha: .62),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w400,
              color: secondary,
            ),
          ),
        ],
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
