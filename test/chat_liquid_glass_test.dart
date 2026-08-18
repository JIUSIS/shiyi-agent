import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/widgets/chat_liquid_glass.dart';

Widget _composer({
  required TextEditingController input,
  required bool allowSendWhileBusy,
}) {
  return MaterialApp(
    home: Scaffold(
      body: LiquidGlassChatComposer(
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
}
