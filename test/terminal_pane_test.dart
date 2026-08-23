import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/widgets/terminal_pane.dart';

void main() {
  group('终端画面拼行', () {
    test('日志末尾拼上当前输入，没有独立提示框文案', () {
      expect(formatTerminalView(log: 'ok\n', draft: 'ls'), 'ok\n\$ ls');
      expect(
        formatTerminalView(log: 'ok', draft: 'uname -a'),
        'ok\n\$ uname -a',
      );
    });

    test('光标画在草稿末尾，空格也能看见', () {
      expect(
        formatTerminalView(log: 'ok\n', draft: 'ls', cursorOn: true),
        'ok\n\$ ls█',
      );
      expect(
        formatTerminalView(log: 'ok\n', draft: 'abcd ', cursorOn: true),
        'ok\n\$ abcd █',
      );
      expect(
        formatTerminalView(log: 'ok\n', draft: 'ls', cursorOn: false),
        'ok\n\$ ls',
      );
    });

    test('输入和输出用不同颜色，历史命令行也算输入', () {
      const out = Color(0xFF111111);
      const inp = Color(0xFF222222);
      final spans = formatTerminalSpans(
        log: '\$ ls\nfile.txt\n',
        draft: 'pwd',
        cursorOn: true,
        outputColor: out,
        inputColor: inp,
      );
      expect(
        [for (final s in spans) (s.text, s.color)],
        [('\$ ls\n', inp), ('file.txt\n', out), ('\$ pwd█', inp)],
      );
      expect(terminalOutputColor, isNot(terminalInputColor));
    });

    test('按行识别错误和警告，命令行不算错误', () {
      expect(classifyTerminalLine(r'$ rm error.log'), TerminalLineKind.input);
      expect(classifyTerminalLine('file.txt'), TerminalLineKind.output);
      expect(classifyTerminalLine('[exit 0]'), TerminalLineKind.output);
      expect(
        classifyTerminalLine('error: no such file'),
        TerminalLineKind.error,
      );
      expect(classifyTerminalLine('ERROR: failed'), TerminalLineKind.error);
      expect(
        classifyTerminalLine('Traceback (most recent call last):'),
        TerminalLineKind.error,
      );
      expect(
        classifyTerminalLine('bash: foo: command not found'),
        TerminalLineKind.error,
      );
      expect(classifyTerminalLine('Permission denied'), TerminalLineKind.error);
      expect(classifyTerminalLine('[exit 1]'), TerminalLineKind.error);
      expect(classifyTerminalLine('启动失败：x'), TerminalLineKind.error);
      expect(
        classifyTerminalLine('warning: deprecated'),
        TerminalLineKind.warning,
      );
      expect(classifyTerminalLine('WARN unused'), TerminalLineKind.warning);
      expect(classifyTerminalLine('警告：磁盘将满'), TerminalLineKind.warning);
    });

    test('错误标红、警告标黄，正确输出和输入分色', () {
      const out = Color(0xFF111111);
      const inp = Color(0xFF222222);
      const err = Color(0xFF333333);
      const warn = Color(0xFF444444);
      final spans = formatTerminalSpans(
        log: '\$ ls\nfile.txt\nwarning: unused\nerror: boom\n[exit 1]\n',
        draft: 'pwd',
        outputColor: out,
        inputColor: inp,
        errorColor: err,
        warningColor: warn,
      );
      expect(
        [for (final s in spans) (s.text, s.color)],
        [
          ('\$ ls\n', inp),
          ('file.txt\n', out),
          ('warning: unused\n', warn),
          ('error: boom\n[exit 1]\n', err),
          ('\$ pwd', inp),
        ],
      );
      expect({
        terminalInputColor,
        terminalOutputColor,
        terminalErrorColor,
        terminalWarningColor,
      }, hasLength(4));
    });

    test('字母后空格再输入斜杠时补回被输入法吃掉的空格', () {
      expect(
        restoreEatenSpaceBeforeSlash(previous: 'abcd ', next: 'abcd/'),
        'abcd /',
      );
      expect(
        restoreEatenSpaceBeforeSlash(previous: 'abcd  ', next: 'abcd/'),
        'abcd  /',
      );
      expect(
        restoreEatenSpaceBeforeSlash(previous: 'abcd', next: 'abcd/'),
        'abcd/',
      );
      expect(restoreEatenSpaceBeforeSlash(previous: ' ', next: ' /'), ' /');
      expect(
        restoreEatenSpaceBeforeSlash(previous: 'abcd ', next: 'abcd /'),
        'abcd /',
      );
    });

    test('输入法组字未提交时不抢空格', () {
      const formatter = RestoreSpaceBeforeSlashFormatter();
      final composing = formatter.formatEditUpdate(
        const TextEditingValue(
          text: 'abcd ',
          selection: TextSelection.collapsed(offset: 5),
        ),
        const TextEditingValue(
          text: 'abcd/',
          selection: TextSelection.collapsed(offset: 5),
          composing: TextRange(start: 0, end: 5),
        ),
      );
      expect(composing.text, 'abcd/');

      final committed = formatter.formatEditUpdate(
        const TextEditingValue(
          text: 'abcd ',
          selection: TextSelection.collapsed(offset: 5),
        ),
        const TextEditingValue(
          text: 'abcd/',
          selection: TextSelection.collapsed(offset: 5),
        ),
      );
      expect(committed.text, 'abcd /');
      expect(committed.selection.baseOffset, 6);
    });

    test('输入法弹出时滚到最新：有内容才跳 maxScrollExtent', () {
      expect(shouldStickTerminalToLatest(hasClients: false), isFalse);
      expect(shouldStickTerminalToLatest(hasClients: true), isTrue);
    });

    test('已聚焦时不要先 unfocus 再 show，否则回车会闪键盘', () {
      expect(shouldRefocusTerminalKeyboard(hasFocus: true), isFalse);
      expect(shouldRefocusTerminalKeyboard(hasFocus: false), isTrue);
    });

    test('滑动看历史不弹输入法，只有轻点才弹', () {
      expect(shouldOpenKeyboardOnPointer(moved: false), isTrue);
      expect(shouldOpenKeyboardOnPointer(moved: true), isFalse);
    });
  });

  group('TerminalPane', () {
    testWidgets('没有底部输入框，点画面就能聚焦输入', (tester) async {
      final controller = TextEditingController();
      final focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalPane(
              log: '拾忆内嵌终端\n',
              controller: controller,
              focusNode: focus,
              scrollController: ScrollController(),
              ready: true,
              busy: false,
              onSubmit: () {},
              onInterrupt: () {},
            ),
          ),
        ),
      );

      expect(find.byType(CupertinoTextField), findsNothing);
      expect(find.textContaining('输入命令'), findsNothing);
      expect(find.textContaining('正在执行'), findsNothing);
      expect(find.textContaining('\$ '), findsOneWidget);

      await tester.tap(find.byKey(TerminalPane.paneKey));
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      expect(find.textContaining('█'), findsOneWidget);
      final display = tester.widget<Text>(
        find.descendant(
          of: find.byKey(TerminalPane.paneKey),
          matching: find.byType(Text),
        ),
      );
      final colors = <Color>{};
      display.textSpan?.visitChildren((span) {
        final color = span.style?.color;
        if (color != null) colors.add(color);
        return true;
      });
      expect(colors, containsAll([terminalOutputColor, terminalInputColor]));
    });

    testWidgets('字母后空格再输入斜杠会补回空格', (tester) async {
      final controller = TextEditingController(text: 'abcd ');
      final focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalPane(
              log: 'ok\n',
              controller: controller,
              focusNode: focus,
              scrollController: ScrollController(),
              ready: true,
              busy: false,
              onSubmit: () {},
              onInterrupt: () {},
            ),
          ),
        ),
      );

      await tester.showKeyboard(find.byKey(TerminalPane.imeKey));
      await tester.enterText(find.byKey(TerminalPane.imeKey), 'abcd/');
      await tester.pump();
      expect(controller.text, 'abcd /');
      expect(find.textContaining('abcd /'), findsWidgets);

      final field = tester.widget<TextField>(find.byKey(TerminalPane.imeKey));
      expect(field.keyboardType, TextInputType.visiblePassword);
      expect(
        field.inputFormatters,
        contains(isA<RestoreSpaceBeforeSlashFormatter>()),
      );
    });

    testWidgets('执行中输入仍可用', (tester) async {
      final controller = TextEditingController(text: 'next');
      final focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalPane(
              log: '\$ sleep 10\n',
              controller: controller,
              focusNode: focus,
              scrollController: ScrollController(),
              ready: true,
              busy: true,
              onSubmit: () {},
              onInterrupt: () {},
            ),
          ),
        ),
      );

      final field = tester.widget<TextField>(find.byKey(TerminalPane.imeKey));
      expect(field.enabled, isTrue);
      expect(field.readOnly, isFalse);
      expect(find.textContaining('\$ next'), findsOneWidget);
    });

    testWidgets('收起输入法后再点画面仍会请求弹出输入法', (tester) async {
      final controller = TextEditingController();
      final focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      final shows = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.textInput,
        (call) async {
          shows.add(call.method);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.textInput,
          null,
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalPane(
              log: 'ok\n',
              controller: controller,
              focusNode: focus,
              scrollController: ScrollController(),
              ready: true,
              busy: false,
              onSubmit: () {},
              onInterrupt: () {},
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(TerminalPane.paneKey));
      await tester.pump();
      await tester.pump(Duration.zero);
      expect(shows, contains('TextInput.show'));

      shows.clear();
      focus.unfocus();
      await tester.pump();
      await tester.tap(find.byKey(TerminalPane.paneKey));
      await tester.pump();
      await tester.pump(Duration.zero);
      expect(shows, contains('TextInput.show'));

      shows.clear();
      await tester.tap(find.byKey(TerminalPane.paneKey));
      await tester.pump();
      await tester.pump(Duration.zero);
      expect(shows, contains('TextInput.show'));
    });

    testWidgets('滑动历史不请求输入法', (tester) async {
      final controller = TextEditingController();
      final focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      final shows = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.textInput,
        (call) async {
          shows.add(call.method);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.textInput,
          null,
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 240,
              child: TerminalPane(
                log: List.generate(40, (i) => 'line $i').join('\n'),
                controller: controller,
                focusNode: focus,
                scrollController: ScrollController(),
                ready: true,
                busy: false,
                onSubmit: () {},
                onInterrupt: () {},
              ),
            ),
          ),
        ),
      );

      await tester.drag(find.byKey(TerminalPane.paneKey), const Offset(0, -80));
      await tester.pump();
      await tester.pump(Duration.zero);
      expect(shows, isNot(contains('TextInput.show')));
      expect(focus.hasFocus, isFalse);
    });
  });
}
