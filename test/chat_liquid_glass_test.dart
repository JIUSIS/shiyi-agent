import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
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
  List<SessionModelOption> modelOptions = const [],
  String modelValue = '',
  String modelId = '',
  ValueChanged<SessionModelSelection>? onModelChanged,
  bool modelEnabled = true,
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
            modelOptions: modelOptions,
            modelValue: modelValue,
            modelId: modelId,
            onModelChanged: onModelChanged,
            modelEnabled: modelEnabled,
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

  testWidgets('会话模型抽屉只列出配置，点进去再选缓存模型 ID', (tester) async {
    final input = TextEditingController();
    addTearDown(input.dispose);
    SessionModelSelection? selected;

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
        modelOptions: const [
          SessionModelOption(
            value: 'DeepSeek',
            label: 'DeepSeek',
            subtitle: 'deepseek-chat',
            models: ['deepseek-chat', 'deepseek-reasoner'],
          ),
          SessionModelOption(
            value: '家里的网关',
            label: '家里的网关',
            subtitle: 'local-model',
            models: ['local-model', 'cached-id'],
          ),
        ],
        modelValue: 'DeepSeek',
        modelId: 'deepseek-chat',
        onModelChanged: (value) => selected = value,
      ),
    );

    expect(find.text('DeepSeek'), findsOneWidget);
    final trigger = tester.getRect(find.byTooltip('选择模型'));
    await tester.tap(find.byTooltip('选择模型'));
    await tester.pumpAndSettle();

    expect(find.text('家里的网关'), findsOneWidget);
    expect(find.text('cached-id'), findsNothing);

    final menu = tester.getRect(find.text('家里的网关'));
    expect(menu.bottom, lessThanOrEqualTo(trigger.top + 8));
    expect(menu.left, closeTo(trigger.left, 24));
    expect(menu.width, lessThanOrEqualTo(280));

    final list = tester.widget<ListView>(find.byType(ListView).last);
    final listBox = tester.renderObject<RenderBox>(find.byType(ListView).last);
    expect(list.shrinkWrap, isTrue);
    expect(listBox.size.height, lessThanOrEqualTo(240));

    await tester.tap(find.text('家里的网关'));
    await tester.pumpAndSettle();
    expect(selected, isNull);
    expect(find.text('返回'), findsOneWidget);
    expect(find.text('cached-id'), findsOneWidget);
    expect(find.text('local-model'), findsOneWidget);

    await tester.tap(find.text('cached-id'));
    await tester.pumpAndSettle();
    expect(selected?.profile, '家里的网关');
    expect(selected?.model, 'cached-id');
  });

  testWidgets('禁用的会话模型选择器不会打开抽屉', (tester) async {
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
        modelOptions: const [
          SessionModelOption(value: 'DeepSeek', label: 'DeepSeek'),
          SessionModelOption(value: '家里的网关', label: '家里的网关'),
        ],
        modelValue: 'DeepSeek',
        onModelChanged: (_) => changes++,
        modelEnabled: false,
      ),
    );

    await tester.tap(find.byTooltip('选择模型'));
    await tester.pumpAndSettle();
    expect(find.text('家里的网关'), findsNothing);
    expect(changes, 0);
  });

  testWidgets('浮动输入叠层量高且根节点透明', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var measured = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatFloatingComposerScaffold(
            messages: (context, overlayHeight) {
              measured = overlayHeight;
              return const ColoredBox(
                color: Colors.red,
                child: SizedBox.expand(child: Text('消息')),
              );
            },
            overlay: const SizedBox(
              height: 96,
              width: double.infinity,
              child: Text('输入区'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(measured, closeTo(96, 0.5));
    expect(find.text('消息'), findsOneWidget);
    expect(find.text('输入区'), findsOneWidget);

    final overlayBox = tester.widget<ColoredBox>(
      find.descendant(
        of: find.byType(ChatFloatingComposerScaffold),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is ColoredBox && widget.color == Colors.transparent,
        ),
      ),
    );
    expect(overlayBox.color, Colors.transparent);
    expect(tester.takeException(), isNull);
  });

  testWidgets('玻璃提示条是胶囊而不是满宽实心底', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ChatGlassNoticeBar(text: '上下文已压缩')),
      ),
    );

    expect(find.text('上下文已压缩'), findsOneWidget);
    expect(find.byType(LiquidGlassLens), findsOneWidget);
    final bar = tester.getRect(find.text('上下文已压缩'));
    expect(bar.width, lessThan(tester.view.physicalSize.width));
    expect(tester.takeException(), isNull);
  });
}
