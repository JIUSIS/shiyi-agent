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

  testWidgets('showIosConfirmDialog 居中显示短文案并回传确认', (tester) async {
    bool? confirmed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: CupertinoButton(
                onPressed: () async {
                  confirmed = await showIosConfirmDialog(
                    context: context,
                    title: '压缩上下文？',
                    message: '较早的对话会变成摘要，完整记录仍保留在本地。',
                    confirmLabel: '压缩',
                  );
                },
                child: const Text('打开确认'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开确认'));
    await tester.pumpAndSettle();

    expect(find.byType(CupertinoAlertDialog), findsOneWidget);
    expect(find.text('压缩上下文？'), findsOneWidget);
    expect(find.text('较早的对话会变成摘要，完整记录仍保留在本地。'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('压缩'), findsOneWidget);

    await tester.tap(find.text('压缩'));
    await tester.pumpAndSettle();
    expect(confirmed, isTrue);
  });

  testWidgets('showIosConfirmDialog 取消时回传 false', (tester) async {
    bool? confirmed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: CupertinoButton(
                onPressed: () async {
                  confirmed = await showIosConfirmDialog(
                    context: context,
                    title: '压缩上下文？',
                    message: '较早的对话会变成摘要，完整记录仍保留。',
                    confirmLabel: '压缩',
                  );
                },
                child: const Text('打开确认'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开确认'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(confirmed, isFalse);
  });
}
