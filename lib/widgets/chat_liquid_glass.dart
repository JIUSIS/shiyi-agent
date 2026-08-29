import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:path/path.dart' as p;

const _iosBlue = Color(0xFF0A84FF);
const _iosRed = Color(0xFFFF3B30);

LiquidGlassStyle chatLiquidGlassStyle(
  BuildContext context, {
  double cornerRadius = 16,
  Color? tint,
}) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return LiquidGlassStyle(
    shape: LiquidGlassShape.continuousRoundedRectangle(
      cornerRadius: cornerRadius,
      borderWidth: 1,
      borderColor: Colors.white.withValues(alpha: dark ? .14 : .48),
      lightIntensity: .78,
      lightDirection: 110,
    ),
    appearance: LiquidGlassAppearance(
      color: tint ?? (dark ? const Color(0x403A3A3C) : const Color(0x48FFFFFF)),
      blur: const LiquidGlassBlur(sigmaX: 14, sigmaY: 14),
      saturation: 1.1,
    ),
    refraction: const LiquidGlassRefraction(
      distortion: .05,
      distortionWidth: 18,
      magnification: 1.008,
      chromaticAberration: .001,
    ),
  );
}

/// 液态玻璃抽屉的弹层路由：透明屏障 + 零过渡，把抽屉放进导航栈。
///
/// 系统返回键 / 手势返回会先落在抽屉路由上：这里拦截后先播收合动画再移除，
/// 不会直接弹出整个页面；抽屉内容仍由各选择器自行构建。选择器内部状态
/// （如模型抽屉的二级菜单）变化时，调用 [markNeedsBuild] 重建抽屉内容。
class LiquidGlassPopupRoute<T> extends PopupRoute<T> {
  LiquidGlassPopupRoute({required this.builder, required this.onDismiss});

  final WidgetBuilder builder;
  final VoidCallback onDismiss;
  _LiquidGlassPopupBodyState? _bodyState;

  void markNeedsBuild() => _bodyState?.requestBuild();

  @override
  Color? get barrierColor => Colors.transparent;

  @override
  bool get barrierDismissible => false;

  @override
  String? get barrierLabel => null;

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  bool get opaque => false;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop) onDismiss();
      },
      child: _LiquidGlassPopupBody(
        builder: builder,
        onState: (state) => _bodyState = state,
      ),
    );
  }
}

class _LiquidGlassPopupBody extends StatefulWidget {
  const _LiquidGlassPopupBody({
    required this.builder,
    required this.onState,
  });

  final WidgetBuilder builder;
  final ValueChanged<_LiquidGlassPopupBodyState?> onState;

  @override
  State<_LiquidGlassPopupBody> createState() => _LiquidGlassPopupBodyState();
}

class _LiquidGlassPopupBodyState extends State<_LiquidGlassPopupBody> {
  @override
  void initState() {
    super.initState();
    widget.onState(this);
  }

  @override
  void dispose() {
    widget.onState(null);
    super.dispose();
  }

  void requestBuild() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

/// 消息列表铺满，底部输入区 / 状态条透明叠在上面。
/// 滑动时气泡能从液态玻璃后透出，玻璃底下不再垫一层 Scaffold 底色。
class ChatFloatingComposerScaffold extends StatefulWidget {
  final Widget Function(BuildContext context, double overlayHeight) messages;
  final Widget overlay;

  const ChatFloatingComposerScaffold({
    super.key,
    required this.messages,
    required this.overlay,
  });

