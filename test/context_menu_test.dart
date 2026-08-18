import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/widgets/context_menu.dart';

void main() {
  testWidgets('showDesktopMenu 弹出菜单，点击条目后执行对应回调', (tester) async {
    var tapped = '';
    final items = [
      DesktopMenuItem(
        label: '重命名',
        icon: Icons.edit_outlined,
        onTap: () => tapped = '重命名',
      ),
      DesktopMenuItem(
        label: '删除',
        icon: Icons.delete_outline,
        iconColor: Colors.red,
        onTap: () => tapped = '删除',
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () {
                  final box = context.findRenderObject() as RenderBox;
                  showDesktopMenu(
                    context,
                    globalPosition: box.localToGlobal(Offset.zero),
                    items: items,
                  );
                },
                child: const Text('打开菜单'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开菜单'));
    await tester.pumpAndSettle();
    expect(find.text('重命名'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(tapped, '删除');
  });

  testWidgets('showDesktopMenu 空条目列表直接返回，不弹菜单', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox())),
    );
    final ctx = tester.element(find.byType(Scaffold));
    final called = await showDesktopMenu(
      ctx,
      globalPosition: Offset.zero,
      items: const [],
    );
    expect(called, isFalse);
  });
}
