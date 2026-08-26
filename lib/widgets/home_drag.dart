import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/home_list_order.dart';

/// 自建拖影：跟手时 duration=0，松手飞入时才动画。全程同一层，不卸再插。
class HomeDragFlyLayer extends StatelessWidget {
  final double top;
  final double destTop;
  final double left;
  final double destLeft;
  final double width;
  final double? height;
  final Widget child;
  final bool flying;
  final bool lifted;
  final Alignment scaleAlignment;
  final Curve curve;
  const HomeDragFlyLayer({
    super.key,
    required this.top,
    required this.destTop,
    required this.left,
    double? destLeft,
    required this.width,
    required this.child,
    this.height,
    this.flying = true,
    this.lifted = false,
    this.scaleAlignment = Alignment.center,
    this.curve = Curves.easeOutBack,
  }) : destLeft = destLeft ?? left;

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: Stack(
        children: [
          AnimatedPositioned(
            duration: flying ? kHomeDragFlyDuration : Duration.zero,
            curve: curve,
            top: flying ? destTop : top,
            left: flying ? destLeft : left,
            width: width,
            height: height,
            child: AnimatedScale(
              scale: lifted ? 1.018 : 1.0,
              alignment: scaleAlignment,
              duration: kHomeDragScaleDuration,
              curve: Curves.easeOutCubic,
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

/// 主页 / DSH 共用的长按拖拽手势入口。
///
/// 不使用 [LongPressDraggable] / [DragTarget]：拖拽反馈、排序预览和命中
/// 全部由页面状态机管理，避免 Flutter 在拖拽开始时重建原手势树。
class HomeLongPressDrag extends StatefulWidget {
  final Widget child;
  final FutureOr<void> Function(LongPressStartDetails details) onDragStart;
  final void Function(LongPressMoveUpdateDetails details) onDragUpdate;
  final FutureOr<void> Function(LongPressEndDetails details) onDragEnd;
  final FutureOr<void> Function()? onDragCancel;
  final FutureOr<void> Function()? onDragSettled;
  final bool enabled;

  const HomeLongPressDrag({
    super.key,
    required this.child,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    this.onDragCancel,
    this.onDragSettled,
    this.enabled = true,
  });

  @override
  State<HomeLongPressDrag> createState() => _HomeLongPressDragState();
}

class _HomeLongPressDragState extends State<HomeLongPressDrag> {
  bool _dragging = false;
  bool _finishing = false;

  Future<void> _start(LongPressStartDetails details) async {
    if (!widget.enabled || _dragging || _finishing) return;
    setState(() => _dragging = true);
    await widget.onDragStart(details);
  }

  void _move(LongPressMoveUpdateDetails details) {
    if (!_dragging || _finishing) return;
    widget.onDragUpdate(details);
  }

  Future<void> _finish(FutureOr<void> Function() callback) async {
    if (!_dragging || _finishing) return;
    _finishing = true;
    try {
      await callback();
    } finally {
      if (mounted) {
        setState(() {
          _dragging = false;
          _finishing = false;
        });
        // 先让源卡片以最终顺序绘制一帧，再卸掉飞行层，避免重排时露出空帧。
        await WidgetsBinding.instance.endOfFrame;
      }
      await widget.onDragSettled?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        LongPressGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
              () => LongPressGestureRecognizer(
                duration: const Duration(milliseconds: 350),
              ),
              (recognizer) {
                recognizer.onLongPressStart = widget.enabled
                    ? (details) => unawaited(_start(details))
                    : null;
                recognizer.onLongPressMoveUpdate = widget.enabled
                    ? _move
                    : null;
                recognizer.onLongPressEnd = widget.enabled
                    ? (details) =>
                          unawaited(_finish(() => widget.onDragEnd(details)))
                    : null;
                recognizer.onLongPressCancel =
                    widget.enabled && widget.onDragCancel != null
                    ? () => unawaited(_finish(widget.onDragCancel!))
                    : null;
              },
            ),
      },
      child: Theme(
        data: Theme.of(context).copyWith(
          splashFactory: NoSplash.splashFactory,
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          focusColor: Colors.transparent,
        ),
        child: IgnorePointer(
          ignoring: _dragging,
          child: AnimatedOpacity(
            opacity: _dragging ? 0 : 1,
            duration: Duration.zero,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// 主页 / DSH 共用的跟手拖影。长按插入，松手飞入，最后再卸。
class HomeDragOverlay {
  OverlayEntry? _entry;
  double top = 0;
  double left = 0;
  double width = 200;
  double? height;
  Widget child = const SizedBox.shrink();
  bool flying = false;
  double destTop = 0;
  double destLeft = 0;
  Offset grabOffset = Offset.zero;
  bool lifted = false;
  Alignment scaleAlignment = Alignment.center;
  Curve flyCurve = Curves.easeOutBack;

  bool get isShowing => _entry != null;

  void show(
    OverlayState overlay, {
    required Offset topLeft,
    required Size size,
    double? visualHeight,
    required Widget child,
    Offset? pointerGlobal,
    Alignment scaleAlignment = Alignment.center,
  }) {
    top = topLeft.dy;
    left = topLeft.dx;
    width = size.width > 1 ? size.width : 200;
    // `size` is the list slot geometry. A session slot also contains the
    // bottom gap, while the feedback itself must be constrained to the card
    // body; otherwise the first lifted frame stretches before scaling.
    height = (visualHeight != null && visualHeight > 1)
        ? visualHeight
        : (size.height > 1 ? size.height : null);
    this.child = child;
    this.scaleAlignment = scaleAlignment;
    flying = false;
    lifted = false;
    flyCurve = Curves.easeOutBack;
    destTop = top;
    destLeft = left;
    grabOffset = pointerGlobal == null
        ? Offset(width / 2, (height ?? 0) / 2)
        : pointerGlobal - topLeft;
    if (_entry == null) {
      _entry = OverlayEntry(
        builder: (_) => IgnorePointer(
          child: HomeDragFlyLayer(
            top: top,
            destTop: destTop,
            left: left,
            destLeft: destLeft,
            width: width,
            height: height,
            flying: flying,
            lifted: lifted,
            scaleAlignment: this.scaleAlignment,
            curve: flyCurve,
            child: this.child,
          ),
        ),
      );
      overlay.insert(_entry!);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_entry == null) return;
        lifted = true;
        _entry!.markNeedsBuild();
      });
    } else {
      _entry!.markNeedsBuild();
    }
  }

  void follow(Offset topLeft) {
    top = topLeft.dy;
    left = topLeft.dx;
    flying = false;
    _entry?.markNeedsBuild();
  }

  void followGlobal(Offset global) {
    follow(global - grabOffset);
  }

  Future<void> flyTo(
    Offset destination, {
    Curve curve = Curves.easeOutBack,
  }) async {
    destTop = destination.dy;
    destLeft = destination.dx;
    flying = true;
    lifted = true;
    flyCurve = curve;
    _entry?.markNeedsBuild();
    final tail = kHomeDragFlyDuration - kHomeDragScaleDuration;
    if (tail > Duration.zero) await Future<void>.delayed(tail);
    if (_entry == null) return;
    // 缩放回落放在飞行尾段，位置和落点同时收住，避免到位后突然缩小。
    lifted = false;
    _entry?.markNeedsBuild();
    await Future<void>.delayed(kHomeDragScaleDuration);
  }

  Future<void> land() async {
    if (_entry == null) return;
    flying = false;
    lifted = false;
    _entry?.markNeedsBuild();
    await Future<void>.delayed(kHomeDragScaleDuration);
  }

  void remove() {
    _entry?.remove();
    _entry = null;
    flying = false;
    lifted = false;
  }
}

/// 拖动过程中其它卡片给被拖项让位的位移。
class HomeDragShift extends ImplicitlyAnimatedWidget {
  final double dy;
  final bool snap;
  final Widget child;
  const HomeDragShift({
    super.key,
    required this.dy,
    required this.child,
    this.snap = false,
    Duration duration = kHomeDragSqueezeDuration,
  }) : super(
         duration: snap ? Duration.zero : duration,
         curve: Curves.easeOutCubic,
       );

  @override
  ImplicitlyAnimatedWidgetState<HomeDragShift> createState() =>
      _HomeDragShiftState();
}

class _HomeDragShiftState extends AnimatedWidgetBaseState<HomeDragShift> {
  Tween<double>? _dy;

  @override
  void forEachTween(TweenVisitor<dynamic> visitor) {
    _dy =
        visitor(_dy, widget.dy, (v) => Tween<double>(begin: v as double))
            as Tween<double>?;
  }

  @override
  void didUpdateWidget(covariant HomeDragShift oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.snap) {
      _dy?.begin = widget.dy;
      _dy?.end = widget.dy;
      controller.value = 1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final y = widget.snap ? widget.dy : (_dy?.evaluate(animation) ?? widget.dy);
    // GlobalKey 挂在本组件上。测量必须读不含位移的布局盒，
    // 否则会把动画中的 Translate 当成槽位，插入下标来回跳。
    return SizedBox(
      child: Transform.translate(
        offset: Offset(0, y),
        transformHitTests: true,
        child: widget.child,
      ),
    );
  }
}

/// 源列表空占位收起 / 打开。
class HomeDragHeightFactor extends ImplicitlyAnimatedWidget {
  final double factor;
  final bool snap;
  final Widget child;
  const HomeDragHeightFactor({
    super.key,
    required this.factor,
    required this.child,
    this.snap = false,
    Duration duration = kHomeDragSqueezeDuration,
  }) : super(
         duration: snap ? Duration.zero : duration,
         curve: Curves.easeOutCubic,
       );

  @override
  ImplicitlyAnimatedWidgetState<HomeDragHeightFactor> createState() =>
      _HomeDragHeightFactorState();
}

class _HomeDragHeightFactorState
    extends AnimatedWidgetBaseState<HomeDragHeightFactor> {
  Tween<double>? _factor;

  @override
  void forEachTween(TweenVisitor<dynamic> visitor) {
    _factor =
        visitor(
              _factor,
              widget.factor,
              (v) => Tween<double>(begin: v as double),
            )
            as Tween<double>?;
  }

  @override
  void didUpdateWidget(covariant HomeDragHeightFactor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.snap) {
      _factor?.begin = widget.factor;
      _factor?.end = widget.factor;
      controller.value = 1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final factor = widget.snap
        ? widget.factor
        : (_factor?.evaluate(animation) ?? widget.factor).clamp(0.0, 1.0);
    return ClipRect(
      child: Align(
        alignment: Alignment.topCenter,
        heightFactor: factor.clamp(0.0, 1.0),
        child: widget.child,
      ),
    );
  }
}

/// 跨项目可释放时在目标列表顶部让出的空隙。
class HomeDragInsertGap extends StatelessWidget {
  final double height;
  final bool snap;
  const HomeDragInsertGap({super.key, required this.height, this.snap = false});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: snap ? Duration.zero : kHomeDragSqueezeDuration,
      curve: Curves.easeOutCubic,
      height: height < 0 ? 0 : height,
    );
  }
}

/// 长按拖起整张卡片的反馈层：独立树，避免和列表项抢同一份 State。
Widget homeDragFeedbackClone(
  BuildContext context, {
  required Widget child,
  double? width,
  double? height,
}) {
  Widget lifted = child;
  if (kHomeDragLiftWholeCard) {
    final w = homeDragFeedbackWidth(context, width: width);
    final h = height != null && height > 1 ? height : null;
    lifted = RepaintBoundary(
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        elevation: 0,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(width: w.toDouble(), height: h, child: child),
      ),
    );
  }
  if (!kHomeDragFeedbackIsClone) return lifted;
  return IgnorePointer(child: lifted);
}

/// 读取一组 GlobalKey 对应槽位的高度和中心 Y。任一槽未布局完成返回 false。
/// [keys] 必须挂在 Transform 外面的布局盒上，禁止再扣让位位移。
bool homeDragReadSlotGeometry(
  List<GlobalKey> keys,
  List<double> heights,
  List<double> centers,
) {
  final nextHeights = <double>[];
  final nextCenters = <double>[];
  for (var i = 0; i < keys.length; i++) {
    final box = keys[i].currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return false;
    final top = box.localToGlobal(Offset.zero).dy;
    nextHeights.add(box.size.height);
    nextCenters.add(top + box.size.height / 2);
  }
  heights
    ..clear()
    ..addAll(nextHeights);
  centers
    ..clear()
    ..addAll(nextCenters);
  return true;
}

/// 拖影宽度：优先用测到的卡片宽，禁止落到 0（release 下会「拖着空气」）。
double homeDragFeedbackWidth(BuildContext context, {double? width}) {
  if (width != null && width > 1) return width;
  final size = context.size?.width ?? 0;
  if (size > 1) return size;
  return (MediaQuery.sizeOf(context).width - 24).clamp(200, 640);
}

(Offset, Size) homeDragOriginSlot(GlobalKey key) {
  final box = key.currentContext?.findRenderObject();
  if (box is RenderBox && box.hasSize) {
    return (box.localToGlobal(Offset.zero), box.size);
  }
  return (Offset.zero, Size.zero);
}