  @override
  State<ChatFloatingComposerScaffold> createState() =>
      _ChatFloatingComposerScaffoldState();
}

class _ChatFloatingComposerScaffoldState
    extends State<ChatFloatingComposerScaffold> {
  double _overlayHeight = 148;
  final _overlayKey = GlobalKey();

  void _scheduleMeasure() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = _overlayKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final height = box.size.height;
      if ((height - _overlayHeight).abs() < 0.5) return;
      setState(() => _overlayHeight = height);
    });
  }

  @override
  Widget build(BuildContext context) {
    _scheduleMeasure();
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        widget.messages(context, _overlayHeight),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: NotificationListener<SizeChangedLayoutNotification>(
            onNotification: (_) {
              _scheduleMeasure();
              return true;
            },
            child: SizeChangedLayoutNotifier(
              child: KeyedSubtree(
                key: _overlayKey,
                child: ColoredBox(
                  color: Colors.transparent,
                  child: widget.overlay,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 输入区上方的提示胶囊：液态玻璃，不满宽铺实心底。
class ChatGlassNoticeBar extends StatelessWidget {
  final String text;
  final Color? tint;
  final Color? foreground;

  const ChatGlassNoticeBar({
    super.key,
    required this.text,
    this.tint,
    this.foreground,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
      child: LiquidGlassLens(
        style: chatLiquidGlassStyle(context, cornerRadius: 10, tint: tint),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text(
            text,
            textAlign: TextAlign.center,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall!.copyWith(
              fontSize: 12,
              color: foreground ?? theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// 拾忆与 DSH 共用的子代理运行状态条。
/// 只负责统一液态玻璃外观，状态文本和可见性由各引擎提供。
class SubagentStatusBar extends StatelessWidget {
  final String text;

  const SubagentStatusBar({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
      child: LiquidGlassLens(
        style: chatLiquidGlassStyle(context, cornerRadius: 10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall!.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// 思考强度选项。空字符串表示跟随提供商默认，`off` 表示显式关闭。
class ThinkingIntensityOption {
  final String value;
  final String label;

  const ThinkingIntensityOption(this.value, this.label);
}

/// 根据能力映射构建选项列表；兼容 DSH 的 `session.models` 格式和拾忆的
/// `LlmClient.reasoningEffortsForModel` 格式。
List<ThinkingIntensityOption> buildReasoningOptions(
  Map<String, String?> capabilities,
) {
  final options = <ThinkingIntensityOption>[];
  if (capabilities.containsKey('off')) {
    options.add(const ThinkingIntensityOption('', 'Default'));
  }
  if (capabilities.containsKey('low')) {
    options.add(const ThinkingIntensityOption('low', 'Low'));
  }
  if (capabilities.containsKey('medium')) {
    options.add(const ThinkingIntensityOption('medium', 'Medium'));
  }
  if (capabilities.containsKey('high')) {
    options.add(const ThinkingIntensityOption('high', 'High'));
  }
  if (capabilities.containsKey('xhigh')) {
    options.add(const ThinkingIntensityOption('xhigh', 'XHigh'));
  }
  if (capabilities.containsKey('max')) {
    options.add(const ThinkingIntensityOption('max', 'Max'));
  }
  return options;
}

/// 拾忆与 DSH 共用的思考强度选择器；只负责展示和回调，不持有引擎状态。
/// 以 iOS 工具栏控件呈现，从按钮上沿拉开未选项的液态玻璃抽屉。
class ThinkingIntensitySelector extends StatefulWidget {
  final List<ThinkingIntensityOption> options;
  final String value;
  final ValueChanged<String> onChanged;
  final bool enabled;

  const ThinkingIntensitySelector({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  State<ThinkingIntensitySelector> createState() =>
      _ThinkingIntensitySelectorState();
}

class _ThinkingIntensitySelectorState extends State<ThinkingIntensitySelector>
    with SingleTickerProviderStateMixin {
  final _buttonKey = GlobalKey();
  LiquidGlassPopupRoute<void>? _popup;
  Rect _anchor = Rect.zero;
  late final AnimationController _anim;
  late final Animation<double> _reveal;

  static const _gap = 6.0;
  static const _rowPadding = 28.0;
  static const _minMenuWidth = 56.0;
  static const _maxMenuWidth = 160.0;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      reverseDuration: const Duration(milliseconds: 160),
    );
    _reveal = CurvedAnimation(
      parent: _anim,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
  }

  bool get _isOpen => _popup != null;

  void _togglePopup() {
    if (_isOpen) {
      _dismissPopup();
    } else {
      _showPopup();
    }
  }

  Future<void> _dismissPopup() async {
    final route = _popup;
    if (route == null) return;
    _popup = null;
    if (mounted) setState(() {});
    if (_anim.value > 0) {
      try {
        await _anim.reverse();
      } catch (_) {}
    }
    if (route.isActive) {
      route.navigator?.removeRoute(route);
    }
  }

  void _showPopup() {
    if (_drawerOptions.isEmpty) return;
    final box = _buttonKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    _anchor = box.localToGlobal(Offset.zero) & box.size;
    HapticFeedback.selectionClick();
    _popup = LiquidGlassPopupRoute<void>(
      builder: _buildOverlay,
      onDismiss: () => unawaited(_dismissPopup()),
    );
    Navigator.of(context, rootNavigator: true).push(_popup!);
    _anim.forward(from: 0);
    setState(() {});
  }

  String get _selectedValue {
    if (widget.options.any((item) => item.value == widget.value)) {
      return widget.value;
    }
    return widget.options.first.value;
  }

  List<ThinkingIntensityOption> get _drawerOptions =>
      widget.options.where((item) => item.value != _selectedValue).toList();

  double _menuWidthFor(
    BuildContext context,
    List<ThinkingIntensityOption> items,
  ) {
    final style =
        Theme.of(
          context,
        ).textTheme.bodyLarge?.copyWith(fontSize: 15, letterSpacing: -0.24) ??
        const TextStyle(fontSize: 15, letterSpacing: -0.24);
    final painter = TextPainter(textDirection: TextDirection.ltr);
    var maxWidth = 0.0;
    for (final item in items) {
      painter.text = TextSpan(text: item.label, style: style);
      painter.layout();
      if (painter.width > maxWidth) maxWidth = painter.width;
    }
    painter.dispose();
    return (maxWidth + _rowPadding).clamp(_minMenuWidth, _maxMenuWidth);
  }

  Widget _buildOverlay(BuildContext overlayContext) {
    final dark = Theme.of(overlayContext).brightness == Brightness.dark;
    final mq = MediaQuery.of(overlayContext);
    final items = _drawerOptions;
    if (items.isEmpty) return const SizedBox.shrink();
    final menuWidth = _menuWidthFor(overlayContext, items);

    // 抽屉贴在按钮上沿，右对齐；空间不够时再夹回安全区内。
    final right = (mq.size.width - _anchor.right).clamp(
      8.0,
      (mq.size.width - menuWidth - 8.0).clamp(8.0, mq.size.width),
    );
    final bottom = (mq.size.height - _anchor.top + _gap).clamp(
      mq.padding.bottom + 8.0,
      mq.size.height - mq.padding.top - 48.0,
    );

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _dismissPopup,
          ),
        ),
        Positioned(
          right: right,
          bottom: bottom,
          width: menuWidth,
          child: Material(
            color: Colors.transparent,
            elevation: 12,
            shadowColor: Colors.black.withValues(alpha: dark ? .36 : .14),
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: SizeTransition(
              sizeFactor: _reveal,
              alignment: Alignment.bottomLeft,
              child: LiquidGlassLens(
                style: chatLiquidGlassStyle(overlayContext, cornerRadius: 14),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final item in items)
                        _ThinkingMenuRow(
                          label: item.label,
                          onTap: () {
                            HapticFeedback.selectionClick();
                            _dismissPopup();
                            widget.onChanged(item.value);
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    final route = _popup;
    _popup = null;
    if (route?.isActive == true) {
      route!.navigator?.removeRoute(route);
    }
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.options.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final selected = widget.options.any((item) => item.value == widget.value)
        ? widget.value
        : widget.options.first.value;
    final label = widget.options
        .firstWhere((item) => item.value == selected)
        .label;
    final accent = widget.enabled
        ? (_isOpen ? _iosBlue : theme.colorScheme.onSurfaceVariant)
        : theme.disabledColor;

    return Tooltip(
      message: '思考强度',
      child: GestureDetector(
        key: _buttonKey,
        onTap: widget.enabled ? _togglePopup : null,
        behavior: HitTestBehavior.opaque,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 160),
          opacity: widget.enabled ? 1 : 0.38,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 2, 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: accent,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.24,
                  ),
                ),
                const SizedBox(width: 1),
                Icon(
                  _isOpen
                      ? CupertinoIcons.chevron_down
                      : CupertinoIcons.chevron_up,
                  size: 11,
                  color: accent,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ThinkingMenuRow extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _ThinkingMenuRow({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        height: 36,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontSize: 15,
                fontWeight: FontWeight.w400,
                color: theme.colorScheme.onSurface,
                letterSpacing: -0.24,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 权限预设可选项（DSH permissionPresets 表；label 来自服务端 schema）。
class PermissionPresetOption {
  final String value;
  final String label;
  const PermissionPresetOption({required this.value, required this.label});
}

/// 固定宽度跑马灯标签：文本不超宽时静止左对齐；超宽时停在起点片刻、
/// 匀速滚到终点、停片刻、再滚回来，循环往复（iOS 状态栏标题风格）。
/// 用 OverflowBox 让文本按自然宽度绘制，外层 ClipRect 负责裁剪。
class AutoScrollLabel extends StatefulWidget {
  final String text;
  final TextStyle style;
  final double width;
  final Alignment alignment;

  const AutoScrollLabel({
    super.key,
    required this.text,
    required this.style,
    required this.width,
    this.alignment = Alignment.centerLeft,
  });

  @override
  State<AutoScrollLabel> createState() => _AutoScrollLabelState();
}

class _AutoScrollLabelState extends State<AutoScrollLabel>
    with SingleTickerProviderStateMixin {
  static const _hold = Duration(milliseconds: 900);
  static const _pxPerSecond = 22.0;

  late final AnimationController _controller;
  double _overflow = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
    _measure();
  }

  @override
  void didUpdateWidget(covariant AutoScrollLabel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _measure();
    }
  }

  void _measure() {
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      textDirection: TextDirection.ltr,
    )..layout();
    final overflow = painter.width - widget.width;
    painter.dispose();
    _overflow = overflow > 0 ? overflow : 0;
    if (_overflow <= 0) {
      _controller.stop();
      return;
    }
    final travel = _travelDuration();
    _controller
      ..duration = _hold + travel + _hold + travel
      ..repeat();
  }

  Duration _travelDuration() => Duration(
    milliseconds: (_overflow / _pxPerSecond * 1000).round().clamp(300, 6000),
  );

  /// 控制器进度 → 位移比例（0=起点，1=终点），两端各停 [hold]。
  double _offsetFraction() {
    if (_overflow <= 0) return 0;
    final travel = _travelDuration();
    final totalMs = (_hold + travel + _hold + travel).inMilliseconds;
    final at = Duration(
      milliseconds: (_controller.value * totalMs).round(),
    );
    final holdMs = _hold.inMilliseconds;
    final travelMs = travel.inMilliseconds;
    if (at.inMilliseconds <= holdMs) return 0;
    if (at.inMilliseconds <= holdMs + travelMs) {
      return Curves.easeInOut.transform(
        (at.inMilliseconds - holdMs) / travelMs,
      );
    }
    if (at.inMilliseconds <= holdMs + travelMs + holdMs) return 1;
    return 1 -
        Curves.easeInOut.transform(
          (at.inMilliseconds - holdMs - travelMs - holdMs) / travelMs,
        );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final height = (widget.style.fontSize ?? 14) * 1.25;
    if (_overflow <= 0) {
      return SizedBox(
        width: widget.width,
        height: height,
        child: Align(
          alignment: widget.alignment,
          child: Text(widget.text, style: widget.style, maxLines: 1),
        ),
      );
    }
    return SizedBox(
      width: widget.width,
      height: height,
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.centerLeft,
          maxWidth: double.infinity,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) => Transform.translate(
              offset: Offset(-_offsetFraction() * _overflow, 0),
              child: Text(
                widget.text,
                style: widget.style,
                maxLines: 1,
                softWrap: false,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// DSH 会话页的权限预设按钮。点击从按钮上沿拉开全量选项抽屉，当前项
/// 打勾；切换走 `/permission <preset>` 会话命令（typert commands/execute），
/// 对当前会话实时生效。与思考强度选择器同一套液态玻璃抽屉交互。
class PermissionPresetSelector extends StatefulWidget {
  final List<PermissionPresetOption> options;
  final String value;
  final ValueChanged<String> onChanged;
  final bool enabled;

  const PermissionPresetSelector({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  State<PermissionPresetSelector> createState() =>
      _PermissionPresetSelectorState();
}

class _PermissionPresetSelectorState extends State<PermissionPresetSelector>
    with SingleTickerProviderStateMixin {
  final _buttonKey = GlobalKey();
  LiquidGlassPopupRoute<void>? _popup;
  Rect _anchor = Rect.zero;
  late final AnimationController _anim;
  late final Animation<double> _reveal;

  static const _gap = 6.0;
  static const _maxMenuWidth = 260.0;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      reverseDuration: const Duration(milliseconds: 160),
    );
    _reveal = CurvedAnimation(
      parent: _anim,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
  }

  bool get _isOpen => _popup != null;

  String get _selectedLabel {
    for (final item in widget.options) {
      if (item.value == widget.value) return item.label;
    }
    return widget.value.isEmpty ? '权限' : widget.value;
  }

  void _togglePopup() {
    if (_isOpen) {
      _dismissPopup();
    } else {
      _showPopup();
    }
  }

  Future<void> _dismissPopup() async {
    final route = _popup;
    if (route == null) return;
    _popup = null;
    if (mounted) setState(() {});
    if (_anim.value > 0) {
      try {
        await _anim.reverse();
      } catch (_) {}
    }
    if (route.isActive) {
      route.navigator?.removeRoute(route);
    }
  }

  void _showPopup() {
    if (widget.options.isEmpty) return;
    final box = _buttonKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    _anchor = box.localToGlobal(Offset.zero) & box.size;
    HapticFeedback.selectionClick();
    _popup = LiquidGlassPopupRoute<void>(
      builder: _buildOverlay,
      onDismiss: () => unawaited(_dismissPopup()),
    );
    Navigator.of(context, rootNavigator: true).push(_popup!);
    _anim.forward(from: 0);
    setState(() {});
  }

  Widget _buildOverlay(BuildContext overlayContext) {
    final dark = Theme.of(overlayContext).brightness == Brightness.dark;
    final mq = MediaQuery.of(overlayContext);
    final menuWidth = _maxMenuWidth;

    final right = (mq.size.width - _anchor.right).clamp(
      8.0,
      (mq.size.width - menuWidth - 8.0).clamp(8.0, mq.size.width),
    );
    final bottom = (mq.size.height - _anchor.top + _gap).clamp(
      mq.padding.bottom + 8.0,
      mq.size.height - mq.padding.top - 48.0,
    );

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _dismissPopup,
          ),
        ),
        Positioned(
          right: right,
          bottom: bottom,
          width: menuWidth,
          child: Material(
            color: Colors.transparent,
            elevation: 12,
            shadowColor: Colors.black.withValues(alpha: dark ? .36 : .14),
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: SizeTransition(
              sizeFactor: _reveal,
              alignment: Alignment.bottomLeft,
              child: LiquidGlassLens(
                style: chatLiquidGlassStyle(overlayContext, cornerRadius: 14),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final item in widget.options)
                        _PermissionMenuRow(
                          label: item.label,
                          checked: item.value == widget.value,
                          onTap: () {
                            HapticFeedback.selectionClick();
                            _dismissPopup();
                            if (item.value != widget.value) {
                              widget.onChanged(item.value);
                            }
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    final route = _popup;
    _popup = null;
    if (route?.isActive == true) {
      route!.navigator?.removeRoute(route);
    }
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.options.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final accent = widget.enabled
        ? (_isOpen ? _iosBlue : theme.colorScheme.onSurfaceVariant)
        : theme.disabledColor;

    return Tooltip(
      message: '权限预设 · $_selectedLabel',
      child: GestureDetector(
        key: _buttonKey,
        onTap: widget.enabled ? _togglePopup : null,
        behavior: HitTestBehavior.opaque,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 160),
          opacity: widget.enabled ? 1 : 0.38,
          child: SizedBox(
            width: 32,
            height: 32,
            child: Icon(
              CupertinoIcons.shield_lefthalf_fill,
              size: 18,
              color: accent,
            ),
          ),
        ),
      ),
    );
  }
}

class _PermissionMenuRow extends StatelessWidget {
  final String label;
  final bool checked;
  final VoidCallback onTap;

  const _PermissionMenuRow({
    required this.label,
    required this.checked,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = checked ? _iosBlue : theme.colorScheme.onSurface;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        height: 36,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Icon(
                checked
                    ? CupertinoIcons.checkmark
                    : CupertinoIcons.shield,
                size: 14,
                color: checked ? _iosBlue : theme.hintColor,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontSize: 15,
                    fontWeight: checked ? FontWeight.w600 : FontWeight.w400,
                    color: accent,
                    letterSpacing: -0.24,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 会话页共用的思考开关；点亮为开，点灭为关。不持有引擎状态。
class ThinkingToggleButton extends StatelessWidget {  final bool on;
  final VoidCallback? onPressed;

  const ThinkingToggleButton({
    super.key,
    required this.on,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onPressed != null;
    final color = !enabled
        ? theme.disabledColor
        : on
        ? _iosBlue
        : theme.colorScheme.onSurfaceVariant;
    return Tooltip(
      message: on ? '思考已开启' : '思考已关闭',
      child: IconButton(
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 32, height: 32),
        visualDensity: VisualDensity.compact,
        iconSize: 18,
        onPressed: onPressed,
        color: color,
        disabledColor: theme.disabledColor,
        icon: Icon(
          on ? CupertinoIcons.lightbulb_fill : CupertinoIcons.lightbulb,
        ),
      ),
    );
  }
}

/// 会话级模型配置选项。只负责展示，不持有引擎或密钥。
class SessionModelOption {
  final String value;
  final String label;
  final String subtitle;
  final List<String> models;

  /// true 表示该项来自当前 DSH 主机，选择时走 session.selectModel。
  final bool targetDsh;

  /// 目标 DSH 的真实 provider id；value 可以是 UI 唯一键。
  final String targetProvider;

  /// 手机侧拾忆 Relay。选择前需要先把 provider 登记到目标 DSH。
  final bool shiyiRelay;

  const SessionModelOption({
    required this.value,
    required this.label,
    this.subtitle = '',
    this.models = const [],
    this.targetDsh = false,
    this.targetProvider = '',
    this.shiyiRelay = false,
  });
}

class SessionModelSelection {
  final String profile;
  final String model;
  final bool targetDsh;
  final bool shiyiRelay;

  const SessionModelSelection({
    required this.profile,
    required this.model,
    this.targetDsh = false,
    this.shiyiRelay = false,
  });
}

/// 输入区左侧的会话模型抽屉：一级已保存配置，二级缓存模型 ID。
class SessionModelSelector extends StatefulWidget {
  final List<SessionModelOption> options;
  final String value;
  final String modelId;
  final ValueChanged<SessionModelSelection> onChanged;
  final bool enabled;
  final VoidCallback? onOpening;

  const SessionModelSelector({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.modelId = '',
    this.enabled = true,
    this.onOpening,
  });

  @override
  State<SessionModelSelector> createState() => _SessionModelSelectorState();
}

class _SessionModelSelectorState extends State<SessionModelSelector>
    with SingleTickerProviderStateMixin {
  final _buttonKey = GlobalKey();
  LiquidGlassPopupRoute<void>? _popup;
  Rect _anchor = Rect.zero;
  late final AnimationController _anim;
  late final Animation<double> _reveal;
  String? _openProfile;

  static const _gap = 6.0;
  static const _minMenuWidth = 168.0;
  static const _maxMenuWidth = 280.0;
  static const _maxMenuHeight = 240.0;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      reverseDuration: const Duration(milliseconds: 160),
    );
    _reveal = CurvedAnimation(
      parent: _anim,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
  }

  bool get _isOpen => _popup != null;

  String get _selectedValue {
    if (widget.options.any((item) => item.value == widget.value)) {
      return widget.value;
    }
    return widget.options.isEmpty ? '' : widget.options.first.value;
  }

  SessionModelOption? get _selectedOption {
    for (final item in widget.options) {
      if (item.value == _selectedValue) return item;
    }
    return widget.options.isEmpty ? null : widget.options.first;
  }

  void _togglePopup() {
    if (_isOpen) {
      _dismissPopup();
    } else {
      _showPopup();
    }
  }

  Future<void> _dismissPopup() async {
    final route = _popup;
    if (route == null) return;
    _popup = null;
    _openProfile = null;
    if (mounted) setState(() {});
    if (_anim.value > 0) {
      try {
        await _anim.reverse();
      } catch (_) {}
    }
    if (route.isActive) {
      route.navigator?.removeRoute(route);
    }
  }

  @override
  void didUpdateWidget(covariant SessionModelSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    final route = _popup;
    if (route != null &&
        route.isActive &&
        oldWidget.options != widget.options) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _popup?.isActive != true) return;
        _popup!.markNeedsBuild();
      });
    }
  }

  /// 系统返回键：模型抽屉在二级菜单时先回一级，一级时再收抽屉。
  void _dismissPopupFromBack() {
    if (_openProfile != null) {
      HapticFeedback.selectionClick();
      setState(() => _openProfile = null);
      _markDirty();
      return;
    }
    unawaited(_dismissPopup());
  }

  void _showPopup() {
    if (widget.options.isEmpty) return;
    final box = _buttonKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    _anchor = box.localToGlobal(Offset.zero) & box.size;
    _openProfile = null;
    widget.onOpening?.call();
    HapticFeedback.selectionClick();
    _popup = LiquidGlassPopupRoute<void>(
      builder: _buildOverlay,
      onDismiss: _dismissPopupFromBack,
    );
    Navigator.of(context, rootNavigator: true).push(_popup!);
    _anim.forward(from: 0);
    setState(() {});
  }

  void _markDirty() {
    final route = _popup;
    if (route != null && route.isActive) {
      route.markNeedsBuild();
    }
  }

  List<String> _modelsFor(SessionModelOption item) {
    final ids = <String>{
      if (item.subtitle.trim().isNotEmpty) item.subtitle.trim(),
      ...item.models.map((e) => e.trim()).where((e) => e.isNotEmpty),
    };
    return ids.toList();
  }

  double _menuWidthFor(BuildContext context, {SessionModelOption? nested}) {
    final titleStyle =
        Theme.of(
          context,
        ).textTheme.bodyLarge?.copyWith(fontSize: 15, letterSpacing: -0.24) ??
        const TextStyle(fontSize: 15, letterSpacing: -0.24);
    final subStyle =
        Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 12) ??
        const TextStyle(fontSize: 12);
    final painter = TextPainter(textDirection: TextDirection.ltr);
    var maxWidth = 0.0;
    void measure(String text, TextStyle style) {
      if (text.isEmpty) return;
      painter.text = TextSpan(text: text, style: style);
      painter.layout();
      if (painter.width > maxWidth) maxWidth = painter.width;
    }

    if (nested == null) {
      for (final item in widget.options) {
        measure(item.label, titleStyle);
        measure(item.subtitle, subStyle);
      }
    } else {
      measure('返回', titleStyle);
      for (final id in _modelsFor(nested)) {
        measure(id, titleStyle);
      }
    }
    painter.dispose();
    return (maxWidth + 48).clamp(_minMenuWidth, _maxMenuWidth);
  }

  Widget _buildOverlay(BuildContext overlayContext) {
    final dark = Theme.of(overlayContext).brightness == Brightness.dark;
    final mq = MediaQuery.of(overlayContext);
    if (widget.options.isEmpty) return const SizedBox.shrink();
    SessionModelOption? nested;
    if (_openProfile != null) {
      for (final item in widget.options) {
        if (item.value == _openProfile) {
          nested = item;
          break;
        }
      }
    }
    final menuWidth = _menuWidthFor(overlayContext, nested: nested);
    final left = _anchor.left.clamp(8.0, mq.size.width - menuWidth - 8.0);
    final bottom = (mq.size.height - _anchor.top + _gap).clamp(
      mq.padding.bottom + 8.0,
      mq.size.height - mq.padding.top - 48.0,
    );
    final children = <Widget>[];
    if (nested == null) {
      for (final item in widget.options) {
        children.add(
          _SessionModelMenuRow(
            label: item.label,
            subtitle: item.subtitle,
            selected: item.value == _selectedValue,
            trailing: true,
            onTap: () {
              HapticFeedback.selectionClick();
              _openProfile = item.value;
              _markDirty();
            },
          ),
        );
      }
    } else {
      final selectedOption = nested;
      children.add(
        _SessionModelMenuRow(
          label: '返回',
          subtitle: selectedOption.label,
          selected: false,
          leading: true,
          onTap: () {
            HapticFeedback.selectionClick();
            _openProfile = null;
            _markDirty();
          },
        ),
      );
      final models = _modelsFor(selectedOption);
      if (models.isEmpty) {
        children.add(
          const _SessionModelMenuRow(
            label: '暂无缓存模型',
            subtitle: '请先在设置里获取模型目录',
            selected: false,
          ),
        );
      } else {
        for (final id in models) {
          children.add(
            _SessionModelMenuRow(
              label: id,
              selected:
                  selectedOption.value == _selectedValue &&
                  id == widget.modelId.trim(),
              onTap: () {
                HapticFeedback.selectionClick();
                _dismissPopup();
                widget.onChanged(
                  SessionModelSelection(
                    profile:
                        selectedOption.targetDsh &&
                            selectedOption.targetProvider.trim().isNotEmpty
                        ? selectedOption.targetProvider
                        : selectedOption.value,
                    model: id,
                    targetDsh: selectedOption.targetDsh,
                    shiyiRelay: selectedOption.shiyiRelay,
                  ),
                );
              },
            ),
          );
        }
      }
    }

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _dismissPopup,
          ),
        ),
        Positioned(
          left: left,
          bottom: bottom,
          width: menuWidth,
          child: Material(
            color: Colors.transparent,
            elevation: 12,
            shadowColor: Colors.black.withValues(alpha: dark ? .36 : .14),
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: SizeTransition(
              sizeFactor: _reveal,
              alignment: Alignment.bottomLeft,
              child: LiquidGlassLens(
                style: chatLiquidGlassStyle(overlayContext, cornerRadius: 14),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: _maxMenuHeight),
                  child: ListView(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    shrinkWrap: true,
                    children: children,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    final route = _popup;
    _popup = null;
    if (route?.isActive == true) {
      route!.navigator?.removeRoute(route);
    }
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.options.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final selected = _selectedOption;
    final modelId = widget.modelId.trim();
    final label = modelId.isNotEmpty ? modelId : selected?.label ?? '选择模型';
    final accent = widget.enabled
        ? (_isOpen ? _iosBlue : theme.colorScheme.onSurfaceVariant)
        : theme.disabledColor;
    final labelStyle = theme.textTheme.labelLarge?.copyWith(
      color: accent,
      fontSize: 13,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.24,
    ) ?? const TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.24,
    );
    final mimoPainter = TextPainter(
      text: TextSpan(text: 'mimo-2.5', style: labelStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    final mimoWidth = mimoPainter.width;
    mimoPainter.dispose();

    return Tooltip(
      message: '选择模型',
      child: GestureDetector(
        key: _buttonKey,
        onTap: widget.enabled ? _togglePopup : null,
        behavior: HitTestBehavior.opaque,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 160),
          opacity: widget.enabled ? 1 : 0.38,
          child: SizedBox(
            width: mimoWidth + 28,
            height: 32,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  AutoScrollLabel(
                    text: label,
                    width: mimoWidth,
                    alignment: Alignment.center,
                    style: labelStyle,
                  ),
                  const SizedBox(width: 1),
                  Icon(
                    _isOpen
                        ? CupertinoIcons.chevron_down
                        : CupertinoIcons.chevron_up,
                    size: 11,
                    color: accent,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SessionModelMenuRow extends StatelessWidget {
  final String label;
  final String subtitle;
  final bool selected;
  final bool trailing;
  final bool leading;
  final VoidCallback? onTap;

  const _SessionModelMenuRow({
    required this.label,
    this.subtitle = '',
    required this.selected,
    this.trailing = false,
    this.leading = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = selected ? _iosBlue : theme.colorScheme.onSurface;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            if (leading) ...[
              Icon(
                CupertinoIcons.chevron_back,
                size: 13,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontSize: 15,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      color: color,
                      letterSpacing: -0.24,
                    ),
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 12,
                        color: selected
                            ? _iosBlue.withValues(alpha: .78)
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing)
              Icon(
                CupertinoIcons.chevron_forward,
                size: 13,
                color: selected ? _iosBlue : theme.colorScheme.onSurfaceVariant,
              ),
          ],
        ),
      ),
    );
  }
}

/// 会话页共用的上下文上限入口；只改本会话，不改全局默认。
class ChatContextLimitButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final String label;

  const ChatContextLimitButton({
    super.key,
    required this.onPressed,
    this.label = '',
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onPressed != null;
    final color = enabled
        ? theme.colorScheme.onSurfaceVariant
        : theme.disabledColor;
    return Tooltip(
      message: '会话上下文',
      child: IconButton(
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 48, height: 32),
        visualDensity: VisualDensity.compact,
        onPressed: onPressed,
        color: color,
        disabledColor: theme.disabledColor,
        icon: Text(
          label.isEmpty ? 'CTX' : label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall?.copyWith(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
          ),
        ),
      ),
    );
  }
}

/// 会话页共用的紧凑压缩入口；压缩实现仍由各引擎自己的回调负责。
class ChatCompressionButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final bool busy;

  const ChatCompressionButton({
    super.key,
    required this.onPressed,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: busy ? '正在压缩上下文' : '压缩上下文',
      child: IconButton(
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 32, height: 32),
        visualDensity: VisualDensity.compact,
        iconSize: 18,
        onPressed: onPressed,
        color: theme.colorScheme.onSurfaceVariant,
        disabledColor: theme.disabledColor,
        icon: busy
            ? const CupertinoActivityIndicator(radius: 7)
            : const Icon(CupertinoIcons.rectangle_compress_vertical),
      ),
    );
  }
}

class LiquidGlassChatComposer extends StatelessWidget {
  final TextEditingController input;
  final bool busy;
  final bool questionActive;
  final bool enterToSend;
  final bool allowSendWhileBusy;
  final List<String> pendingImages;
  final List<String> pendingFiles;
  final VoidCallback onPickAttachment;
  final ValueChanged<int> onRemoveImage;
  final ValueChanged<int> onRemoveFile;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final String idleHint;
  final String busyHint;
  final List<ThinkingIntensityOption> thinkingOptions;
  final String thinkingValue;
  final ValueChanged<String>? onThinkingChanged;
  final bool thinkingEnabled;
  final bool thinkingOn;
  final ValueChanged<bool>? onThinkingToggled;
  final VoidCallback? onCompress;
  final bool compressBusy;
  final VoidCallback? onContextLimit;
  final String contextLimitLabel;
  final List<SessionModelOption> modelOptions;
  final String modelValue;
  final String modelId;
  final ValueChanged<SessionModelSelection>? onModelChanged;
  final bool modelEnabled;
  final VoidCallback? onModelOpening;
  final List<PermissionPresetOption> permissionOptions;
  final String permissionValue;
  final ValueChanged<String>? onPermissionChanged;
  final bool permissionEnabled;

  const LiquidGlassChatComposer({
    super.key,
    required this.input,
    required this.busy,
    required this.enterToSend,
    required this.pendingImages,
    required this.pendingFiles,
    required this.onPickAttachment,
    required this.onRemoveImage,
    required this.onRemoveFile,
    required this.onSend,
    required this.onStop,
    this.questionActive = false,
    this.allowSendWhileBusy = false,
    this.idleHint = '输入消息…',
    this.busyHint = 'agent 运行中…',
    this.thinkingOptions = const [],
    this.thinkingValue = '',
    this.onThinkingChanged,
    this.thinkingEnabled = true,
    this.thinkingOn = true,
    this.onThinkingToggled,
    this.onCompress,
    this.compressBusy = false,
    this.onContextLimit,
    this.contextLimitLabel = '',
    this.modelOptions = const [],
    this.modelValue = '',
    this.modelId = '',
    this.onModelChanged,
    this.modelEnabled = true,
    this.onModelOpening,
    this.permissionOptions = const [],
    this.permissionValue = '',
    this.onPermissionChanged,
    this.permissionEnabled = true,
  });

  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final isEnter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (!isEnter) return false;
    final ctrl =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (ctrl) {
      if (enterToSend) {
        final text = input.text;
        final selection = input.selection;
        final start = selection.isValid ? selection.start : text.length;
        final end = selection.isValid ? selection.end : text.length;
        input.text = text.replaceRange(start, end, '\n');
        input.selection = TextSelection.collapsed(offset: start + 1);
      } else {
        onSend();
      }
      return true;
    }
    if (enterToSend) {
      onSend();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: Container(
        key: const ValueKey('liquidGlassChatComposer'),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(26),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: dark ? .28 : .10),
              blurRadius: 18,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: LiquidGlassLens(
          style: chatLiquidGlassStyle(
            context,
            cornerRadius: 26,
            tint: dark ? const Color(0x8A1C1C1E) : const Color(0x8AF2F2F7),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if ((modelOptions.isNotEmpty && onModelChanged != null) ||
                    (thinkingOptions.isNotEmpty && onThinkingChanged != null) ||
                    onThinkingToggled != null ||
                    onCompress != null ||
                    onContextLimit != null ||
                    (permissionOptions.isNotEmpty &&
                        onPermissionChanged != null)) ...[
                  Row(
                    children: [
                      if (modelOptions.isNotEmpty && onModelChanged != null)
                        Flexible(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: SessionModelSelector(
                              options: modelOptions,
                              value: modelValue,
                              modelId: modelId,
                              onChanged: onModelChanged!,
                              enabled: modelEnabled,
                              onOpening: onModelOpening,
                            ),
                          ),
                        )
                      else
                        const Spacer(),
                      if (permissionOptions.isNotEmpty &&
                          onPermissionChanged != null)
                        PermissionPresetSelector(
                          options: permissionOptions,
                          value: permissionValue,
                          onChanged: onPermissionChanged!,
                          enabled: permissionEnabled,
                        ),
                      if (onContextLimit != null)
                        ChatContextLimitButton(
                          onPressed: onContextLimit,
                          label: contextLimitLabel,
                        ),
                      if (onCompress != null)
                        ChatCompressionButton(
                          onPressed: onCompress,
                          busy: compressBusy,
                        ),
                      if (onThinkingToggled != null &&
                          thinkingOptions.isNotEmpty)
                        ThinkingToggleButton(
                          on: thinkingOn,
                          onPressed: thinkingEnabled
                              ? () => onThinkingToggled!(!thinkingOn)
                              : null,
                        ),
                      if (thinkingOptions.isNotEmpty &&
                          onThinkingChanged != null)
                        ThinkingIntensitySelector(
                          options: thinkingOptions,
                          value: thinkingValue,
                          onChanged: onThinkingChanged!,
                          enabled: thinkingEnabled,
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                ],
                if (pendingImages.isNotEmpty || pendingFiles.isNotEmpty) ...[
                  _previewRow(theme),
                  const SizedBox(height: 6),
                ],
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 40,
                      height: 40,
                      child: IconButton(
                        onPressed: onPickAttachment,
                        icon: const Icon(
                          CupertinoIcons.plus_circle,
                          size: 24,
                          color: _iosBlue,
                        ),
                        tooltip: '添加附件',
                        padding: EdgeInsets.zero,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: dark
                              ? Colors.black.withValues(alpha: .18)
                              : Colors.white.withValues(alpha: .32),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: Colors.white.withValues(
                              alpha: dark ? .10 : .42,
                            ),
                          ),
                        ),
                        child: Focus(
                          onKeyEvent: (node, event) => _handleKey(event)
                              ? KeyEventResult.handled
                              : KeyEventResult.ignored,
                          child: TextField(
                            controller: input,
                            minLines: 1,
                            maxLines: 5,
                            textInputAction: enterToSend
                                ? TextInputAction.send
                                : TextInputAction.newline,
                            onSubmitted: enterToSend ? (_) => onSend() : null,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontSize: 16,
                              height: 1.25,
                            ),
                            decoration: InputDecoration(
                              hintText: questionActive
                                  ? '直接输入你的回答…'
                                  : busy
                                  ? busyHint
                                  : idleHint,
                              hintStyle: TextStyle(color: theme.hintColor),
                              filled: false,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              disabledBorder: InputBorder.none,
                              errorBorder: InputBorder.none,
                              focusedErrorBorder: InputBorder.none,
                              isDense: true,
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: input,
                      builder: (context, value, _) {
                        final hasInput =
                            value.text.trim().isNotEmpty ||
                            pendingImages.isNotEmpty ||
                            pendingFiles.isNotEmpty;
                        return _sendControl(dark: dark, hasInput: hasInput);
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sendControl({required bool dark, required bool hasInput}) {
    if (busy) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _roundIconButton(
            onPressed: onStop,
            icon: CupertinoIcons.stop_circle_fill,
            color: _iosRed,
            tooltip: '停止',
          ),
          if (allowSendWhileBusy && hasInput) ...[
            const SizedBox(width: 2),
            _roundIconButton(
              onPressed: onSend,
              icon: CupertinoIcons.arrow_up_circle_fill,
              color: _iosBlue,
              tooltip: questionActive ? '发送回答' : '发送并引导',
            ),
          ],
        ],
      );
    }
    return _roundIconButton(
      onPressed: hasInput ? onSend : null,
      icon: hasInput
          ? CupertinoIcons.arrow_up_circle_fill
          : CupertinoIcons.arrow_up_circle,
      color: hasInput
          ? _iosBlue
          : dark
          ? const Color(0xFF48484A)
          : const Color(0xFFC7C7CC),
      tooltip: questionActive ? '发送回答' : '发送',
    );
  }

  Widget _roundIconButton({
    required VoidCallback? onPressed,
    required IconData icon,
    required Color color,
    required String tooltip,
  }) {
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon, size: 32, color: color),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      tooltip: tooltip,
    );
  }

  Widget _previewRow(ThemeData theme) {
    return SizedBox(
      height: 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: pendingImages.length + pendingFiles.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          if (index < pendingImages.length) {
            final path = pendingImages[index];
            return Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(
                    File(path),
                    width: 56,
                    height: 56,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      width: 56,
                      height: 56,
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: theme.hintColor,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 0,
                  right: 0,
                  child: GestureDetector(
                    onTap: () => onRemoveImage(index),
                    child: _removeBadge(),
                  ),
                ),
              ],
            );
          }
          final fileIndex = index - pendingImages.length;
          final file = pendingFiles[fileIndex];
          return Stack(
            children: [
              Container(
                width: 140,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.insert_drive_file_outlined,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        p.basename(file),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall,
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                top: 0,
                right: 0,
                child: GestureDetector(
                  onTap: () => onRemoveFile(fileIndex),
                  child: _removeBadge(),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _removeBadge() => Container(
    decoration: BoxDecoration(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(8),
    ),
    child: const Icon(Icons.close, size: 14, color: Colors.white),
  );
}
