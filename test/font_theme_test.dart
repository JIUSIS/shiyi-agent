import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/app_theme.dart';
import 'package:shiyi_agent_app/widgets/ios_style.dart';

/// 系统默认字体验证（2026-08-15 起移除内置苹方）：
/// - Material 主题（ThemeData.fontFamily）应为 null（系统默认）
/// - Cupertino 主题（CupertinoTextThemeData）应为默认（null）
/// - 渲染 Text 的字体族应为 null（继承系统默认）
void main() {
  testWidgets('主题字体族为系统默认（Material + Cupertino）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: MacTheme.light(),
        home: Builder(
          builder: (context) => CupertinoTheme(
            data: iosCupertinoTheme(context),
            child: const SizedBox(),
          ),
        ),
      ),
    );
    final ctx = tester.element(find.byType(SizedBox));

    // Material 侧：bodyMedium 继承 ThemeData.fontFamily。
    // Flutter Material 默认字体为 Roboto（未内置打包，实际渲染走系统
    // fallback：Android 系统 CJK / Windows Segoe UI+雅黑）。
    final materialFamily = Theme.of(ctx).textTheme.bodyMedium!.fontFamily;
    expect(materialFamily, 'Roboto',
        reason: 'Material 文本使用 Flutter 默认字体（Roboto，系统 fallback）');

    // Cupertino 侧：组件文本样式继承 iosCupertinoTheme 的 textTheme（默认）。
    // Flutter Cupertino 默认字体族为 CupertinoSystemText（映射平台系统字体）。
    final cupertinoFamily = CupertinoTheme.of(ctx).textTheme.textStyle.fontFamily;
    expect(cupertinoFamily, 'CupertinoSystemText',
        reason: 'Cupertino 组件文本使用系统默认字体');
    expect(
      CupertinoTheme.of(ctx).textTheme.navTitleTextStyle.fontFamily,
      'CupertinoSystemText',
    );
  });

  testWidgets('渲染的 Text 默认字体族为系统默认（继承链）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: MacTheme.dark(),
        home: const Scaffold(
          body: Center(child: Text('测试字体')),
        ),
      ),
    );
    final textStyle = DefaultTextStyle.of(tester.element(find.text('测试字体')));
    expect(textStyle.style.fontFamily, 'Roboto');
  });
}
