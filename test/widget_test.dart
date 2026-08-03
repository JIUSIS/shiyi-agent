import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/widgets/markdown_text.dart';

void main() {
  testWidgets('MarkdownText renders bold text', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: MarkdownText('**加粗** 文本')),
    ));
    expect(find.textContaining('加粗'), findsOneWidget);
  });

  testWidgets('MarkdownText keeps paragraphs mixed with lists', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: MarkdownText('开头段落\n- 列表项一\n- 列表项二\n结尾段落'),
      ),
    ));
    expect(find.textContaining('开头段落'), findsOneWidget);
    expect(find.textContaining('列表项一'), findsOneWidget);
    expect(find.textContaining('列表项二'), findsOneWidget);
    expect(find.textContaining('结尾段落'), findsOneWidget);
  });

  testWidgets('MarkdownText renders ## heading not as literal text', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: MarkdownText('第一段。\n## 小标题\n第二段。'),
      ),
    ));
    // 标题内容被渲染（字体变大加粗），而不是整段变成标题样式
    expect(find.text('第一段。'), findsOneWidget);
    expect(find.text('小标题'), findsOneWidget);
    expect(find.text('第二段。'), findsOneWidget);
    // 原始 ## 不应出现在任何文本里
    expect(find.textContaining('##'), findsNothing);
  });
}