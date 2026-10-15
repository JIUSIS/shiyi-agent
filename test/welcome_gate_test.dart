import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shiyi_agent_app/core/app_state.dart';
import 'package:shiyi_agent_app/screens/welcome_screen.dart';

/// 首启顺序回归：权限/初始化（`startup`）没走完时不能先进主页，
/// 走完后要走「欢迎页淡出 → 主页淡入」，不能跳黑或突然切换。
/// 见 docs/fix-log.md #385。
void main() {
  Opacity heldOpacity(WidgetTester tester) => tester.widget<Opacity>(
    find
        .descendant(
          of: find.byType(AnimatedBuilder),
          matching: find.byType(Opacity),
        )
        .first,
  );

  testWidgets('启动序列没完成时留在欢迎页并给出准备提示', (tester) async {
    final gate = Completer<void>();
    var entered = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: WelcomeScreen(
          shiyi: ShiyiState(),
          startup: gate.future,
          enterHome: (_) => entered++,
        ),
      ),
    );

    // 欢迎动画（2.6s）早已结束，但启动序列没完成：不能进主页。
    // 按帧推进（真实掉帧/跳帧也要能停在停留段）。
    for (var i = 0; i < 220; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(entered, 0);
    expect(find.byType(WelcomeScreen), findsOneWidget);
    expect(find.text('首次启动正在准备，请稍候…'), findsOneWidget);
    // 画面保持全亮（停在停留段），不压暗、不跳黑。
    expect(heldOpacity(tester).opacity, 1.0);

    // 授权 + 初始化走完后：先补 0.8s 淡出，淡出结束才进主页。
    gate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(entered, 0);
    await tester.pump(const Duration(milliseconds: 700));
    expect(entered, 1);
  });

  testWidgets('启动序列完成、动画也结束后自动进主页（且不闪准备提示）', (tester) async {
    var entered = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: WelcomeScreen(
          shiyi: ShiyiState(),
          startup: Future<void>.value(),
          enterHome: (_) => entered++,
        ),
      ),
    );
    await tester.pump();
    // 已经授权过：正常启动不该闪一下「准备中」提示。
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('首次启动正在准备，请稍候…'), findsNothing);
    // 动画淡出走完才进主页。
    await tester.pump(const Duration(milliseconds: 1800));
    expect(entered, 1);
  });
}
