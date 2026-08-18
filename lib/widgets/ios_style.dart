import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// iOS 化页面共用样式：Material Scaffold 不解析 Cupertino 动态颜色，
/// 这里统一显式取值，避免深色 / 浅色下出现大面积错误底色。
bool isIosDark(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark;

/// Material 页面里打开 Cupertino 弹窗时，沿用当前主题明暗。
/// 字体走系统默认（2026-08-15 起移除内置苹方）。
CupertinoThemeData iosCupertinoTheme(BuildContext context) =>
    CupertinoThemeData(
      brightness: Theme.of(context).brightness,
      textTheme: cupertinoTextTheme(),
    );

/// Cupertino 组件文本主题：使用系统默认字体（返回默认主题即可，
/// 不再注入内置字体族）。
CupertinoTextThemeData cupertinoTextTheme() => const CupertinoTextThemeData();

Color iosGroupedBackground(BuildContext context) =>
    Theme.of(context).scaffoldBackgroundColor;

Color iosSectionBackground(BuildContext context) =>
    isIosDark(context) ? const Color(0xFF1C1C1E) : Colors.white;

BoxDecoration iosSectionDecoration(BuildContext context) => BoxDecoration(
  color: iosSectionBackground(context),
  borderRadius: BorderRadius.circular(10),
);

/// 统一弹窗动画：只做淡入淡出，不做飞入/缩放，低端设备更流畅。
Future<T?> showIosFadeDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  bool useRootNavigator = true,
}) {
  return showGeneralDialog<T>(
    context: context,
    useRootNavigator: useRootNavigator,
    barrierDismissible: barrierDismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (context, animation, secondaryAnimation) => builder(context),
    transitionBuilder: (context, animation, secondaryAnimation, child) =>
        FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
          child: child,
        ),
  );
}

/// 底部操作面板：保持底部弹出位置，动画统一改为淡入淡出。
/// Windows 桌面：改为屏幕居中弹出（宽度自适应，上限 420），
/// 避免在宽窗口底部出现一条窄长的手机式面板。
Future<T?> showIosFadeModalPopup<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  final desktop = Platform.isWindows;
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: .32),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (context, animation, secondaryAnimation) => desktop
        ? Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: builder(context),
            ),
          )
        : Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(top: false, child: builder(context)),
          ),
    transitionBuilder: (context, animation, secondaryAnimation, child) =>
        FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
          child: child,
        ),
  );
}

/// Material 风格底部面板：自带圆角表面，动画统一为淡入淡出。
/// Windows 桌面：改为屏幕居中弹出（宽度自适应，上限 460）。
Future<T?> showIosFadeSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  Color? backgroundColor,
}) {
  final desktop = Platform.isWindows;
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: .32),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (context, animation, secondaryAnimation) => desktop
        ? Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Material(
                color: backgroundColor ?? Theme.of(context).colorScheme.surface,
                borderRadius: const BorderRadius.all(Radius.circular(14)),
                elevation: 16,
                shadowColor: Colors.black.withValues(alpha: .35),
                clipBehavior: Clip.antiAlias,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight:
                        MediaQuery.sizeOf(context).height *
                        (isScrollControlled ? 0.92 : 0.6),
                  ),
                  child: builder(context),
                ),
              ),
            ),
          )
        : Align(
            alignment: Alignment.bottomCenter,
            child: Material(
              color: backgroundColor ?? Theme.of(context).colorScheme.surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(12),
              ),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight:
                      MediaQuery.sizeOf(context).height *
                      (isScrollControlled ? 0.92 : 0.5),
                ),
                child: SafeArea(top: false, child: builder(context)),
              ),
            ),
          ),
    transitionBuilder: (context, animation, secondaryAnimation, child) =>
        FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
          child: child,
        ),
  );
}

/// 比 Flutter 默认 20dp 更紧凑的分组外边距，条目可用宽度更大。
const EdgeInsetsDirectional iosSectionMargin = EdgeInsetsDirectional.fromSTEB(
  12,
  0,
  12,
  10,
);
