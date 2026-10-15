import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shiyi_agent_app/widgets/chat_liquid_glass.dart';

/// 共享液态玻璃按钮：拾忆首页空态与 DSH 各空态/错误态主按钮共用它。
/// 这里守住「能构建、能点、两套主题都成立」。
void main() {
  testWidgets('强调款液态玻璃按钮可点击，深浅两套主题都能构建', (tester) async {
    var taps = 0;
    for (final isDark in [true, false]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: isDark ? ThemeData.dark() : ThemeData.light(),
          home: Scaffold(
            body: Center(
              child: GlassActionButton(
                label: '新建项目',
                icon: Icons.add,
                onPressed: () => taps++,
                accent: true,
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('新建项目'));
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(taps, 2);
  });

  testWidgets('onPressed 为空时不可点击', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: Center(
            child: GlassActionButton(
              label: '添加工作数据',
              onPressed: null,
              accent: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('添加工作数据'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(taps, 0);
  });
}
