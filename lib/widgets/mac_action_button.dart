import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// macOS 风格工具栏胶囊按钮（Windows 桌面版使用）：
/// 毛玻璃背景 + 居中图标，尺寸与旧 TrafficLightsButton 一致。
///
/// 窗口控制红黄绿已移入全局标题栏（MacTitleBar），页面内再用红绿灯
/// 会与窗口控制语义混淆，因此 Windows 上统一替换为该按钮。
class MacActionButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  const MacActionButton({
    super.key,
    required this.icon,
    this.tooltip = '',
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final fg = dark
        ? Colors.white.withValues(alpha: .85)
        : Colors.black.withValues(alpha: .62);
    final button = Container(
      width: 60,
      height: 26,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(13),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.35 : 0.16),
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
            color: Colors.white.withValues(alpha: dark ? 0.10 : 0.40),
            child: InkWell(
              onTap: onTap,
              child: Icon(icon, size: 13, color: fg),
            ),
          ),
        ),
      ),
    );
    if (tooltip.isEmpty) return button;
    return Tooltip(message: tooltip, child: button);
  }
}

/// 毛玻璃设置胶囊按钮（红绿灯胶囊同款设计，内容为横线 + 齿轮）：
/// 与拾忆会话页右上角设置入口同款，供 DSH 等页面复用。
class FrostedSettingsButton extends StatelessWidget {
  final VoidCallback onPressed;
  const FrostedSettingsButton({super.key, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final fg = dark
        ? Colors.white.withValues(alpha: 0.85)
        : Colors.black.withValues(alpha: 0.62);
    return Tooltip(
      message: '设置',
      child: GestureDetector(
        onTap: onPressed,
        child: Align(
          alignment: Alignment.center,
          child: Container(
            width: 60,
            height: 26,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(13),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? 0.35 : 0.16),
                  blurRadius: 12,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(13),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: Container(
                  color: Colors.white.withValues(alpha: dark ? 0.10 : 0.40),
                  alignment: Alignment.center,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // 两条短横线：与红绿灯胶囊的圆点横排呼应，统一风格。
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(width: 11, height: 1.6, color: fg),
                          const SizedBox(height: 3.5),
                          Container(width: 11, height: 1.6, color: fg),
                        ],
                      ),
                      const SizedBox(width: 5),
                      Icon(Icons.settings_outlined, size: 13, color: fg),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
