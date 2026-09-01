import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/widgets/agent_swipe_delete.dart';

void main() {
  testWidgets('横滑只擦除揭示删除，不滚动列表', (tester) async {
    var deleted = false;
    final controller = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: controller,
            children: [
              for (var i = 0; i < 20; i++)
                AgentSwipeDelete(
                  showDelete: true,
                  onTap: () {},
                  onDelete: () => deleted = true,
                  child: Container(
                    key: ValueKey('row_$i'),
                    height: 60,
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text('Agent $i'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    await tester.drag(
      find.byKey(const ValueKey('row_0')),
      const Offset(-140, 0),
    );
    await tester.pumpAndSettle();

    expect(controller.offset, 0);
    final delete = find.text('删除').hitTestable();
    expect(delete, findsOneWidget);
    await tester.tap(delete);
    await tester.pump();
    expect(deleted, true);
  });

  testWidgets('纵向拖动正常滚动，不揭示删除', (tester) async {
    final controller = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: controller,
            children: [
              for (var i = 0; i < 20; i++)
                AgentSwipeDelete(
                  showDelete: true,
                  onTap: () {},
                  onDelete: () {},
                  child: Container(
                    key: ValueKey('row_$i'),
                    height: 60,
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text('Agent $i'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    await tester.drag(
      find.byKey(const ValueKey('row_0')),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();

    expect(controller.offset, greaterThan(0));
    expect(find.text('删除').hitTestable(), findsNothing);
  });

  testWidgets('滑开后右滑可以收回', (tester) async {
    final controller = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: controller,
            children: [
              for (var i = 0; i < 20; i++)
                AgentSwipeDelete(
                  showDelete: true,
                  onTap: () {},
                  onDelete: () {},
                  child: Container(
                    key: ValueKey('row_$i'),
                    height: 60,
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text('Agent $i'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    await tester.drag(
      find.byKey(const ValueKey('row_0')),
      const Offset(-140, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('删除').hitTestable(), findsOneWidget);

    await tester.drag(
      find.byKey(const ValueKey('row_0')),
      const Offset(140, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('删除').hitTestable(), findsNothing);
    expect(controller.offset, 0);
  });

  testWidgets('从删除按钮上起手右滑也能收回', (tester) async {
    final controller = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: controller,
            children: [
              for (var i = 0; i < 20; i++)
                AgentSwipeDelete(
                  showDelete: true,
                  onTap: () {},
                  onDelete: () {},
                  child: Container(
                    key: ValueKey('row_$i'),
                    height: 60,
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text('Agent $i'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    final row = tester.getRect(find.byKey(const ValueKey('row_0')));
    await tester.dragFrom(row.center - const Offset(300, 0), const Offset(-140, 0));
    await tester.pumpAndSettle();
    expect(find.text('删除').hitTestable(), findsOneWidget);

    // 从删除按钮区域内起手右滑
    await tester.dragFrom(row.topRight - const Offset(30, -30), const Offset(140, 0));
    await tester.pumpAndSettle();
    expect(find.text('删除').hitTestable(), findsNothing);
    expect(controller.offset, 0);
  });
}
