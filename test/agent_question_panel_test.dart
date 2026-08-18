import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/widgets/agent_question_panel.dart';

Widget _app(Widget child, {MediaQueryData? mediaQuery}) {
  return MaterialApp(
    home: MediaQuery(
      data: mediaQuery ?? const MediaQueryData(size: Size(400, 800)),
      child: Scaffold(
        body: Align(alignment: Alignment.bottomCenter, child: child),
      ),
    ),
  );
}

void main() {
  testWidgets('拾忆单选点击后立即提交', (tester) async {
    List<Map<String, dynamic>>? submitted;
    await tester.pumpWidget(
      _app(
        AgentQuestionPanel(
          title: '拾忆 向你提问',
          questions: const [
            {
              'id': 'shiyi-question',
              'question': '要继续吗？',
              'options': ['继续', '停止'],
            },
          ],
          instantSingleChoice: true,
          onSubmit: (answers) => submitted = answers,
          onCancel: () {},
        ),
      ),
    );

    await tester.tap(find.widgetWithText(FilledButton, '继续'));

    expect(submitted, [
      {
        'id': 'shiyi-question',
        'selected': ['继续'],
      },
    ]);
  });

  testWidgets('DSH 多选与自定义回答按原协议统一提交', (tester) async {
    List<Map<String, dynamic>>? submitted;
    await tester.pumpWidget(
      _app(
        AgentQuestionPanel(
          title: 'DS Harness 向你提问',
          questions: const [
            {
              'id': 'features',
              'question': '选择要启用的功能',
              'multiSelect': true,
              'options': ['联网', '技能'],
            },
            {
              'id': 'detail',
              'question': '补充说明',
              'options': ['无需补充'],
            },
          ],
          showCustomAnswers: true,
          showSubmitActions: true,
          onSubmit: (answers) => submitted = answers,
          onCancel: () {},
        ),
      ),
    );

    await tester.tap(find.widgetWithText(FilledButton, '联网'));
    await tester.tap(find.widgetWithText(FilledButton, '技能'));
    await tester.enterText(find.byType(TextField).at(1), '保留现有会话');
    await tester.tap(find.widgetWithText(FilledButton, '提交'));

    expect(submitted, [
      {
        'id': 'features',
        'selected': ['联网', '技能'],
      },
      {'id': 'detail', 'selected': <String>[], 'custom': '保留现有会话'},
    ]);
  });

  testWidgets('键盘占用小屏空间时面板可滚动且操作区保持可用', (tester) async {
    var cancelled = false;
    var submitted = false;
    await tester.pumpWidget(
      _app(
        AgentQuestionPanel(
          title: 'DS Harness 向你提问',
          questions: const [
            {
              'id': 'long-question',
              'question': '这是一个用于验证小屏幕键盘布局的较长问题',
              'multiSelect': true,
              'options': ['选项一', '选项二', '选项三', '选项四'],
            },
          ],
          showCustomAnswers: true,
          showSubmitActions: true,
          onSubmit: (_) => submitted = true,
          onCancel: () => cancelled = true,
        ),
        mediaQuery: const MediaQueryData(
          size: Size(360, 360),
          viewInsets: EdgeInsets.only(bottom: 180),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '提交'), findsOneWidget);
    expect(find.byTooltip('取消提问'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '提交'));
    await tester.tap(find.byTooltip('取消提问'));

    expect(submitted, isTrue);
    expect(cancelled, isTrue);
    expect(tester.takeException(), isNull);
  });
}
