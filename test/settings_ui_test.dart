import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('外观分段控件在 MaterialApp 环境中保持 iOS 紧凑尺寸', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: CupertinoTheme(
          data: const CupertinoThemeData(brightness: Brightness.dark),
          child: CupertinoPageScaffold(
            navigationBar: CupertinoNavigationBar(
              middle: const Text('外观'),
            ),
            child: ListView(
              children: <Widget>[
                CupertinoListSection.insetGrouped(
                  children: const <Widget>[
                    CupertinoListTile(
                      title: Text('主题模式'),
                      subtitle: Text('浅色 / 深色 / 跟随系统'),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                  child: DefaultTextStyle(
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                    child: CupertinoSegmentedControl<String>(
                      groupValue: 'dark',
                      onValueChanged: _noop,
                      selectedColor: CupertinoColors.activeBlue,
                      unselectedColor: CupertinoColors.white,
                      borderColor: CupertinoColors.systemGrey4,
                      children: const <String, Widget>{
                        'light': Text('浅色'),
                        'dark': Text('深色'),
                        'system': Text('跟随系统'),
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final box = tester.renderObject<RenderBox>(
      find.byType(CupertinoSegmentedControl<String>),
    );
    expect(box.size.height, lessThan(60),
        reason: '分段控件高度不应被外层默认字号撑高');
    expect(box.size.width, greaterThan(300));
  });

  testWidgets('分段控件选中文字为浅色、未选中文字为主题色', (tester) async {
    await tester.pumpWidget(
      CupertinoApp(
        home: DefaultTextStyle(
          style: const TextStyle(fontSize: 13),
          child: CupertinoSegmentedControl<String>(
            groupValue: 'dark',
            onValueChanged: _noop,
            selectedColor: CupertinoColors.activeBlue,
            unselectedColor: CupertinoColors.white,
            borderColor: CupertinoColors.systemGrey4,
            children: const <String, Widget>{
              'light': Text('浅色'),
              'dark': Text('深色'),
              'system': Text('跟随系统'),
            },
          ),
        ),
      ),
    );
    await tester.pump();

    final textWidgets = tester
        .widgetList<Text>(find.byType(Text))
        .where((t) => const <String>['浅色', '深色', '跟随系统'].contains(t.data))
        .toList();
    expect(textWidgets, hasLength(3));

    Color? colorOf(String label) {
      for (final text in textWidgets) {
        if (text.data == label) {
          return DefaultTextStyle.of(
            tester.element(find.text(label)),
          ).style.color;
        }
      }
      return null;
    }

    expect(colorOf('深色'), CupertinoColors.white);
    expect(colorOf('浅色'), CupertinoColors.activeBlue);
    expect(colorOf('跟随系统'), CupertinoColors.activeBlue);
  });

  testWidgets('设置页文本不继承 Material fallback 黄色下划线', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: CupertinoTheme(
          data: const CupertinoThemeData(brightness: Brightness.dark),
          child: Material(
            type: MaterialType.transparency,
            child: CupertinoPageScaffold(
              navigationBar: CupertinoNavigationBar(
                middle: const Text('外观'),
              ),
              child: SafeArea(
                bottom: false,
                child: ListView(
                  children: const <Widget>[
                    Padding(
                      padding: EdgeInsets.all(8),
                      child: Text(
                        '设置',
                        style: TextStyle(
                          fontSize: 34,
                          fontWeight: FontWeight.w700,
                          color: CupertinoColors.label,
                        ),
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.only(top: 18),
                      child: Text(
                        '拾忆 v2.0.0 · Flutter 原生',
                        style: TextStyle(
                          fontSize: 13,
                          color: CupertinoColors.secondaryLabel,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final titleStyle = DefaultTextStyle.of(tester.element(find.text('设置'))).style;
    final versionStyle = DefaultTextStyle.of(
      tester.element(find.text('拾忆 v2.0.0 · Flutter 原生')),
    ).style;
    expect(titleStyle.decoration, isNot(TextDecoration.underline));
    expect(versionStyle.decoration, isNot(TextDecoration.underline));
    expect(titleStyle.fontSize, lessThan(48));
  });

  testWidgets('二级设置页内容从导航栏下方开始', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: CupertinoTheme(
          data: const CupertinoThemeData(brightness: Brightness.dark),
          child: Material(
            type: MaterialType.transparency,
            child: CupertinoPageScaffold(
              navigationBar: CupertinoNavigationBar(
                middle: const Text('对话与功能'),
              ),
              child: SafeArea(
                bottom: false,
                child: ListView(
                  children: <Widget>[
                    CupertinoListSection.insetGrouped(
                      children: const <Widget>[
                        CupertinoListTile(
                          title: Text('启用工具调用'),
                          subtitle: Text('测试副标题'),
                          trailing: CupertinoSwitch(value: true, onChanged: null),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final listOffset = tester
        .renderObject<RenderBox>(find.byType(ListView))
        .localToGlobal(Offset.zero);
    final navBox = tester.renderObject<RenderBox>(
      find.byType(CupertinoNavigationBar),
    );
    expect(listOffset.dy, greaterThanOrEqualTo(navBox.size.height));
  });
}

void _noop(String value) {}
