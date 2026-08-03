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
}
