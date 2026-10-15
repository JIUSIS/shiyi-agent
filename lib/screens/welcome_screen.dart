import 'dart:async';

import 'package:flutter/material.dart';

import '../widgets/chat_liquid_glass.dart';
import '../core/app_state.dart';
import 'home_screen.dart';

/// 欢迎页：打开软件时自动显示，图片 +「欢迎回家」渐显渐隐，随后自动进入主页。
///
/// 首启会先等 [startup]（权限流程 + 状态初始化）走完：权限没给完不进主页，
/// 避免「还没授权就直接进了软件」和并发初始化失败。
class WelcomeScreen extends StatefulWidget {
  final ShiyiState shiyi;
  final Future<void> startup;

  /// 进入主页的动作（默认淡入替换到 [HomeScreen]）。测试注入用。
  final void Function(BuildContext context)? enterHome;

  const WelcomeScreen({
    super.key,
    required this.shiyi,
    required this.startup,
    this.enterHome,
  });

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with SingleTickerProviderStateMixin {
  /// 入场动画在停留段结束处的时间点（淡入 30% + 停留 40%）。
  /// 权限没给完时停在这里（画面保持全亮），授权完成后继续播淡出。
  static const double _holdAt = 0.7;

  late final AnimationController _ctrl;
  late final Animation<double> _opacity;

  /// 入场动画 / 启动序列是否完成；两个都完成才进主页。
  bool _animationDone = false;
  bool _startupDone = false;
  bool _entered = false;

  /// 启动序列拖了很久（首启等权限）才提示：正常启动 1 秒内就进主页，
  /// 不能每次冷启动都闪一下提示。
  bool _showAuthHint = false;
  Timer? _authHintTimer;

  @override
  void initState() {
    super.initState();
    // 淡入 0.8s → 停留 1.0s → 淡出 0.8s，总时长 2.6s。
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    );
    _opacity = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(
          begin: 0.0,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 30,
      ),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 40),
      TweenSequenceItem(
        tween: Tween(
          begin: 1.0,
          end: 0.0,
        ).chain(CurveTween(curve: Curves.easeIn)),
        weight: 30,
      ),
    ]).animate(_ctrl);

    _ctrl.addListener(_holdWhileWaiting);
    _ctrl.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _animationDone = true;
        _maybeEnterHome();
      }
    });
    _ctrl.forward();
    _authHintTimer = Timer(const Duration(milliseconds: 1500), () {
      if (!mounted || _startupDone) return;
      setState(() => _showAuthHint = true);
    });
    widget.startup.whenComplete(() {
      if (!mounted) return;
      _authHintTimer?.cancel();
      setState(() {
        _startupDone = true;
        _showAuthHint = false;
      });
      // 之前停在停留段末尾（首启在等权限/设置页）：从这里接着播淡出，
      // 保持「欢迎页淡出 → 主页淡入」的连贯观感，不能直接跳到主页。
      if (!_animationDone && _ctrl.value >= _holdAt) {
        _ctrl.forward();
      }
      _maybeEnterHome();
    });
  }

  /// 启动序列没完成时不要淡出：停在停留段末尾，画面全亮等用户授权。
  /// 掉帧导致动画一步跳完也要拉回来，不能出现黑屏等授权。
  void _holdWhileWaiting() {
    if (_startupDone) return;
    if (_ctrl.value < _holdAt) return;
    if (_ctrl.isAnimating) _ctrl.stop();
    if (_ctrl.value != _holdAt) _ctrl.value = _holdAt;
    _animationDone = false;
  }

  @override
  void dispose() {
    _authHintTimer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _maybeEnterHome() {
    if (_entered || !_animationDone || !_startupDone) return;
    _entered = true;
    _enterHome();
  }

  void _enterHome() {
    if (!mounted) return;
    final injected = widget.enterHome;
    if (injected != null) {
      injected(context);
      return;
    }
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, _, _) => HomeScreen(shiyi: widget.shiyi),
        transitionsBuilder: (_, anim, _, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 350),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      // 页面背景与主题空背景一致（scaffoldBackgroundColor: 浅 #F2F2F7 / 深 #1E1E20），
      // 避免欢迎页用 surface 纯白导致与主页背景不统一。
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Stack(
          children: [
            AnimatedBuilder(
              animation: _ctrl,
              builder: (context, child) =>
                  Opacity(opacity: _opacity.value, child: child),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset(
                      'assets/welcome.png',
                      width: 240,
                      height: 240,
                      fit: BoxFit.contain,
                    ),
                    const SizedBox(height: 30),
                    Text(
                      '欢迎回家',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Text(
                        '愿中国青年都摆脱冷气，只是向上走，不必听自暴自弃者流的话。'
                        '能做事的做事，能发声的发声。有一分热，发一分光，'
                        '就令萤火一般，也可以在黑暗里发一点光，不必等候炬火。',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.hintColor,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (!_startupDone && _showAuthHint)
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 56),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const AppLoading(),
                      const SizedBox(height: 12),
                      Text(
                        // 不写「授权」：授权完成后这里不该再提授权，
                        // 真正的授权提示由系统弹窗自己给。
                        '首次启动正在准备，请稍候…',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.hintColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
