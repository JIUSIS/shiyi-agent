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
    final big = List.generate(3000, (i) => '- 第 $i 项 **加粗** `code`').join('\n');
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
      const MaterialApp(home: Scaffold(body: AdaptiveMarkdownText(md))),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('国家'), findsOneWidget);
    expect(find.text('中国'), findsOneWidget);
    expect(find.text('东京'), findsOneWidget);
  });

  test('短内容表不压缩，全部横排', () {
    final specs = markdownTableColumnSpecs(
      headers: ['水果', '产地', '价格'],
      body: [
        ['苹果', '山东', '5'],
        ['香蕉', '海南', '8'],
      ],
      baseFontSize: 16,
    );
    expect(specs.every((s) => s.vertical == false), isTrue);
    expect(specs.every((s) => s.kind != MarkdownTableColumnKind.body), isTrue);
    expect(specs.every((s) => s.textAlign == TextAlign.center), isTrue);
  });

  test('长内容表才压缩序号和状态，标题短语保持横排', () {
    final specs = markdownTableColumnSpecs(
      headers: ['序号', '标题', '状态', '内容'],
      body: [
        ['1', '需求分析', '进行中', '这是一段比较长的正文内容，需要足够宽度才能读，用来把内容列撑开。'],
        ['2', '系统架构设计', '完成', '继续一段说明文字，仍然明显长于标题。'],
      ],
      baseFontSize: 16,
    );
    expect(specs, hasLength(4));
    expect(specs[0].kind, MarkdownTableColumnKind.serial);
    expect(specs[1].kind, MarkdownTableColumnKind.title);
    expect(specs[2].kind, MarkdownTableColumnKind.compact);
    expect(specs[3].kind, MarkdownTableColumnKind.body);
    expect(specs[0].vertical, isTrue);
    expect(specs[1].vertical, isFalse);
    expect(specs[2].vertical, isTrue);
    expect(specs[3].vertical, isFalse);
    expect(specs.every((s) => s.textAlign == TextAlign.center), isTrue);
    expect(markdownTableStackChars('序号'), '序\n号');
  });

  testWidgets('短内容水果表保持正常横排，不被竖排挤到一边', (tester) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const md =
        '| 水果 | 产地 | 价格 |\n|---|---|---|\n'
        '| 苹果 | 山东 | 5 |\n'
        '| 香蕉 | 海南 | 8 |';
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AdaptiveMarkdownText(md))),
    );
    await tester.pumpAndSettle();
    expect(find.text('水果'), findsOneWidget);
    expect(find.text('苹果'), findsOneWidget);
    expect(find.text('水\n果'), findsNothing);
    final fruitW = tester.getSize(find.byKey(const ValueKey('md-col-0'))).width;
    final originW = tester.getSize(find.byKey(const ValueKey('md-col-1'))).width;
    final priceW = tester.getSize(find.byKey(const ValueKey('md-col-2'))).width;
    expect(fruitW, greaterThan(40));
    expect(originW, greaterThan(40));
    expect(priceW, greaterThan(30));
    expect(tester.takeException(), isNull);
  });

  testWidgets('长内容表压缩序号状态，标题需求分析保持横排', (tester) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const md =
        '| 序号 | 标题 | 状态 | 内容 |\n|---|---|---|---|\n'
        '| 1 | 需求分析 | 进行中 | 这是一段比较长的正文内容，需要足够宽度才能读，用来把内容列撑开。 |\n'
        '| 2 | 系统架构设计 | 完成 | 继续一段说明文字，仍然明显长于标题。 |';
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AdaptiveMarkdownText(md))),
    );
    await tester.pumpAndSettle();
    expect(find.text('序\n号'), findsOneWidget);
    expect(find.text('需求分析'), findsOneWidget);
    expect(find.text('系统架构设计'), findsOneWidget);
    expect(find.text('需\n求\n分\n析'), findsNothing);
    final serialW = tester.getSize(find.byKey(const ValueKey('md-col-0'))).width;
    final titleW = tester.getSize(find.byKey(const ValueKey('md-col-1'))).width;
    final statusW = tester.getSize(find.byKey(const ValueKey('md-col-2'))).width;
    final bodyW = tester.getSize(find.byKey(const ValueKey('md-col-3'))).width;
    expect(serialW, lessThan(40));
    expect(statusW, lessThan(40));
    expect(titleW, greaterThan(serialW));
    expect(bodyW, greaterThan(titleW));
    expect(tester.takeException(), isNull);
  });

  testWidgets('链接渲染为可点击文本', (tester) async {
    const md = '详情见 [官方文档](https://example.com)';
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AdaptiveMarkdownText(md))),
    );
    expect(tester.takeException(), isNull);
    expect(find.textContaining('官方文档'), findsOneWidget);
  });

  testWidgets('引用块渲染', (tester) async {
    const md = '> 这是引用\n> 第二行引用';
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AdaptiveMarkdownText(md))),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('这是引用'), findsOneWidget);
    expect(find.text('第二行引用'), findsOneWidget);
  });

  testWidgets('任务列表渲染勾选与未勾选', (tester) async {
    const md = '- [x] 已完成\n- [ ] 待办';
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AdaptiveMarkdownText(md))),
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
      const MaterialApp(home: Scaffold(body: AdaptiveMarkdownText(md))),
    );
    expect(tester.takeException(), isNull);
    expect(find.textContaining('旧内容'), findsOneWidget);
  });

  testWidgets('嵌套列表缩进渲染不报错', (tester) async {
    const md = '- 一级\n  - 二级\n    - 三级';
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AdaptiveMarkdownText(md))),
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

  test('代码块字号更小、行距字距更紧', () {
    final style = markdownCodeBlockStyle(baseFontSize: 16);
    expect(style.fontSize, lessThanOrEqualTo(12.5));
    expect(style.height, lessThanOrEqualTo(1.28));
    expect(style.letterSpacing, lessThanOrEqualTo(0));
  });

  test('代码块关键字、字符串、注释分色', () {
    final spans = markdownHighlightSpans(
      'def hello():\n    # note\n    return "ok"',
      language: 'python',
    );
    expect(spans.length, greaterThan(1));
    final colors = spans
        .map((s) => s.style?.color)
        .whereType<Color>()
        .toSet();
    expect(colors.length, greaterThanOrEqualTo(3));
    expect(spans.any((s) => s.text == 'def'), isTrue);
    expect(spans.any((s) => s.text == '# note'), isTrue);
    expect(spans.any((s) => s.text == '"ok"'), isTrue);
  });

  test('JSON 代码不高亮注释分组，也不抛错', () {
    const json = '{\n  "name": "拾忆",\n  "count": 3\n}';
    final spans = markdownHighlightSpans(json, language: 'json');
    expect(spans, isNotEmpty);
    expect(spans.map((s) => s.text).join(), json);
    expect(spans.any((s) => s.text?.contains('"name"') == true), isTrue);
    expect(
      spans.any((s) => s.text == '"拾忆"' && s.style?.color != null),
      isTrue,
    );
  });

  testWidgets('JSON 代码块渲染正文，不出现空白错误框', (tester) async {
    const md = '''代码块（JSON）：
```json
{
  "name": "拾忆",
  "count": 3
}
```
''';
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AdaptiveMarkdownText(md))),
    );
    expect(tester.takeException(), isNull);
    expect(find.textContaining('"name"'), findsOneWidget);
    expect(find.textContaining('拾忆'), findsOneWidget);
    expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
  });

  testWidgets('代码块渲染：单个代码块只有一个复制按钮', (tester) async {
    const md = '''试试这个：

```text
清理结果汇总
```
''';
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AdaptiveMarkdownText(md))),
    );
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
  });

  testWidgets('空代码块不渲染复制按钮', (tester) async {
    const md = '前文\n\n```text\n```\n\n后文';
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AdaptiveMarkdownText(md))),
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
    expect(find.byType(MarkdownText), findsNothing);
    expect(find.byType(Text), findsWidgets);
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

  test('独立分隔线从段落中拆出，三种写法都是规则块', () {
    const md = '上文\n\n---\n\n***\n\n___\n\n下文';
    final blocks = splitMarkdownBlocks(md);
    expect(blocks.any((b) => b.trim() == '---'), isTrue);
    expect(blocks.any((b) => b.trim() == '***'), isTrue);
    expect(blocks.any((b) => b.trim() == '___'), isTrue);
    expect(blocks.any((b) => b.contains('上文')), isTrue);
    expect(blocks.any((b) => b.contains('下文')), isTrue);
  });

  test('脚注标记解析：内联内容与百分号解码', () {
    expect(
      markdownFootnoteMatch('见这里[^1](第一脚注)。')?.id,
      '1',
    );
    expect(
      markdownFootnoteMatch('见这里[^1](第一脚注)。')?.content,
      '第一脚注',
    );
    expect(
      markdownFootnoteMatch(
        'x[^note](%E4%BD%A0%E5%A5%BD)。',
      )?.content,
      '你好',
    );
    expect(markdownFootnoteMatch('普通[链接](https://example.com)'), isNull);
  });

  test('标准脚注引用与文末定义能解析', () {
    const md = '''
这里有一个脚注引用[^1]，和另一个脚注[^note]。

[^1]: 这是第一个脚注的内容。
[^note]: 这是第二个脚注，标签用了自定义名称。
''';
    final notes = markdownCollectFootnotes(md);
    expect(notes['1'], '这是第一个脚注的内容。');
    expect(notes['note'], '这是第二个脚注，标签用了自定义名称。');
    expect(markdownFootnoteRefIds('见这里[^1]和[^note]。'), ['1', 'note']);
    expect(markdownIsFootnoteDefinition('[^1]: 这是第一个脚注的内容。'), isTrue);
  });

  test('定义列表行识别缩进冒号和全角冒号', () {
    expect(markdownIsDefListLine(':   术语 A 的定义解释'), isTrue);
    expect(markdownIsDefListLine('    : 术语 A 的定义解释'), isTrue);
    expect(markdownIsDefListLine('：  术语 B 的定义'), isTrue);
    expect(markdownIsDefListLine('- 这不是定义'), isFalse);
  });

  test('LaTeX 转可读文本：上下标、积分、根号、矩阵', () {
    expect(markdownLatexPlain(r'E = mc^2'), contains('E = mc'));
    expect(markdownLatexPlain(r'E = mc^2'), contains('2'));
    expect(
      markdownLatexPlain(r'\int_{-\infty}^{\infty} e^{-x^2} dx = \sqrt{\pi}'),
      contains('∫'),
    );
    expect(
      markdownLatexPlain(r'\int_{-\infty}^{\infty} e^{-x^2} dx = \sqrt{\pi}'),
      isNot(contains(r'\int')),
    );
    expect(
      markdownLatexPlain(
        '\\begin{bmatrix}\n1 & 2 & 3 \\\\\n4 & 5 & 6 \\\\\n7 & 8 & 9\n\\end{bmatrix}',
      ),
      contains('1'),
    );
    expect(
      markdownLatexPlain(
        '\\begin{bmatrix}\n1 & 2 & 3 \\\\\n4 & 5 & 6 \\\\\n7 & 8 & 9\n\\end{bmatrix}',
      ),
      isNot(contains(r'\begin')),
    );
  });

  testWidgets('图片语法渲染为图片组件并保留替代文字', (tester) async {
    const md = '![示例图片](https://example.com/demo.png)';
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AdaptiveMarkdownText(md))),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('示例图片'), findsOneWidget);
    expect(find.textContaining('![示例图片]'), findsNothing);
  });

  testWidgets('标准脚注渲染上标和文末注释，不露 [^1] 原文', (tester) async {
    const md = '''
这里有一个脚注引用[^1]，和另一个脚注[^note]。

[^1]: 这是第一个脚注的内容。
[^note]: 这是第二个脚注，标签用了自定义名称。
''';
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AdaptiveMarkdownText(md))),
    );
    expect(tester.takeException(), isNull);
    expect(find.textContaining('这是第一个脚注的内容。'), findsOneWidget);
    expect(find.textContaining('自定义名称'), findsOneWidget);
    expect(find.textContaining('[^1]'), findsNothing);
    expect(find.textContaining('[^note]'), findsNothing);
    expect(find.textContaining('[^1]:'), findsNothing);
  });

  testWidgets('定义列表缩进冒号也渲染，不露原始冒号行', (tester) async {
    const md = '术语 A\n    :   术语 A 的定义解释，可以很长很长，会自动换行缩进。\n\n术语 B\n：  术语 B 的定义，支持 **富文本** 格式。';
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AdaptiveMarkdownText(md))),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('术语 A'), findsOneWidget);
    expect(find.textContaining('术语 A 的定义解释'), findsOneWidget);
    expect(find.text('术语 B'), findsOneWidget);
    expect(find.textContaining('富文本'), findsOneWidget);
    expect(find.textContaining(':   '), findsNothing);
    expect(find.textContaining('：  '), findsNothing);
  });

  testWidgets('脚注渲染上标与注释内容，不把百分号原文露出来', (tester) async {
    const md =
        '这里有一个脚注引用[^1](%E8%BF%99%E6%98%AF%E7%AC%AC%E4%B8%80%E4%B8%AA%E8%84%9A%E6%B3%A8%E7%9A%84%E5%86%85%E5%AE%B9%E3%80%82)，'
        '和另一个脚注[^note](%E8%BF%99%E6%98%AF%E7%AC%AC%E4%BA%8C%E4%B8%AA%E8%84%9A%E6%B3%A8%EF%BC%8C%E6%A0%87%E7%AD%BE%E7%94%A8%E4%BA%86%E8%87%AA%E5%AE%9A%E4%B9%89%E5%90%8D%E7%A7%B0%E3%80%82)。';
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AdaptiveMarkdownText(md))),
    );
    expect(tester.takeException(), isNull);
    expect(find.textContaining('这是第一个脚注的内容。'), findsOneWidget);
    expect(find.textContaining('自定义名称'), findsOneWidget);
    expect(find.textContaining('%E8%BF%99'), findsNothing);
    expect(find.textContaining('[^1]'), findsNothing);
  });

  testWidgets('定义列表渲染术语与解释', (tester) async {
    const md = '术语 A\n:   术语 A 的定义解释\n\n术语 B\n:   术语 B 的定义，支持 **富文本** 格式。';
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AdaptiveMarkdownText(md))),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('术语 A'), findsOneWidget);
    expect(find.textContaining('术语 A 的定义解释'), findsOneWidget);
    expect(find.text('术语 B'), findsOneWidget);
    expect(find.textContaining('富文本'), findsOneWidget);
    expect(find.textContaining(':   '), findsNothing);
  });

  testWidgets('键盘按键渲染为按键外观', (tester) async {
    const md = '按 Ctrl + C 复制，按 <kbd>Ctrl</kbd> + <kbd>V</kbd> 粘贴。';
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AdaptiveMarkdownText(md))),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Ctrl'), findsWidgets);
    expect(find.text('C'), findsOneWidget);
    expect(find.text('V'), findsOneWidget);
    expect(find.textContaining('<kbd>'), findsNothing);
  });

  testWidgets('双等号高亮不再显示原始标记', (tester) async {
    const md = '==这是一段高亮文字==（部分渲染器支持）。';
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AdaptiveMarkdownText(md))),
    );
    expect(tester.takeException(), isNull);
    expect(find.textContaining('这是一段高亮文字'), findsOneWidget);
    expect(find.textContaining('==这是一段高亮文字=='), findsNothing);
  });

  testWidgets('GitHub Alert 提示/警告/注意块渲染标题，不露原始标记', (tester) async {
    const md = '''
> [!TIP]
> 这是一个提示块（GitHub 风格 Alert）。

> [!WARNING]
> 这是一个警告块。

> [!NOTE]
> 这是一个注意信息块。
''';
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AdaptiveMarkdownText(md))),
    );
    expect(tester.takeException(), isNull);
    expect(find.textContaining('这是一个提示块'), findsOneWidget);
    expect(find.textContaining('这是一个警告块。'), findsOneWidget);
    expect(find.textContaining('这是一个注意信息块。'), findsOneWidget);
    expect(find.textContaining('[!TIP]'), findsNothing);
    expect(find.textContaining('[!WARNING]'), findsNothing);
    expect(find.textContaining('[!NOTE]'), findsNothing);
  });

  testWidgets('行内与独立 LaTeX 公式渲染，不显示原始美元符号命令', (tester) async {
    const md = r'''
行内公式：$E = mc^2$

独立公式：

$$
\int_{-\infty}^{\infty} e^{-x^2} dx = \sqrt{\pi}
$$
''';
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AdaptiveMarkdownText(md))),
    );
    expect(tester.takeException(), isNull);
    expect(find.textContaining(r'$E = mc^2$'), findsNothing);
    expect(find.textContaining(r'\int'), findsNothing);
    expect(find.textContaining('E = mc'), findsWidgets);
    expect(find.textContaining('∫'), findsOneWidget);
    expect(find.textContaining('π'), findsOneWidget);
  });

  testWidgets('LaTeX 矩阵渲染单元格，不显示 begin 命令', (tester) async {
    const md = r'''
$$
\begin{bmatrix}
1 & 2 & 3 \\
4 & 5 & 6 \\
7 & 8 & 9
\end{bmatrix}
$$
''';
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AdaptiveMarkdownText(md))),
    );
    expect(tester.takeException(), isNull);
    expect(find.textContaining(r'\begin'), findsNothing);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
    expect(find.text('9'), findsOneWidget);
  });

  testWidgets('全要素示例不把新语法露成原文，也不打断旧元素', (tester) async {
    const md = r'''
# Markdown 全要素示例文档

> 这是一段引用文字，用来展示引用块的渲染效果。可以包含**加粗**、*斜体*和`行内代码`。

---

## 1. 文本样式

这是**加粗文本**，这是*斜体文本*，这是~~删除线文本~~，这是`行内代码`，这是[超链接](https://example.com)。

## 6. 图片

![示例图片](https://example.com/demo.png)

## 7. 脚注

这里有一个脚注引用[^1](%E7%AC%AC%E4%B8%80%E4%B8%AA%E8%84%9A%E6%B3%A8)，和另一个脚注[^note](%E8%87%AA%E5%AE%9A%E4%B9%89)。

## 8. 定义列表

术语 A
:   术语 A 的定义解释

## 9. 键盘按键

按 Ctrl + C 复制。

## 10. 高亮与提示

==这是一段高亮文字==

> [!TIP]
> 这是一个提示块。

## 11. 数学公式

行内公式：$E = mc^2$

$$
\int_{-\infty}^{\infty} e^{-x^2} dx = \sqrt{\pi}
$$
''';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: AdaptiveMarkdownText(md)),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('加粗文本'), findsOneWidget);
    expect(find.textContaining('示例图片'), findsOneWidget);
    expect(find.textContaining('第一个脚注'), findsOneWidget);
    expect(find.text('术语 A'), findsOneWidget);
    expect(find.text('Ctrl'), findsWidgets);
    expect(find.textContaining('这是一段高亮文字'), findsOneWidget);
    expect(find.textContaining('这是一个提示块。'), findsOneWidget);
    expect(find.textContaining('[!TIP]'), findsNothing);
    expect(find.textContaining(r'$E = mc^2$'), findsNothing);
    expect(find.textContaining(r'\int'), findsNothing);
    expect(find.byType(Divider), findsWidgets);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('已有强调与链接不被新语法打断', (tester) async {
    const md = '这是**加粗文本**，这是*斜体文本*，这是~~删除线文本~~，这是`行内代码`，这是[超链接](https://example.com)。';
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AdaptiveMarkdownText(md))),
    );
    expect(tester.takeException(), isNull);
    expect(find.textContaining('加粗文本'), findsOneWidget);
    expect(find.textContaining('斜体文本'), findsOneWidget);
    expect(find.textContaining('删除线文本'), findsOneWidget);
    expect(find.textContaining('行内代码'), findsOneWidget);
    expect(find.textContaining('超链接'), findsOneWidget);
  });
}
