import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/screens/dsh_provider_editor_screen.dart';
import 'package:shiyi_agent_app/services/dsh_provider_config.dart';

void main() {
  testWidgets('新增页默认只展示易懂协议和常用字段', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: DshProviderEditorScreen()));

    expect(find.text('Chat'), findsOneWidget);
    expect(find.text('Responses'), findsOneWidget);
    expect(find.text('Claude'), findsOneWidget);
    expect(find.text('openai-completions'), findsNothing);
    expect(find.text('凭据引用'), findsNothing);
    expect(find.text('获取模型目录'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('测试连接'),
      260,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('测试连接'), findsOneWidget);
  });

  testWidgets('名称会自动生成高级 Provider ID 和凭据引用', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: DshProviderEditorScreen()));

    await tester.enterText(
      find.byKey(const Key('dsh-provider-name')),
      'My Gateway',
    );
    await tester.scrollUntilVisible(
      find.text('底层标识'),
      260,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(ListView), const Offset(0, -160));
    await tester.pumpAndSettle();
    await tester.tap(find.text('底层标识'));
    await tester.pump();

    final id = tester.widget<CupertinoTextField>(
      find.byKey(const Key('dsh-provider-id')),
    );
    final credential = tester.widget<CupertinoTextField>(
      find.byKey(const Key('dsh-provider-credential')),
    );
    expect(id.controller!.text, 'my_gateway');
    expect(credential.controller!.text, 'MY_GATEWAY_API_KEY');
  });

  testWidgets('编辑页还原协议、地址和模型', (tester) async {
    const config = DshProviderConfig(
      id: 'remote_api',
      displayName: '远端接口',
      protocol: 'responses',
      baseUrl: 'https://gateway.example/v1',
      credentialRef: 'REMOTE_API_KEY',
      models: ['gpt-test'],
    );
    await tester.pumpWidget(
      const MaterialApp(home: DshProviderEditorScreen(initial: config)),
    );

    expect(find.text('编辑 API'), findsOneWidget);
    expect(find.text('https://gateway.example/v1'), findsOneWidget);
    expect(find.text('gpt-test'), findsOneWidget);
    final segmented = tester.widget<CupertinoSlidingSegmentedControl<String>>(
      find.byKey(const Key('dsh-provider-protocol')),
    );
    expect(segmented.groupValue, 'responses');
  });

  testWidgets('小屏页面可以滚动且不会首屏溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MaterialApp(home: DshProviderEditorScreen()));
    await tester.pump();

    expect(find.byType(ListView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
