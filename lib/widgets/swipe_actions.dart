import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'context_menu.dart';
import 'ios_style.dart';

/// 左滑操作中的圆形图标按钮：圆形底 + 图标，下方配小字标签。
class CircularSwipeAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color backgroundColor;
  final Color foregroundColor;
  final VoidCallback onTap;

  const CircularSwipeAction({
    super.key,
    required this.icon,
    required this.label,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: label,
      child: SizedBox(
        width: 56,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Material(
                color: backgroundColor,
                shape: const CircleBorder(),
                elevation: 1.5,
                shadowColor: Colors.black.withValues(alpha: .25),
                child: InkWell(
                  onTap: onTap,
                  customBorder: const CircleBorder(),
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: Icon(icon, color: foregroundColor, size: 18),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 自实现左滑操作容器：内容跟随手指左移，露出右侧固定宽度的操作胶囊；
/// 已滑开时点击内容先收回，再点才触发 onTap。
class SwipeActions extends StatefulWidget {
  final Widget child;
  final List<Widget> actions;
  final VoidCallback? onTap;
  final double actionWidth;
  final ValueNotifier<String?>? openNotifier;
  final ValueChanged<Rect?>? onOpenRectChanged;
  final String? swipeKey;

  /// 拖拽卡片时关闭并锁住左滑，避免拖拽启动帧把卡片推向左侧。
  final bool disableSwipe;

  /// 测试覆盖：true 强制走桌面悬停路径，false 强制走手机左滑路径。
  final bool? desktopOverride;

  const SwipeActions({
    super.key,
    required this.child,
    required this.actions,
    this.onTap,
    this.actionWidth = 132,
    this.openNotifier,
    this.onOpenRectChanged,
    this.swipeKey,
    this.disableSwipe = false,
    this.desktopOverride,
  });

  @override
  State<SwipeActions> createState() => _SwipeActionsState();
}

class _SwipeActionsState extends State<SwipeActions>
    with SingleTickerProviderStateMixin {
  double get actionWidth => widget.actionWidth;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  )..addStatusListener(_onAnimationStatus);

  double _offset = 0;
  bool _animating = false;
  bool _horizontalSwipe = false;
  bool _swipeWindowOpen = false;
  int? _pointer;
  Offset? _pointerStart;
  Timer? _swipeWindowTimer;
  double _lastMoveDx = 0;
  Duration _lastMoveTime = Duration.zero;

  // 左滑必须在长按拖拽识别前启动；长按期间的触屏抖动不应打开操作区。
  static const _swipeStartWindow = Duration(milliseconds: 300);

  @override
  void initState() {
    super.initState();
    widget.openNotifier?.addListener(_onOpenChanged);
  }

  @override
  void dispose() {
    _swipeWindowTimer?.cancel();
    widget.openNotifier?.removeListener(_onOpenChanged);
    final onOpenRectChanged = widget.onOpenRectChanged;
    if (onOpenRectChanged != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        onOpenRectChanged(null);
      });
    }
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant SwipeActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.disableSwipe && !oldWidget.disableSwipe) {
      _resetImmediately();
    }
  }

  void _resetImmediately() {
    _pointer = null;
    _pointerStart = null;
    _swipeWindowTimer?.cancel();
    _swipeWindowOpen = false;
    _horizontalSwipe = false;
    _lastMoveDx = 0;
    if (_animating) {
      _controller.stop();
      _animating = false;
    }
    _controller.value = 0;
    _offset = 0;
    final notifier = widget.openNotifier;
    final key = widget.swipeKey;
    if (notifier != null && key != null && notifier.value == key) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.disableSwipe && notifier.value == key) {
          notifier.value = null;
        }
      });
    }
    final onRectChanged = widget.onOpenRectChanged;
    if (onRectChanged != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.disableSwipe) onRectChanged(null);
      });
    }
  }

  void _onAnimationStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed &&
        status != AnimationStatus.dismissed) {
      return;
    }
    _offset = -actionWidth * _controller.value;
    _animating = false;
    if (status == AnimationStatus.dismissed) {
      widget.onOpenRectChanged?.call(null);
    }
    if (mounted) setState(() {});
  }

  /// 左滑过 35% 或快速左滑 → 展开；已完全展开时快速右滑收回，原地松手保持展开。
  double _target(double velocity) {
    final fullyOpen = _offset <= -actionWidth + 2;
    if (fullyOpen) {
      if (velocity > 200) return 0;
      return -actionWidth;
    }
    if (velocity > 250) return 0;
    if (_offset < -actionWidth * 0.35 || velocity < -200) {
      return -actionWidth;
    }
    return 0;
  }

  void _applyDx(double dx) {
    final n = widget.openNotifier;
    final k = widget.swipeKey;
    if (n != null && k != null && n.value != null && n.value != k) {
      n.value = null;
    }
    if (_animating) {
      _controller.stop();
      _animating = false;
    }
    setState(() {
      _offset = (_offset + dx).clamp(-actionWidth, 0.0);
    });
  }

  /// 用 Listener 跟手，不进手势竞技场，避免和 LongPressDraggable / ListView 互抢。
  void _onPointerDown(PointerDownEvent e) {
    if (widget.disableSwipe) return;
    _pointer = e.pointer;
    _pointerStart = e.position;
    _swipeWindowOpen = true;
    _swipeWindowTimer?.cancel();
    _swipeWindowTimer = Timer(
      _swipeStartWindow,
      () => _swipeWindowOpen = false,
    );
    _horizontalSwipe = false;
    _lastMoveDx = 0;
    _lastMoveTime = e.timeStamp;
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (widget.disableSwipe || e.pointer != _pointer || _pointerStart == null) {
      return;
    }
    final delta = e.position - _pointerStart!;
    if (!_horizontalSwipe) {
      if (!_swipeWindowOpen) {
        return;
      }
      if (delta.distance < 12) return;
      if (delta.dx.abs() <= delta.dy.abs()) return;
      _horizontalSwipe = true;
    }
    _lastMoveDx = e.delta.dx;
    _lastMoveTime = e.timeStamp;
    _applyDx(e.delta.dx);
  }

  void _onPointerUp(PointerUpEvent e) {
    if (widget.disableSwipe || e.pointer != _pointer) return;
    final swiped = _horizontalSwipe;
    _pointer = null;
    _pointerStart = null;
    _swipeWindowTimer?.cancel();
    _swipeWindowOpen = false;
    var velocity = 0.0;
    final dt = e.timeStamp - _lastMoveTime;
    if (dt.inMicroseconds > 0 && dt.inMilliseconds < 80) {
      velocity = _lastMoveDx * 1000 / dt.inMilliseconds.clamp(1, 80);
    }
    _end(velocity);
    if (swiped) _horizontalSwipe = true;
  }

  void _onPointerCancel(PointerCancelEvent e) {
    if (widget.disableSwipe || e.pointer != _pointer) return;
    _pointer = null;
    _pointerStart = null;
    _swipeWindowTimer?.cancel();
    _swipeWindowOpen = false;
    _end(0);
  }

  void _settle(double target) {
    _controller.value = (_offset / -actionWidth).clamp(0.0, 1.0);
    _animating = true;
    _controller.animateTo(target / -actionWidth, curve: Curves.easeOutCubic);
  }

  void _end(double velocity) {
    if (!_horizontalSwipe && _offset == 0) {
      _horizontalSwipe = false;
      return;
    }
    _horizontalSwipe = false;
    final t = _target(velocity);
    if (t == _offset) {
      if (_animating) {
        _controller.stop();
        _animating = false;
      }
      _syncOpenState(t);
      return;
    }
    _settle(t);
    _syncOpenState(t);
  }

  void _handleTap() {
    if (_horizontalSwipe) {
      _horizontalSwipe = false;
      return;
    }
    if (_offset < 0) {
      widget.onOpenRectChanged?.call(null);
      _settle(0);
      _syncOpenState(0);
      return;
    }
    widget.onTap?.call();
  }

  void _setHovered(bool hovered) {
    if (!Platform.isWindows || widget.disableSwipe) return;
    if (_animating) {
      _controller.stop();
      _animating = false;
    }
    if (hovered) {
      if (_offset >= 0) {
        _controller.forward();
        _syncOpenState(-actionWidth);
      }
    } else if (_offset < 0) {
      widget.onOpenRectChanged?.call(null);
      _settle(0);
      _syncOpenState(0);
    }
    if (mounted) setState(() {});
  }

  void _openContextMenu(BuildContext context, Offset globalPosition) {
    final entries = <DesktopMenuItem>[];
    for (final a in widget.actions) {
      if (a is CircularSwipeAction) {
        entries.add(
          DesktopMenuItem(
            label: a.label,
            icon: a.icon,
            iconColor: a.backgroundColor,
            onTap: a.onTap,
          ),
        );
      }
    }
    if (entries.isEmpty) return;
    if (_offset < 0) {
      widget.onOpenRectChanged?.call(null);
      _settle(0);
      _syncOpenState(0);
    }
    showDesktopMenu(context, globalPosition: globalPosition, items: entries);
  }

  void _syncOpenState(double target) {
    final n = widget.openNotifier;
    final k = widget.swipeKey;
    if (n == null || k == null) return;
    if (target < 0) {
      n.value = k;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final box = context.findRenderObject();
        if (box is RenderBox && box.hasSize) {
          widget.onOpenRectChanged?.call(
            box.localToGlobal(Offset.zero) & box.size,
          );
        }
      });
    } else if (n.value == k) {
      n.value = null;
      widget.onOpenRectChanged?.call(null);
    }
  }

  void _onOpenChanged() {
    final n = widget.openNotifier;
    final k = widget.swipeKey;
    if (n == null || k == null || n.value == k) return;
    if (_animating) {
      _controller.stop();
      _animating = false;
      _offset = -actionWidth * _controller.value;
    }
    if (_offset < 0) {
      widget.onOpenRectChanged?.call(null);
      _settle(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final displayOffset = _animating
        ? -actionWidth * _controller.value
        : _offset;
    final desktop = widget.desktopOverride ?? Platform.isWindows;
    return MouseRegion(
      onEnter: desktop && !widget.disableSwipe
          ? (_) => _setHovered(true)
          : null,
      onExit: desktop && !widget.disableSwipe
          ? (_) => _setHovered(false)
          : null,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Stack(
          children: [
            Positioned.fill(
              child: AnimatedOpacity(
                opacity: displayOffset < 0 ? 1 : 0,
                duration: const Duration(milliseconds: 100),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _handleTap,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: SizedBox(
                      width: actionWidth,
                      height: double.infinity,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [for (final a in widget.actions) a],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                final off = _animating
                    ? -actionWidth * _controller.value
                    : _offset;
                return Container(
                  transform: Matrix4.translationValues(off, 0, 0),
                  decoration: BoxDecoration(
                    color: iosSectionBackground(context),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Listener(
                    onPointerDown: desktop || widget.disableSwipe
                        ? null
                        : _onPointerDown,
                    onPointerMove: desktop || widget.disableSwipe
                        ? null
                        : _onPointerMove,
                    onPointerUp: desktop || widget.disableSwipe
                        ? null
                        : _onPointerUp,
                    onPointerCancel: desktop || widget.disableSwipe
                        ? null
                        : _onPointerCancel,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onSecondaryTapDown: desktop && !widget.disableSwipe
                          ? (d) => _openContextMenu(context, d.globalPosition)
                          : null,
                      onTap: widget.disableSwipe ? null : _handleTap,
                      child: widget.child,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
