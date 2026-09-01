import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/mac_page_route.dart';

void main() {
  testWidgets('MacBackFade 拦截返回并 pop，不会卡在当前页', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () {
                Navigator.push<void>(
                  context,
                  MacPageRoute(
                    builder: (_) => const MacBackFade(
                      child: Scaffold(body: Text('inner-page')),
                    ),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('inner-page'), findsOneWidget);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    await navigator.maybePop();
    await tester.pumpAndSettle();
    expect(find.text('inner-page'), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });
}
