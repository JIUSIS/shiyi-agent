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

  test('splitMarkdownBlocks 单个代码块不产生空代码块', () {
    const md = '''试试这个：

```text
清理结果汇总
────────────────
删除 26 个安装包，释放约 2.5G
删除 yq_v1_9.APK，释放 146M
15 个视频已移入 Download/视频/
根目录现在只剩 8 个文件
```
''';
    final blocks = splitMarkdownBlocks(md);
    final codeBlocks = blocks.where((b) => b.trim().startsWith('```')).toList();
    expect(codeBlocks.length, 1);
    expect(blocks.where((b) => b.trim().isEmpty), isEmpty);
  });

  test('splitMarkdownBlocks 空代码块不渲染', () {
    const md = '```text\n```\n后文';
    final blocks = splitMarkdownBlocks(md);
    expect(blocks.where((b) => b.trim().startsWith('```')), isEmpty);
  });

  test('splitMarkdownBlocks 连续两个非空代码块', () {
    const md = '```dart\nvoid main() {}\n```\n\n```python\nprint(1)\n```';
    final blocks = splitMarkdownBlocks(md);
    expect(blocks.where((b) => b.trim().startsWith('```')).length, 2);
  });

  test('splitMarkdownBlocks 只有起始围栏不创建空代码块', () {
    const md = '```text\n';
    final blocks = splitMarkdownBlocks(md);
    expect(blocks.where((b) => b.trim().startsWith('```')), isEmpty);
  });

  test('splitMarkdownBlocks 未闭合但有内容的围栏保留部分代码块', () {
    const md = '```python\nprint(1)\n';
    final blocks = splitMarkdownBlocks(md);
    expect(blocks.where((b) => b.trim().startsWith('```')).length, 1);
  });

  testWidgets('代码块渲染：单个代码块只有一个复制按钮', (tester) async {
    const md = '''试试这个：

```text
清理结果汇总
```
''';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AdaptiveMarkdownText(md)),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
  });

  testWidgets('空代码块不渲染复制按钮', (tester) async {
    const md = '前文\n\n```text\n```\n\n后文';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AdaptiveMarkdownText(md)),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.copy_rounded), findsNothing);
  });

  testWidgets('流式中超长内容固定 Column 渲染，不切换 ListView', (tester) async {
    // 流式（isStreaming=true）跨过 lazyThreshold 也不切换渲染树，防中途重排跳动。
    final big = List.generate(20, (i) => '- 第 $i 项').join('\n');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AdaptiveMarkdownText(big, lazyThreshold: 10, isStreaming: true),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(ListView), findsNothing);
    expect(find.byType(MarkdownText), findsOneWidget);
  });

  test('分片流式：半截代码块不报错、不产生空代码框', () {
    // 模拟流式增量：围栏开了还没闭合。
    final md1 = '第一段\n\n```python\n';
    final blocks1 = splitMarkdownBlocks(md1);
    expect(blocks1.where((b) => b.trim().startsWith('```')), isEmpty);
    // 内容到达后渲染一次。
    final md2 = '第一段\n\n```python\nprint(1)\n';
    final blocks2 = splitMarkdownBlocks(md2);
    expect(blocks2.where((b) => b.trim().startsWith('```')).length, 1);
  });

  test('分片流式：半截表格不报错，完整后正确成表', () {
    final partial = '| 列A | 列B |\n|---|---|';
    final blocks1 = splitMarkdownBlocks(partial);
    expect(blocks1, isNotEmpty);
    final complete = '$partial\n| 1 | 2 |';
    final blocks2 = splitMarkdownBlocks(complete);
    expect(blocks2.any((b) => b.contains('| 1 | 2 |')), isTrue);
  });

  test('分片流式：半截链接不崩溃', () {
    final partial = '详情见 [官方文';
    final blocks1 = splitMarkdownBlocks(partial);
    expect(blocks1, isNotEmpty);
    final complete = '详情见 [官方文档](https://example.com)';
    final blocks2 = splitMarkdownBlocks(complete);
    expect(blocks2, isNotEmpty);
  });
}
