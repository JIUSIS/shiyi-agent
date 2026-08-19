import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyi_agent_app/core/models.dart';
import 'package:shiyi_agent_app/screens/dsh_models_screen.dart';
import 'package:shiyi_agent_app/services/dsh_model_sync.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('模型数据页只列出已注入配置，不能勾选模型 ID', (tester) async {
    await DshModelSync.rememberInjectedConfig(
      AppSettings(
        baseUrl: 'https://api.deepseek.com/v1',
        model: 'deepseek-chat',
      ),
      name: 'DeepSeek',
    );
    await DshModelSync.rememberInjectedConfig(
      AppSettings(baseUrl: 'https://gateway.example/v1', model: 'local-model'),
      name: '家里的网关',
    );

    await tester.pumpWidget(const MaterialApp(home: DshModelsScreen()));
    await tester.pumpAndSettle();

    expect(find.text('已注入 API 配置'), findsOneWidget);
    expect(find.text('DeepSeek'), findsOneWidget);
    expect(find.text('家里的网关'), findsOneWidget);
    expect(find.textContaining('deepseek-chat'), findsOneWidget);
    expect(find.textContaining('local-model'), findsOneWidget);
    expect(find.text('当前模型'), findsNothing);
    expect(find.byIcon(CupertinoIcons.checkmark_circle_fill), findsNothing);
    expect(
      tester
          .widget<CupertinoListTile>(find.byType(CupertinoListTile).first)
          .onTap,
      isNull,
    );
  });
}
