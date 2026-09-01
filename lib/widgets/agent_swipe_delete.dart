import 'package:flutter/material.dart';

const double agentDeleteWidth = 76;

/// Agent 行左滑删除：卡片本身不滑动，右缘按手势擦除出红色「删除」。
/// 横向手势进竞技场，横滑时所在列表不会跟着上下滚动。
class AgentSwipeDelete extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final bool showDelete;
  final ValueNotifier<String?>? openNotifier;
  final String? swipeKey;
  final ValueChanged<Rect?>? onOpenRectChanged;

  const AgentSwipeDelete({
    super.key,
    required this.child,
    required this.onTap,
    required this.onDelete,
    required this.showDelete,
    this.openNotifier,
    this.swipeKey,
    this.onOpenRectChanged,
  });

  @override
  State<AgentSwipeDelete> createState() => _AgentSwipeDeleteState();
}

class _AgentSwipeDeleteState extends State<AgentSwipeDelete>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );
  bool _open = false;
  double _dragOffset = 0;

  @override
  void initState() {
    super.initState();
    widget.openNotifier?.addListener(_onOpenChanged);
  }

  @override
  void dispose() {
    widget.openNotifier?.removeListener(_onOpenChanged);
    _ctrl.dispose();
    super.dispose();
  }

  void _onOpenChanged() {
    if (widget.openNotifier?.value != widget.swipeKey && _open) {
      _open = false;
      _ctrl.animateTo(0);
      _syncOpenRect();
    }
  }

  double get _progress => _ctrl.value.clamp(0.0, 1.0);

  void _onDragStart(DragStartDetails d) {
    if (!widget.showDelete) return;
    _dragOffset = _open ? -agentDeleteWidth : 0.0;
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (!widget.showDelete) return;
    if (_ctrl.isAnimating) _ctrl.stop();
    _dragOffset = (_dragOffset + d.delta.dx).clamp(-agentDeleteWidth, 0.0);
    final progress = (-_dragOffset / agentDeleteWidth).clamp(0.0, 1.0);
    _ctrl.value = progress;
    if (progress > 0 &&
        widget.openNotifier != null &&
        widget.swipeKey != null) {
      widget.openNotifier!.value = widget.swipeKey;
    }
  }

  void _onDragEnd(DragEndDetails d) {
    if (!widget.showDelete) return;
    final velocity = d.primaryVelocity ?? 0;
    final open = _ctrl.value > 0.35 || velocity < -600;
    _dragOffset = open ? -agentDeleteWidth : 0.0;
    setState(() => _open = open);
    _ctrl.animateTo(open ? 1 : 0);
    widget.openNotifier?.value = open ? widget.swipeKey : null;
    _syncOpenRect();
  }

  void _handleTap() {
    if (_open) {
      setState(() => _open = false);
      _ctrl.animateTo(0);
      widget.openNotifier?.value = null;
      _syncOpenRect();
      return;
    }
    widget.onTap();
  }

  void _syncOpenRect() {
    final onRect = widget.onOpenRectChanged;
    if (onRect == null) return;
    if (_open) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_open) return;
        final box = context.findRenderObject();
        if (box is RenderBox && box.hasSize) {
          onRect(box.localToGlobal(Offset.zero) & box.size);
        }
      });
    } else {
      onRect(null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final progress = _progress;
        final revealWidth = progress * agentDeleteWidth;
        return Stack(
          children: [
            ClipRect(
              clipper: _RightEraseClipper(revealWidth),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _handleTap,
                onHorizontalDragStart: widget.showDelete ? _onDragStart : null,
                onHorizontalDragUpdate: widget.showDelete
                    ? _onDragUpdate
                    : null,
                onHorizontalDragEnd: widget.showDelete ? _onDragEnd : null,
                child: widget.child,
              ),
            ),
            if (widget.showDelete)
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                width: agentDeleteWidth,
                child: ClipRect(
                  clipper: _LeftRevealClipper(revealWidth),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onDelete,
                    onHorizontalDragStart: _onDragStart,
                    onHorizontalDragUpdate: _onDragUpdate,
                    onHorizontalDragEnd: _onDragEnd,
                    child: const _AgentDeleteButton(),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _AgentDeleteButton extends StatelessWidget {
  const _AgentDeleteButton();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 10, 10),
      child: Container(
        width: double.infinity,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFFFF3B30),
          borderRadius: BorderRadius.circular(7),
        ),
        child: const Text(
          '删除',
          style: TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _RightEraseClipper extends CustomClipper<Rect> {
  final double eraseWidth;
  const _RightEraseClipper(this.eraseWidth);

  @override
  Rect getClip(Size size) => Rect.fromLTWH(
    0,
    0,
    (size.width - eraseWidth).clamp(0, size.width),
    size.height,
  );

  @override
  bool shouldReclip(_RightEraseClipper oldDelegate) =>
      oldDelegate.eraseWidth != eraseWidth;
}

class _LeftRevealClipper extends CustomClipper<Rect> {
  final double revealWidth;
  const _LeftRevealClipper(this.revealWidth);

  @override
  Rect getClip(Size size) => Rect.fromLTWH(
    size.width - revealWidth,
    0,
    revealWidth.clamp(0, size.width),
    size.height,
  );

  @override
  bool shouldReclip(_LeftRevealClipper oldDelegate) =>
      oldDelegate.revealWidth != revealWidth;
}
