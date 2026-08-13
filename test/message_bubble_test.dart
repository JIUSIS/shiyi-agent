import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/models.dart';
import 'package:shiyi_agent_app/widgets/message_bubble.dart';

ChatMessage _assistantMessage() => ChatMessage(
  id: 'a1',
  sessionId: 's1',
  role: 'assistant',
  content: '这是测试回复，包含一段用于渲染气泡的文字。',
  createdAt: 0,
);

ChatMessage _userMessage() => ChatMessage(
  id: 'u1',
  sessionId: 's1',
  role: 'user',
  content: '你好',
  createdAt: 0,
);

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(useMaterial3: true, brightness: Brightness.light),
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: child,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('assistant bubble 渲染内容且窄屏不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _pump(
      tester,
      MessageBubble(
        message: _assistantMessage(),
        onCopy: (_) {},
        onDelete: (_) {},
        onRegenerate: (_) {},
        onSaveMemory: (_) {},
        onSaveSkill: (_) {},
        onSpeak: (_) {},
      ),
    );

    expect(find.textContaining('测试回复'), findsOneWidget);
    expect(find.byTooltip('复制'), findsOneWidget);
    expect(find.byTooltip('重新生成'), findsOneWidget);
    expect(find.byTooltip('保存记忆'), findsOneWidget);
    expect(find.byTooltip('删除'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final bubbleLeft = tester
        .renderObject<RenderBox>(find.byKey(const ValueKey('assistantBubble')))
        .localToGlobal(Offset.zero)
        .dx;
    final barLeft = tester
        .renderObject<RenderBox>(find.byKey(const ValueKey('messageActionBar')))
        .localToGlobal(Offset.zero)
        .dx;
    expect(barLeft, bubbleLeft);
  });

  testWidgets('user bubble 渲染内容且操作条靠右', (tester) async {
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _pump(
      tester,
      MessageBubble(
        message: _userMessage(),
        onCopy: (_) {},
        onDelete: (_) {},
        onSaveMemory: (_) {},
        onSaveSkill: (_) {},
      ),
    );

    expect(find.text('你好'), findsOneWidget);
    expect(find.byTooltip('复制'), findsOneWidget);
    expect(find.byTooltip('保存记忆'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final bubbleBox = tester.renderObject<RenderBox>(
      find.byKey(const ValueKey('userBubble')),
    );
    final barBox = tester.renderObject<RenderBox>(
      find.byKey(const ValueKey('messageActionBar')),
    );
    expect(
      barBox.localToGlobal(Offset(barBox.size.width, 0)).dx,
      bubbleBox.localToGlobal(Offset(bubbleBox.size.width, 0)).dx,
    );
  });

  testWidgets('长按气泡弹出 iOS 操作面板并支持选择文字', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _pump(
      tester,
      MessageBubble(
        message: _assistantMessage(),
        onCopy: (_) {},
        onDelete: (_) {},
        onRegenerate: (_) {},
        onSaveMemory: (_) {},
        onSaveSkill: (_) {},
        onSpeak: (_) {},
      ),
    );

    await tester.longPress(find.textContaining('测试回复'));
    await tester.pumpAndSettle();

    expect(find.text('消息操作'), findsOneWidget);
    expect(find.text('选择文字'), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);

    await tester.tap(find.text('选择文字'));
    await tester.pumpAndSettle();

    expect(find.text('完成'), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
