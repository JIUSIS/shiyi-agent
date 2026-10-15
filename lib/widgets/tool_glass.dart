import 'package:flutter/material.dart';

import 'package:liquid_glass_easy/liquid_glass_easy.dart';

/// 工具胶囊的液态玻璃外观（拾忆信息流胶囊、群聊成员气泡胶囊共用一套）。
/// 从 `tool_pill.dart` 抽出来，避免「tool_pill ↔ code_change_card」互相 import 成环。
BoxShadow toolGlassShadow(BuildContext context) {
  final isLight = Theme.of(context).brightness == Brightness.light;
  return BoxShadow(
    color: Colors.black.withValues(alpha: isLight ? 0.16 : 0.35),
    blurRadius: 12,
    offset: const Offset(0, 3),
  );
}

Color toolGlassBackground(BuildContext context) {
  final isLight = Theme.of(context).brightness == Brightness.light;
  return Colors.white.withValues(alpha: isLight ? 0.40 : 0.10);
}

LiquidGlassStyle toolGlassStyle(
  BuildContext context, {
  double cornerRadius = 14,
}) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return LiquidGlassStyle(
    shape: LiquidGlassShape.continuousRoundedRectangle(
      cornerRadius: cornerRadius,
      borderWidth: 1,
      borderColor: Colors.white.withValues(alpha: dark ? .16 : .52),
      lightIntensity: .8,
      lightDirection: 110,
    ),
    appearance: LiquidGlassAppearance(
      color: toolGlassBackground(context),
      blur: const LiquidGlassBlur(sigmaX: 16, sigmaY: 16),
      saturation: 1.1,
    ),
    refraction: const LiquidGlassRefraction(
      distortion: .06,
      distortionWidth: 18,
      magnification: 1.01,
      chromaticAberration: .001,
    ),
  );
}

/// 液态玻璃胶囊外壳：圆角 + 阴影 + 折射 + 点击水波。
Widget toolPillShell({
  required BuildContext context,
  required VoidCallback onTap,
  required Widget child,
  double cornerRadius = 14,
}) {
  return Container(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(cornerRadius),
      boxShadow: [toolGlassShadow(context)],
    ),
    child: LiquidGlassLens(
      style: toolGlassStyle(context, cornerRadius: cornerRadius),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(cornerRadius),
        child: InkWell(
          borderRadius: BorderRadius.circular(cornerRadius),
          onTap: onTap,
          child: child,
        ),
      ),
    ),
  );
}

/// 液态玻璃面板（群聊调用日志、展开后的完整内容块用）。
Widget toolGlassPanel({
  required BuildContext context,
  required Widget child,
  double cornerRadius = 14,
  EdgeInsetsGeometry padding = const EdgeInsets.symmetric(
    horizontal: 10,
    vertical: 8,
  ),
}) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return Container(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(cornerRadius),
      boxShadow: [toolGlassShadow(context)],
    ),
    child: LiquidGlassLens(
      style: toolGlassStyle(context, cornerRadius: cornerRadius),
      child: Container(
        padding: padding,
        child: DefaultTextStyle(
          style: TextStyle(
            color: dark ? const Color(0xFFE6E6E6) : const Color(0xFF2C2C2E),
            fontSize: 12,
          ),
          child: child,
        ),
      ),
    ),
  );
}
