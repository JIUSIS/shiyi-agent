import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// iOS/macOS 风格红绿灯胶囊：作为各主页面左上角的功能入口。
/// 思考中（busy=true）三盏灯按红→黄→绿循环高亮闪烁，完成后全部亮起。
class TrafficLightsButton extends StatefulWidget {
  final VoidCallback? onTap;
  final String tooltip;
  final bool busy;
  const TrafficLightsButton({
    super.key,
    this.onTap,
    this.tooltip = '新建项目',
    this.busy = false,
  });

  @override
  State<TrafficLightsButton> createState() => _TrafficLightsButtonState();
}

class _TrafficLightsButtonState extends State<TrafficLightsButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant TrafficLightsButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.busy != widget.busy) _sync();
  }

  void _sync() {
    if (widget.busy && !_running) {
      _running = true;
      _ctrl.repeat();
    } else if (!widget.busy && _running) {
      _running = false;
      _ctrl.stop();
      _ctrl.value = 1;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  int _activeIndex() {
    if (!widget.busy) return -1;
    final t = _ctrl.value;
    for (var i = 0; i < 3; i++) {
      final start = i / 3.0;
      final end = (i + 1) / 3.0;
      if (t >= start && t < end) return i;
    }
    return 2;
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final button = Container(
      width: 60,
      height: 26,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(13),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isLight ? 0.16 : 0.35),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(13),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Material(
            color: Colors.white.withValues(alpha: isLight ? 0.40 : 0.10),
            child: InkWell(
              onTap: widget.onTap,
              child: AnimatedBuilder(
                animation: _ctrl,
                builder: (context, _) {
                  final active = _activeIndex();
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _TrafficDot(
                        color: const Color(0xFFFF5F57),
                        highlighted: active == 0,
                        dimmed: active >= 0 && active != 0,
                      ),
                      const SizedBox(width: 5),
                      _TrafficDot(
                        color: const Color(0xFFFEBC2E),
                        highlighted: active == 1,
                        dimmed: active >= 0 && active != 1,
                      ),
                      const SizedBox(width: 5),
                      _TrafficDot(
                        color: const Color(0xFF28C840),
                        highlighted: active == 2,
                        dimmed: active >= 0 && active != 2,
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    final capsule = Align(
      alignment: Alignment.center,
      child: button,
    );
    if (widget.tooltip.isEmpty) return capsule;
    return Tooltip(message: widget.tooltip, child: capsule);
  }
}

class _TrafficDot extends StatelessWidget {
  final Color color;
  final bool highlighted;
  final bool dimmed;
  const _TrafficDot({
    required this.color,
    this.highlighted = false,
    this.dimmed = false,
  });

  @override
  Widget build(BuildContext context) {
    final size = highlighted ? 12.0 : 10.0;
    return AnimatedScale(
      scale: highlighted ? 1.2 : 1.0,
      duration: const Duration(milliseconds: 120),
      child: Opacity(
        opacity: dimmed ? 0.35 : 1.0,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: Colors.black.withValues(alpha: .18),
              width: 1,
            ),
            boxShadow: highlighted
                ? [
                    BoxShadow(
                      color: color.withValues(alpha: .65),
                      blurRadius: 6,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
        ),
      ),
    );
  }
}
