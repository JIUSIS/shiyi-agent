import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/widgets/ios_style.dart';

void main() {
  testWidgets('showIosFadeModalPopup 能弹出 CupertinoActionSheet', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: CupertinoButton(
                onPressed: () {
                  showIosFadeModalPopup<String>(
                    context: context,
                    builder: (ctx) => CupertinoActionSheet(
                      title: const Text('模型预设'),
                      actions: [
                        CupertinoActionSheetAction(
                          onPressed: () => Navigator.pop(ctx, 'DeepSeek'),
                          child: const Text('DeepSeek'),
                        ),
                      ],
                      cancelButton: CupertinoActionSheetAction(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('取消'),
                      ),
                    ),
                  );
                },
                child: const Text('打开预设'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开预设'));
    await tester.pumpAndSettle();

    expect(find.text('模型预设'), findsOneWidget);
    expect(find.text('DeepSeek'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
  });

  testWidgets('showIosFadeSheet 能弹出底部面板', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: CupertinoButton(
                onPressed: () {
                  showIosFadeSheet<void>(
                    context: context,
                    builder: (ctx) => const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('工作目录'),
                    ),
                  );
                },
                child: const Text('打开面板'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开面板'));
    await tester.pumpAndSettle();

    expect(find.text('工作目录'), findsOneWidget);
  });
}
