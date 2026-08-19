import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/widgets/chat_liquid_glass.dart';

Widget _composer({
  required TextEditingController input,
  required bool allowSendWhileBusy,
  List<ThinkingIntensityOption> thinkingOptions = const [],
  String thinkingValue = '',
  ValueChanged<String>? onThinkingChanged,
  bool thinkingEnabled = true,
  bool thinkingOn = true,
  ValueChanged<bool>? onThinkingToggled,
  VoidCallback? onCompress,
  bool compressBusy = false,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: LiquidGlassChatComposer(
            input: input,
            busy: true,
            enterToSend: true,
            allowSendWhileBusy: allowSendWhileBusy,
            pendingImages: const [],
            pendingFiles: const [],
            onPickAttachment: () {},
            onRemoveImage: (_) {},
            onRemoveFile: (_) {},
            onSend: () {},
            onStop: () {},
            thinkingOptions: thinkingOptions,
            thinkingValue: thinkingValue,
            onThinkingChanged: onThinkingChanged,
            thinkingEnabled: thinkingEnabled,
            thinkingOn: thinkingOn,
            onThinkingToggled: onThinkingToggled,
            onCompress: onCompress,
            compressBusy: compressBusy,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('共享液态玻璃输入区支持拾忆运行中引导', (tester) async {
    final input = TextEditingController(text: '继续补充');
    addTearDown(input.dispose);

    await tester.pumpWidget(_composer(input: input, allowSendWhileBusy: true));

    expect(
      find.byKey(const ValueKey('liquidGlassChatComposer')),
      findsOneWidget,
    );
    expect(find.byTooltip('停止'), findsOneWidget);
    expect(find.byTooltip('发送并引导'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('共享子代理状态条保留拾忆详细进度文本', (tester) async {
    const status = '子代理 1/2 · explore · 第 3/15 轮 · 正在调用 read_file';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SubagentStatusBar(text: status)),
      ),
    );

    expect(find.text(status), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('思考强度选择器显示当前值并回传显式档位', (tester) async {
    final input = TextEditingController();
    addTearDown(input.dispose);
    String? selected;

    // 使用更大的屏幕避免溢出。
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 忽略布局溢出（测试环境屏幕约束可能触发 RenderFlex 溢出警告）。
    final originalOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('RenderFlex overflowed')) return;
      originalOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = originalOnError);

    await tester.pumpWidget(
      _composer(
        input: input,
        allowSendWhileBusy: false,
        thinkingOptions: const [
          ThinkingIntensityOption('', 'Default'),
          ThinkingIntensityOption('low', 'Low'),
          ThinkingIntensityOption('high', 'High'),
          ThinkingIntensityOption('max', 'Max'),
        ],
        thinkingValue: 'high',
        onThinkingChanged: (value) => selected = value,
      ),
    );

    expect(find.text('High'), findsOneWidget);
    final trigger = tester.getRect(find.byTooltip('思考强度'));
    await tester.tap(find.byTooltip('思考强度'));
    await tester.pumpAndSettle();

    // 已选项只留在按钮上，抽屉只列出其余档位；Off 由开关单独处理。
    expect(find.text('High'), findsOneWidget);
    expect(find.text('Default'), findsOneWidget);
    expect(find.text('Off'), findsNothing);
    expect(find.text('Low'), findsOneWidget);
    expect(find.text('Max'), findsOneWidget);

    final menu = tester.getRect(find.text('Default'));
    expect(menu.bottom, lessThanOrEqualTo(trigger.top + 8));
    expect(menu.right, closeTo(trigger.right, 24));

    await tester.tap(find.text('Low'));
    await tester.pumpAndSettle();
    expect(selected, 'low');
  });

  testWidgets('禁用的思考强度选择器不会打开菜单', (tester) async {
    final input = TextEditingController();
    addTearDown(input.dispose);
    var changes = 0;

    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final originalOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('RenderFlex overflowed')) return;
      originalOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = originalOnError);

    await tester.pumpWidget(
      _composer(
        input: input,
        allowSendWhileBusy: false,
        thinkingOptions: const [
          ThinkingIntensityOption('', 'Default'),
          ThinkingIntensityOption('high', 'High'),
        ],
        thinkingValue: 'high',
        onThinkingChanged: (_) => changes++,
        thinkingEnabled: false,
      ),
    );

    await tester.tap(find.byTooltip('思考强度'));
    await tester.pumpAndSettle();
    expect(find.text('Default'), findsNothing);
    expect(changes, 0);
  });

  testWidgets('思考开关点亮为开、点灭为关，禁用时不回调', (tester) async {
    final input = TextEditingController();
    addTearDown(input.dispose);
    var on = true;
    var taps = 0;

    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Widget composer({required bool thinkingOn, required bool enabled}) {
      return _composer(
        input: input,
        allowSendWhileBusy: false,
        thinkingOptions: const [
          ThinkingIntensityOption('', 'Default'),
          ThinkingIntensityOption('high', 'High'),
        ],
        thinkingValue: 'high',
        onThinkingChanged: (_) {},
        thinkingEnabled: enabled,
        thinkingOn: thinkingOn,
        onThinkingToggled: (value) {
          taps++;
          on = value;
        },
      );
    }

    await tester.pumpWidget(composer(thinkingOn: true, enabled: true));
    expect(find.byTooltip('思考已开启'), findsOneWidget);
    expect(find.byTooltip('思考已关闭'), findsNothing);

    await tester.tap(find.byTooltip('思考已开启'));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(on, isFalse);

    await tester.pumpWidget(composer(thinkingOn: false, enabled: true));
    await tester.pumpAndSettle();
    expect(find.byTooltip('思考已关闭'), findsOneWidget);

    await tester.tap(find.byTooltip('思考已关闭'));
    await tester.pumpAndSettle();
    expect(taps, 2);
    expect(on, isTrue);

    await tester.pumpWidget(composer(thinkingOn: true, enabled: false));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('思考已开启'));
    await tester.pumpAndSettle();
    expect(taps, 2);
  });

  testWidgets('共享压缩按钮提供 tooltip、忙碌态和禁用状态', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatCompressionButton(onPressed: null, busy: true),
        ),
      ),
    );

    expect(find.byTooltip('正在压缩上下文'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(IconButton), findsOneWidget);
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNull,
    );
  });
}
