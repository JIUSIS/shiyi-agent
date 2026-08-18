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
    expect(
      find.byKey(const ValueKey('assistantLiquidGlassLens')),
      findsOneWidget,
    );
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
    expect(find.byKey(const ValueKey('userLiquidGlassLens')), findsOneWidget);
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

  testWidgets('有注入上下文才显示折叠头，默认收起，点开能看全文', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    const snap =
        'Current runtime context. This snapshot supersedes earlier '
        'runtime-context snapshots.\n\nCurrent DSH file policy: workspace-write.';

    await _pump(tester, MessageBubble(message: _userMessage()));
    expect(find.text('注入上下文'), findsNothing);

    await _pump(
      tester,
      MessageBubble(
        message: ChatMessage(
          id: 'u2',
          sessionId: 's1',
          role: 'user',
          content: 'hi',
          createdAt: 0,
          runtimeContext: snap,
        ),
        onCopy: (_) {},
      ),
    );

    expect(find.text('注入上下文'), findsOneWidget);
    expect(find.text('hi'), findsOneWidget);
    expect(find.textContaining('Current DSH file policy'), findsNothing);

    await tester.tap(find.text('注入上下文'));
    await tester.pumpAndSettle();

    expect(find.text('收起上下文'), findsOneWidget);
    expect(find.textContaining('Current DSH file policy'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('子代理返回信息默认收起，展开后显示返回正文', (tester) async {
    await _pump(
      tester,
      MessageBubble(
        message: ChatMessage(
          id: 'subagent-result',
          sessionId: 's1',
          role: 'assistant',
          content: '<子代理返回信息>\n已完成子任务并返回结果。',
          createdAt: 0,
        ),
      ),
    );

    expect(find.text('子代理返回信息'), findsOneWidget);
    expect(find.textContaining('<子代理返回信息>'), findsNothing);
    expect(find.textContaining('已完成子任务'), findsNothing);

    await tester.tap(find.text('子代理返回信息'));
    await tester.pumpAndSettle();

    expect(find.text('收起子代理'), findsOneWidget);
    expect(find.textContaining('已完成子任务'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('拾忆子代理结果在左侧助手气泡折叠，不隐藏主模型正文', (tester) async {
    await _pump(
      tester,
      MessageBubble(
        message: ChatMessage(
          id: 'shiyi-subagent-result',
          sessionId: 's1',
          role: 'assistant',
          content: '主模型继续回复',
          subagentResult: '子代理真实返回内容',
          createdAt: 0,
        ),
      ),
    );

    expect(find.byKey(const ValueKey('assistantBubble')), findsOneWidget);
    expect(find.text('子代理返回信息'), findsOneWidget);
    expect(find.textContaining('子代理真实返回内容'), findsNothing);
    expect(find.textContaining('主模型继续回复'), findsOneWidget);

    await tester.tap(find.text('子代理返回信息'));
    await tester.pumpAndSettle();

    expect(find.textContaining('子代理真实返回内容'), findsOneWidget);
    expect(find.textContaining('主模型继续回复'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('子代理提示词注入默认收起，展开后显示提示词正文', (tester) async {
    await _pump(
      tester,
      MessageBubble(
        message: ChatMessage(
          id: 'subagent-prompt',
          sessionId: 's1',
          role: 'assistant',
          content: '<子代理提示词注入>\n请检查消息气泡的布局。',
          createdAt: 0,
        ),
      ),
    );

    expect(find.text('子代理提示词注入'), findsOneWidget);
    expect(find.textContaining('<子代理提示词注入>'), findsNothing);
    expect(find.textContaining('请检查消息气泡'), findsNothing);

    await tester.tap(find.text('子代理提示词注入'));
    await tester.pumpAndSettle();

    expect(find.text('收起提示词'), findsOneWidget);
    expect(find.textContaining('请检查消息气泡'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('子代理总结默认收起，展开后显示总结正文', (tester) async {
    await _pump(
      tester,
      MessageBubble(
        message: ChatMessage(
          id: 'subagent-summary',
          sessionId: 's1',
          role: 'assistant',
          content: '<子代理总结>\n两个子代理均已完成测试。',
          createdAt: 0,
        ),
      ),
    );

    expect(find.text('子代理总结'), findsOneWidget);
    expect(find.textContaining('<子代理总结>'), findsNothing);
    expect(find.textContaining('两个子代理均已完成'), findsNothing);

    await tester.tap(find.text('子代理总结'));
    await tester.pumpAndSettle();

    expect(find.text('收起总结'), findsOneWidget);
    expect(find.textContaining('两个子代理均已完成'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('独立子代理总结不折叠主模型正文', (tester) async {
    await _pump(
      tester,
      MessageBubble(
        message: ChatMessage(
          id: 'subagent-summary-field',
          sessionId: 's1',
          role: 'assistant',
          content: '展示给用户的主模型正文',
          subagentSummary: '模型内部总结',
          createdAt: 0,
        ),
      ),
    );

    expect(find.text('子代理总结'), findsOneWidget);
    expect(find.textContaining('模型内部总结'), findsNothing);
    expect(find.textContaining('展示给用户的主模型正文'), findsOneWidget);

    await tester.tap(find.text('子代理总结'));
    await tester.pumpAndSettle();

    expect(find.textContaining('模型内部总结'), findsOneWidget);
    expect(find.textContaining('展示给用户的主模型正文'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空的流式思考回退消息字段，且不被子代理总结隐藏', (tester) async {
    await _pump(
      tester,
      MessageBubble(
        message: ChatMessage(
          id: 'reasoning-with-summary',
          sessionId: 's1',
          role: 'assistant',
          content: '主模型正文',
          reasoning: '完整思考过程',
          subagentSummary: '子代理完成摘要',
          createdAt: 0,
        ),
        liveReasoning: '',
      ),
    );

    expect(find.text('思考过程'), findsOneWidget);
    expect(find.text('子代理总结'), findsOneWidget);
    expect(find.textContaining('完整思考过程'), findsNothing);

    await tester.tap(find.text('思考过程'));
    await tester.pumpAndSettle();

    expect(find.text('收起思考'), findsOneWidget);
    expect(find.textContaining('完整思考过程'), findsOneWidget);
    expect(find.textContaining('主模型正文'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有回调的工具栏按钮不显示，避免只摆不能用', (tester) async {
    await _pump(tester, MessageBubble(message: _assistantMessage()));

    expect(find.byTooltip('复制'), findsNothing);
    expect(find.byTooltip('朗读'), findsNothing);
    expect(find.byTooltip('重新生成'), findsNothing);
    expect(find.byTooltip('保存记忆'), findsNothing);
    expect(find.byTooltip('保存技能'), findsNothing);
    expect(find.byTooltip('删除'), findsNothing);
    expect(find.byKey(const ValueKey('messageActionBar')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('流式正文和思考已有内容时仍持续显示思考状态', (tester) async {
    await _pump(
      tester,
      MessageBubble(
        message: ChatMessage(
          id: 'live',
          sessionId: 's1',
          role: 'assistant',
          content: '',
          streaming: true,
          createdAt: 0,
        ),
        liveContent: '已经输出一部分正文',
        liveReasoning: '已经产生一部分思考',
      ),
    );

    expect(find.text('思考中'), findsOneWidget);
    expect(find.text('思考过程'), findsNothing);
    expect(find.textContaining('已经输出一部分正文'), findsOneWidget);
    // 流式正文由带稳定 Key 的 FadeTransition 渐显，不按正文内容重建。
    expect(find.byKey(const ValueKey('streamingFadeMarkdown')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('思考中'), findsOneWidget);
    await tester.tap(find.text('思考中'));
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.text('收起思考'), findsOneWidget);
    expect(find.textContaining('已经产生一部分思考'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('工具运行期间思考中面板仍保留真实思考内容', (tester) async {
    await _pump(
      tester,
      MessageBubble(
        message: ChatMessage(
          id: 'live-tool',
          sessionId: 's1',
          role: 'assistant',
          content: '',
          reasoning: '工具调用前的思考',
          streaming: true,
          createdAt: 0,
          toolCalls: [ToolCall(id: 'call-1', name: 'read', arguments: '{}')],
        ),
        liveReasoning: '工具调用前的思考',
      ),
    );

    expect(find.text('思考中'), findsOneWidget);
    expect(find.text('思考过程'), findsNothing);
    expect(find.textContaining('工具调用前的思考'), findsNothing);

    await tester.tap(find.text('思考中'));
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.textContaining('工具调用前的思考'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('流式更新后思考过程和注入上下文保持展开', (tester) async {
    const bubbleKey = ValueKey('stable-live-bubble');
    ChatMessage liveMessage() => ChatMessage(
      id: 'stable-live',
      sessionId: 's1',
      role: 'assistant',
      content: '',
      runtimeContext: 'Current DSH file policy: workspace-write.',
      streaming: true,
      createdAt: 0,
    );

    await _pump(
      tester,
      MessageBubble(
        key: bubbleKey,
        message: liveMessage(),
        liveContent: '第一批正文',
        liveReasoning: '第一段思考',
      ),
    );

    await tester.tap(find.text('思考中'));
    await tester.tap(find.text('注入上下文'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('收起思考'), findsOneWidget);
    expect(find.text('收起上下文'), findsOneWidget);
    expect(find.textContaining('第一段思考'), findsOneWidget);
    expect(find.textContaining('Current DSH file policy'), findsOneWidget);

    await _pump(
      tester,
      MessageBubble(
        key: bubbleKey,
        message: liveMessage(),
        liveContent: '第一批正文，第二批继续输出',
        liveReasoning: '第一段思考，第二段继续分析',
      ),
    );
    await tester.pump(const Duration(milliseconds: 220));

    expect(find.text('收起思考'), findsOneWidget);
    expect(find.text('收起上下文'), findsOneWidget);
    expect(find.textContaining('第二段继续分析'), findsOneWidget);
    expect(find.textContaining('Current DSH file policy'), findsOneWidget);
    expect(find.textContaining('第二批继续输出'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('用户气泡文字浅色模式用深色、深色模式用白色（动态颜色）', (tester) async {
    tester.view.physicalSize = const Size(390, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // 浅色模式：用户气泡文字应为深色。
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true, brightness: Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: MessageBubble(
              key: const ValueKey('light-bubble'),
              message: _userMessage(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final lightText = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('light-bubble')),
        matching: find.text('你好'),
      ),
    );
    expect(lightText.style?.color, isNot(Colors.white));
    expect(lightText.style?.color?.computeLuminance(), lessThan(0.5));
    expect(tester.takeException(), isNull);

    // 深色模式：用户气泡文字应为白色。
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
        home: Scaffold(
          body: SingleChildScrollView(
            child: MessageBubble(
              key: const ValueKey('dark-bubble'),
              message: _userMessage(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final darkText = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('dark-bubble')),
        matching: find.text('你好'),
      ),
    );
    expect(darkText.style?.color, Colors.white);
    expect(darkText.style?.color?.computeLuminance(), greaterThan(0.5));
    expect(tester.takeException(), isNull);
  });
}
