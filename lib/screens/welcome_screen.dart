import 'package:flutter/material.dart';

import '../core/app_state.dart';
import 'home_screen.dart';

/// 欢迎页：打开软件时自动显示，图片 +「欢迎回家」渐显渐隐，随后自动进入主页。
class WelcomeScreen extends StatefulWidget {
  final ShiyiState shiyi;
  const WelcomeScreen({super.key, required this.shiyi});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _opacity;

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

    _ctrl.addStatusListener((status) {
      if (status == AnimationStatus.completed) _enterHome();
    });
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _enterHome() {
    if (!mounted) return;
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
      body: AnimatedBuilder(
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
              Text(
                '拾忆 · 你的智能体伙伴',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
