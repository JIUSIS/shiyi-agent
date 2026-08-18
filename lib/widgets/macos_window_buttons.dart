import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../services/window_control.dart';

/// macOS 风格全局标题栏（仅 Windows 无边框窗口使用）：
/// 高 44px，左侧红黄绿三键（关闭/最小化/最大化-还原），
/// 其余区域为窗口拖拽区（拖拽、双击最大化由 win32 WM_NCHITTEST 处理）。
class MacTitleBar extends StatefulWidget {
  const MacTitleBar({super.key});

  @override
  State<MacTitleBar> createState() => _MacTitleBarState();
}

class _MacTitleBarState extends State<MacTitleBar> {
  @override
  void initState() {
    super.initState();
    WindowControl.instance.init();
  }

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).scaffoldBackgroundColor;
    return Container(
      height: 44,
      color: bg,
      child: Row(
        children: [
          const SizedBox(width: 14),
          _TrafficLight(
            color: const Color(0xFFFF5F57),
            hoverIcon: CupertinoIcons.multiply,
            tooltip: '关闭',
            onTap: WindowControl.instance.close,
          ),
          const SizedBox(width: 8),
          _TrafficLight(
            color: const Color(0xFFFEBC2E),
            hoverIcon: CupertinoIcons.minus,
            tooltip: '最小化',
            onTap: WindowControl.instance.minimize,
          ),
          const SizedBox(width: 8),
          ValueListenableBuilder<bool>(
            valueListenable: WindowControl.instance.isMaximized,
            builder: (_, maximized, _) => _TrafficLight(
              color: const Color(0xFF28C840),
              // 最大化状态：hover 显示「还原」；普通状态显示「最大化」。
              hoverIcon: maximized
                  ? CupertinoIcons.arrow_down_right
                  : CupertinoIcons.arrow_up_left,
              tooltip: maximized ? '还原' : '最大化',
              onTap: WindowControl.instance.toggleMaximize,
            ),
          ),
          const Spacer(),
          const SizedBox(width: 14),
        ],
      ),
    );
  }
}

/// 单个红黄绿按钮：12px 圆形，悬停显示功能图标（macOS 惯例）。
class _TrafficLight extends StatefulWidget {
  final Color color;
  final IconData hoverIcon;
  final String tooltip;
  final VoidCallback onTap;
  const _TrafficLight({
    required this.color,
    required this.hoverIcon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  State<_TrafficLight> createState() => _TrafficLightState();
}

class _TrafficLightState extends State<_TrafficLight> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: widget.color,
              shape: BoxShape.circle,
            ),
            child: _hover
                ? Icon(
                    widget.hoverIcon,
                    size: 8,
                    color: Colors.black.withValues(alpha: .55),
                  )
                : null,
          ),
        ),
      ),
    );
  }
}
