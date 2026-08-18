import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/models.dart';
import 'package:shiyi_agent_app/widgets/tool_pill.dart';

void main() {
  testWidgets('运行中的工具胶囊始终显示调用秒数', (tester) async {
    final startedAt = DateTime.now().millisecondsSinceEpoch - 2200;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ToolPill(
            event: ToolEvent(
              name: 'read',
              argsSummary: '{}',
              startedAt: startedAt,
            ),
            index: 1,
            total: 1,
            onTap: () {},
          ),
        ),
      ),
    );

    expect(find.text('read 1/1'), findsOneWidget);
    expect(find.text('2s'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('待机工具胶囊显示工具与零秒', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ToolPillIdle(onTap: () {})),
      ),
    );

    expect(find.text('工具'), findsOneWidget);
    expect(find.text('0.0s'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('工具日志面板显示空态并支持关闭', (tester) async {
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ToolLogPanel(events: const [], onClose: () => closed = true),
        ),
      ),
    );

    expect(find.text('工具调用'), findsOneWidget);
    expect(find.text('暂无工具调用'), findsOneWidget);
    await tester.tap(find.byTooltip('收起'));
    expect(closed, isTrue);
    expect(tester.takeException(), isNull);
  });
}
