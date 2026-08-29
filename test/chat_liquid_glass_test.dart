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
  VoidCallback? onContextLimit,
  String contextLimitLabel = '',
  List<SessionModelOption> modelOptions = const [],
  String modelValue = '',
  String modelId = '',
  ValueChanged<SessionModelSelection>? onModelChanged,
  bool modelEnabled = true,
  VoidCallback? onModelOpening,
  List<PermissionPresetOption> permissionOptions = const [],
  String permissionValue = '',
  ValueChanged<String>? onPermissionChanged,
  bool permissionEnabled = true,
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
            onContextLimit: onContextLimit,
            contextLimitLabel: contextLimitLabel,
            modelOptions: modelOptions,
            modelValue: modelValue,
            modelId: modelId,
            onModelChanged: onModelChanged,
            modelEnabled: modelEnabled,
            onModelOpening: onModelOpening,
            permissionOptions: permissionOptions,
            permissionValue: permissionValue,
            onPermissionChanged: onPermissionChanged,
            permissionEnabled: permissionEnabled,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('AutoScrollLabel 短文本静止，超长文本进入跑马灯', (tester) async {
    const style = TextStyle(fontSize: 13);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: Column(
              children: [
                AutoScrollLabel(text: 'Full access', style: style, width: 76),
                AutoScrollLabel(
                  text: '一个特别特别特别特别特别长的权限预设名称',
                  style: style,
                  width: 76,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // 短文本直接渲染，宽文本被 ClipRect 裁在固定宽度里。
    expect(find.text('Full access'), findsOneWidget);
    expect(find.text('一个特别特别特别特别特别长的权限预设名称'), findsOneWidget);
    // 跑马灯推进若干帧不抛异常（repeat 动画在 pump 下推进）。
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
  });

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

  testWidgets('运行中工具栏按钮保持可见且思考开关不置灰', (tester) async {
    final input = TextEditingController();
    addTearDown(input.dispose);

    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _composer(
        input: input,
        allowSendWhileBusy: true,
        modelOptions: const [
          SessionModelOption(
            value: 'deepseek',
            label: 'DeepSeek',
            models: ['deepseek-chat'],
          ),
        ],
        modelValue: 'deepseek',
        modelId: 'deepseek-chat',
        onModelChanged: (_) {},
        thinkingOptions: const [ThinkingIntensityOption('high', '高')],
        thinkingValue: 'high',
        thinkingOn: true,
        onThinkingChanged: (_) {},
        onThinkingToggled: (_) {},
        onCompress: () {},
        onContextLimit: () {},
      ),
    );
    await tester.pump();

    expect(find.byTooltip('选择模型'), findsOneWidget);
    expect(find.byTooltip('思考已开启'), findsOneWidget);
    expect(find.byTooltip('压缩上下文'), findsOneWidget);
    expect(find.byTooltip('会话上下文'), findsOneWidget);
    final toggle = tester.widget<ThinkingToggleButton>(
      find.byType(ThinkingToggleButton),
    );
    expect(toggle.onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有模型回调时工具栏仍可安全渲染', (tester) async {
    final input = TextEditingController();
    addTearDown(input.dispose);

    await tester.pumpWidget(
      _composer(
        input: input,
        allowSendWhileBusy: false,
        onCompress: () {},
        modelOptions: const [
          SessionModelOption(value: 'unused', label: 'unused'),
        ],
        onModelChanged: null,
      ),
    );

    expect(find.byTooltip('压缩上下文'), findsOneWidget);
    expect(find.byTooltip('选择模型'), findsNothing);
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

    expect(find.text('deepseek-chat'), findsOneWidget);
    final trigger = tester.getRect(find.byTooltip('选择模型'));
    await tester.tap(find.byTooltip('选择模型'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(selected, isNull);
    expect(find.text('返回'), findsOneWidget);
    expect(find.text('cached-id'), findsOneWidget);
    expect(find.text('local-model'), findsOneWidget);

    await tester.tap(find.text('cached-id'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(selected?.profile, '家里的网关');
    expect(selected?.model, 'cached-id');
  });

  testWidgets('目标 DSH 模型项回传真实 provider 而不是 UI 唯一键', (tester) async {
    final input = TextEditingController();
    addTearDown(input.dispose);
    SessionModelSelection? selected;

    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _composer(
        input: input,
        allowSendWhileBusy: false,
        modelOptions: const [
          SessionModelOption(
            value: 'dsh:remote-provider',
            label: '当前 DSH · 远程接口',
            subtitle: 'remote-model',
            models: ['remote-model'],
            targetDsh: true,
            targetProvider: 'remote-provider',
          ),
        ],
        modelValue: 'dsh:remote-provider',
        modelId: 'remote-model',
        onModelChanged: (value) => selected = value,
      ),
    );

    await tester.tap(find.byTooltip('选择模型'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('当前 DSH · 远程接口'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('remote-model').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(selected?.profile, 'remote-provider');
    expect(selected?.model, 'remote-model');
    expect(selected?.targetDsh, isTrue);
  });

  testWidgets('拾忆 Relay 模型项保留中转标记并回传真实 provider', (tester) async {
    final input = TextEditingController();
    addTearDown(input.dispose);
    SessionModelSelection? selected;

    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _composer(
        input: input,
        allowSendWhileBusy: false,
        modelOptions: const [
          SessionModelOption(
            value: 'relay:profile-a',
            label: '拾忆中转 · 主配置',
            subtitle: 'model-a',
            models: ['model-a'],
            targetDsh: true,
            targetProvider: 'shiyi_relay_profile_a',
            shiyiRelay: true,
          ),
        ],
        modelValue: 'relay:profile-a',
        modelId: 'model-a',
        onModelChanged: (value) => selected = value,
      ),
    );

    await tester.tap(find.byTooltip('选择模型'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('拾忆中转 · 主配置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('model-a').last);
    await tester.pumpAndSettle();

    expect(selected?.profile, 'shiyi_relay_profile_a');
    expect(selected?.model, 'model-a');
    expect(selected?.targetDsh, isTrue);
    expect(selected?.shiyiRelay, isTrue);
  });

  testWidgets('模型抽屉打开时刷新配置，打开期间选项变化会自动重建', (tester) async {
    final input = TextEditingController();
    addTearDown(input.dispose);
    var opened = 0;
    var options = const [
      SessionModelOption(value: 'old', label: '旧配置', models: ['old-model']),
    ];
    late StateSetter rebuild;

    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return LiquidGlassChatComposer(
                input: input,
                busy: false,
                enterToSend: true,
                pendingImages: const [],
                pendingFiles: const [],
                onPickAttachment: () {},
                onRemoveImage: (_) {},
                onRemoveFile: (_) {},
                onSend: () {},
                onStop: () {},
                modelOptions: options,
                modelValue: 'old',
                modelId: 'old-model',
                onModelChanged: (_) {},
                onModelOpening: () => opened++,
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('选择模型'));
    // 抽屉内超长模型名会进入跑马灯动画，不能 pumpAndSettle。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(opened, 1);
    expect(find.text('旧配置'), findsOneWidget);

    rebuild(
      () => options = const [
        SessionModelOption(value: 'new', label: '新配置', models: ['new-model']),
      ],
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('旧配置'), findsNothing);
    expect(find.text('新配置'), findsOneWidget);
    expect(tester.takeException(), isNull);
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

  testWidgets('小屏浮动输入区带完整工具栏时仍完成布局', (tester) async {
    tester.view.physicalSize = const Size(400, 869);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final input = TextEditingController();
    addTearDown(input.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatFloatingComposerScaffold(
            messages: (_, _) => const SizedBox.expand(),
            overlay: LiquidGlassChatComposer(
              input: input,
              busy: false,
              enterToSend: true,
              pendingImages: const [],
              pendingFiles: const [],
              onPickAttachment: () {},
              onRemoveImage: (_) {},
              onRemoveFile: (_) {},
              onSend: () {},
              onStop: () {},
              modelOptions: const [
                SessionModelOption(
                  value: 'deepseek',
                  label: 'DeepSeek',
                  models: ['deepseek-chat'],
                ),
              ],
              modelValue: 'deepseek',
              modelId: 'deepseek-chat',
              onModelChanged: (_) {},
              thinkingOptions: const [ThinkingIntensityOption('high', '高')],
              thinkingValue: 'high',
              onThinkingChanged: (_) {},
              onThinkingToggled: (_) {},
              onCompress: () {},
              onContextLimit: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final box = tester.renderObject<RenderBox>(
      find.byKey(const ValueKey('liquidGlassChatComposer')),
    );
    expect(box.hasSize, isTrue);
    expect(box.size.height, greaterThan(0));
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

  testWidgets('返回键先收抽屉：思考强度 / 模型二级 / 权限都先收起而不是退页', (tester) async {
    final input = TextEditingController();
    addTearDown(input.dispose);

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

    final modelOptions = const [
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
    ];

    Future<void> pumpComposer() => tester.pumpWidget(
      _composer(
        input: input,
        allowSendWhileBusy: false,
        thinkingOptions: const [
          ThinkingIntensityOption('', 'Default'),
          ThinkingIntensityOption('high', 'High'),
        ],
        thinkingValue: 'high',
        onThinkingChanged: (_) {},
        modelOptions: modelOptions,
        modelValue: 'DeepSeek',
        modelId: 'deepseek-chat',
        onModelChanged: (_) {},
        permissionOptions: const [
          PermissionPresetOption(value: 'readonly', label: 'Read Only'),
          PermissionPresetOption(value: 'workspace-write', label: 'Workspace Write'),
          PermissionPresetOption(value: 'full', label: 'Full access'),
        ],
        permissionValue: 'readonly',
        onPermissionChanged: (_) {},
      ),
    );

    // Navigator.push 后首帧才构建路由，动画在构建帧仍是 0；先 pump 一帧
    // 再推进时长，抽屉才能以完整尺寸参与命中测试。
    Future<void> settle() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    // 思考强度抽屉：返回键只收起抽屉，页面还在。
    await pumpComposer();
    await tester.tap(find.byTooltip('思考强度'));
    await settle();
    expect(find.text('Default'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await settle();
    expect(find.text('Default'), findsNothing);
    expect(find.byTooltip('思考强度'), findsOneWidget);

    // 模型抽屉二级菜单：返回键先回一级，再按一次收抽屉。
    await tester.tap(find.byTooltip('选择模型'));
    await settle();
    await tester.tap(find.text('家里的网关'));
    await settle();
    expect(find.text('cached-id'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await settle();
    expect(find.text('返回'), findsNothing);
    expect(find.text('家里的网关'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await settle();
    expect(find.text('家里的网关'), findsNothing);
    expect(find.byTooltip('选择模型'), findsOneWidget);

    // 权限抽屉：返回键收起，按钮还在。
    await tester.tap(find.byTooltip('权限预设 · Read Only'));
    await settle();
    expect(find.text('Workspace Write'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await settle();
    expect(find.text('Workspace Write'), findsNothing);
    expect(find.byTooltip('权限预设 · Read Only'), findsOneWidget);
  });
}
