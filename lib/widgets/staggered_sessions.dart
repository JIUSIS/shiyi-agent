import 'package:flutter/material.dart';

import '../core/home_list_order.dart';

/// 展开/收起过程必须裁剪高度，否则项目点开没有交错动画。
/// 只有完全展开且 [unclipped] 才放开裁剪，好让会话长按拖拽命中。
/// 树结构始终不变：收起时不能把 SizeTransition 换成 Column，否则会闪一下。
bool staggeredSessionsUsesSizeClip({
  required bool unclipped,
  required double animationValue,
}) {
  if (unclipped && animationValue >= 1) return false;
  return true;
}

/// 已完全展开且静止时不要再播入场滑入，否则跨项目写入会从下往上弹一下。
bool staggeredSessionsPlaysEnterSlide({
  required bool isAnimating,
  required double animationValue,
}) {
  return isAnimating || animationValue < 1;
}

/// 分组下会话列表的展开/收起：卡片逐条出现/收回。
/// 始终保持同一棵动画树，只切换 [ClipRect.clipBehavior]。
class StaggeredSessions extends StatefulWidget {
  final bool expanded;
  final bool unclipped;
  final bool instant;
  final bool fastCollapse;
  final bool outOfFlow;
  final List<Widget> children;
  const StaggeredSessions({
    super.key,
    required this.expanded,
    required this.children,
    this.unclipped = false,
    this.instant = false,
    this.fastCollapse = false,
    this.outOfFlow = false,
  });

  @override
  State<StaggeredSessions> createState() => _StaggeredSessionsState();
}

class _StaggeredSessionsState extends State<StaggeredSessions>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  final List<CurvedAnimation> _curves = [];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    )..value = widget.expanded ? 1 : 0;
    _controller.addListener(_onTick);
    _syncCurves(widget.children.length);
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  void _syncCurves(int n) {
    if (_curves.length == n) return;
    for (final c in _curves) {
      c.dispose();
    }
    _curves.clear();
    for (var i = 0; i < n; i++) {
      final start = n == 0 ? 0.0 : i / n;
      final end = n == 0 ? 1.0 : (i + 1) / n;
      _curves.add(
        CurvedAnimation(
          parent: _controller,
          curve: Interval(start, end, curve: Curves.easeOutCubic),
          reverseCurve: Interval(start, end, curve: Curves.easeInCubic),
        ),
      );
    }
  }

  @override
  void didUpdateWidget(covariant StaggeredSessions oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncCurves(widget.children.length);
    if (oldWidget.expanded != widget.expanded) {
      if (widget.instant) {
        _controller.value = widget.expanded ? 1 : 0;
      } else if (widget.expanded) {
        _controller.forward();
      } else if (widget.fastCollapse) {
        _controller.animateTo(
          0,
          duration: kHomeDragFastCollapseDuration,
          curve: Curves.easeOutCubic,
        );
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onTick);
    for (final c in _curves) {
      c.dispose();
    }
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.children.length;
    final clip = staggeredSessionsUsesSizeClip(
      unclipped: widget.unclipped,
      animationValue: _controller.value,
    );
    final column = Column(
      mainAxisSize: MainAxisSize.min,
      children: [for (var i = 0; i < n; i++) _buildItem(i, clip)],
    );
    if (!widget.outOfFlow) return column;
    // 长按展开项目时会话从文档流拿掉，挤开高度才是项目头，收起动画仍画在原处。
    return IgnorePointer(
      child: Align(
        alignment: Alignment.topCenter,
        heightFactor: 0,
        child: column,
      ),
    );
  }

  Widget _buildItem(int index, bool clip) {
    final curved = _curves[index];
    Widget child = widget.children[index];
    if (staggeredSessionsPlaysEnterSlide(
      isAnimating: _controller.isAnimating,
      animationValue: _controller.value,
    )) {
      child = FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.08),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    }
    return ClipRect(
      clipBehavior: clip ? Clip.hardEdge : Clip.none,
      child: Align(
        alignment: Alignment.topCenter,
        heightFactor: curved.value.clamp(0.0, 1.0),
        child: child,
      ),
    );
  }
}
