import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/widgets/markdown_text.dart';

void main() {
  testWidgets('AdaptiveMarkdownText 短内容直接渲染', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AdaptiveMarkdownText('**粗体** 和 `代码`')),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(MarkdownText), findsOneWidget);
  });

  testWidgets('AdaptiveMarkdownText 超长内容切懒加载列表', (tester) async {
    final big = List.generate(3000, (i) => '- 第 $i 项 **加粗** `code`')
        .join('\n');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AdaptiveMarkdownText(big, lazyThreshold: 100)),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(ListView), findsWidgets);
  });

  testWidgets('表格渲染：表头与数据行都可见', (tester) async {
    const md = '| 国家 | 首都 |\n|---|---|\n| 中国 | 北京 |\n| 日本 | 东京 |';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AdaptiveMarkdownText(md)),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('国家'), findsOneWidget);
    expect(find.text('中国'), findsOneWidget);
    expect(find.text('东京'), findsOneWidget);
  });

  testWidgets('链接渲染为可点击文本', (tester) async {
    const md = '详情见 [官方文档](https://example.com)';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AdaptiveMarkdownText(md)),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.textContaining('官方文档'), findsOneWidget);
  });

  testWidgets('引用块渲染', (tester) async {
    const md = '> 这是引用\n> 第二行引用';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AdaptiveMarkdownText(md)),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('这是引用'), findsOneWidget);
    expect(find.text('第二行引用'), findsOneWidget);
  });

  testWidgets('任务列表渲染勾选与未勾选', (tester) async {
    const md = '- [x] 已完成\n- [ ] 待办';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AdaptiveMarkdownText(md)),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('待办'), findsOneWidget);
    expect(find.byIcon(Icons.check_box_rounded), findsOneWidget);
    expect(find.byIcon(Icons.check_box_outline_blank_rounded), findsOneWidget);
  });

  testWidgets('删除线渲染', (tester) async {
    const md = '这是 ~~旧内容~~ 新内容';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AdaptiveMarkdownText(md)),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.textContaining('旧内容'), findsOneWidget);
  });

  testWidgets('嵌套列表缩进渲染不报错', (tester) async {
    const md = '- 一级\n  - 二级\n    - 三级';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AdaptiveMarkdownText(md)),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('一级'), findsOneWidget);
    expect(find.text('二级'), findsOneWidget);
    expect(find.text('三级'), findsOneWidget);
  });
}
