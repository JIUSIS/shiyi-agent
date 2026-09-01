// 预测性返回（Predictive Back）路由。
// - opaque: false：页面缩小悬浮时能透出底层上一页预览；
// - 进入/返回：纯淡入淡出（省掉横向滑动，降低动画开销）；
// - 注册 WidgetsBindingObserver 接收系统预测性返回手势（侧边滑动），
//   把进度/提交/取消事件转发给页面（BackGestureTarget），
//   由页面播放缩小悬浮、超阈值返回、未达阈值回弹。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 预测性返回手势目标：由当前路由页面实现。
abstract interface class BackGestureTarget {
  /// 系统手势进度 0~1（0 = 未滑动，1 = 完全滑到阈值）。
  void onBackGestureProgress(double progress);

  /// 手势超过阈值松手：执行返回。
  void onBackGestureCommit();

  /// 手势未达阈值松手：回弹复原。
  void onBackGestureCancel();
}

class MacPageRoute<T> extends PageRouteBuilder<T> {
  MacPageRoute({required WidgetBuilder builder, super.settings})
    : super(
        opaque: false,
        pageBuilder: (context, animation, secondaryAnimation) =>
            builder(context),
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 240),
        transitionsBuilder: _buildTransitions,
      );

  /// 当前页面注册后，可接收系统预测性返回手势事件。
  BackGestureTarget? backGestureTarget;

  _MacRouteBackObserver? _backObserver;

  @override
  void install() {
    super.install();
    _backObserver = _MacRouteBackObserver(this);
    WidgetsBinding.instance.addObserver(_backObserver!);
  }

  @override
  void dispose() {
    final observer = _backObserver;
    if (observer != null) {
      WidgetsBinding.instance.removeObserver(observer);
      _backObserver = null;
    }
    super.dispose();
  }

  static Widget _buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    // 纯淡入淡出（无缩放/位移），低开销。
    return FadeTransition(opacity: curved, child: child);
  }
}

/// 系统预测性返回手势观察者。
///
/// Flutter 只有在路由使用 PredictiveBackPageTransitionsBuilder 时才会自动
/// 注册观察者；自定义路由需要自己注册 WidgetsBindingObserver 才能收到系统
/// 边缘滑动返回手势的进度事件。
class _MacRouteBackObserver with WidgetsBindingObserver {
  _MacRouteBackObserver(this.route);

  final MacPageRoute route;
  bool _active = false;

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    final target = route.backGestureTarget;
    if (!route.isCurrent || !route.popGestureEnabled || target == null) {
      return false;
    }
    _active = true;
    target.onBackGestureProgress(backEvent.progress);
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    if (!_active) return;
    route.backGestureTarget?.onBackGestureProgress(backEvent.progress);
  }

  @override
  void handleCommitBackGesture() {
    if (!_active) return;
    _active = false;
    route.backGestureTarget?.onBackGestureCommit();
  }

  @override
  void handleCancelBackGesture() {
    if (!_active) return;
    _active = false;
    route.backGestureTarget?.onBackGestureCancel();
  }
}

/// 预测性返回淡出：系统侧滑进度驱动透明度，和拾忆会话页同一套。
class MacBackFade extends StatefulWidget {
  final Widget child;
  final bool Function()? consumeBack;
  const MacBackFade({super.key, required this.child, this.consumeBack});

  @override
  State<MacBackFade> createState() => _MacBackFadeState();
}

class _MacBackFadeState extends State<MacBackFade>
    with SingleTickerProviderStateMixin
    implements BackGestureTarget {
  late final AnimationController _dragCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    value: 0,
  );
  MacPageRoute? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is MacPageRoute) {
      _route = route;
      route.backGestureTarget = this;
    }
  }

  @override
  void dispose() {
    _route?.backGestureTarget = null;
    _dragCtrl.dispose();
    super.dispose();
  }

  void _pop() {
    if (widget.consumeBack?.call() == true) return;
    FocusManager.instance.primaryFocus?.unfocus();
    if (mounted) Navigator.pop(context);
  }

  @override
  void onBackGestureProgress(double progress) {
    if (!mounted) return;
    _dragCtrl.stop();
    _dragCtrl.value = progress.clamp(0.0, 1.0);
  }

  @override
  void onBackGestureCommit() {
    if (!mounted) return;
    _pop();
  }

  @override
  void onBackGestureCancel() {
    if (!mounted) return;
    _dragCtrl.animateBack(
      0,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _pop();
      },
      child: AnimatedBuilder(
        animation: _dragCtrl,
        builder: (context, child) {
          final t = _dragCtrl.value;
          if (t <= 0.001) return child!;
          return Opacity(opacity: 1.0 - t * 0.45, child: child);
        },
        child: widget.child,
      ),
    );
  }
}
