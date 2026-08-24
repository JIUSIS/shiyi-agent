import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/app_state.dart';
import 'package:shiyi_agent_app/core/models.dart';
import 'package:shiyi_agent_app/widgets/chat_liquid_glass.dart';

Session _session({
  required String id,
  int contextLimit = 0,
}) {
  return Session(
    id: id,
    title: id,
    model: 'mimo-v2.5-pro',
    createdAt: 1,
    updatedAt: 1,
    contextLimit: contextLimit,
  );
}

void main() {
  group('sanitizeLoadedContextLimit', () {
    test('用户设置的 100 万 token 不再被写回 128k', () {
      expect(sanitizeLoadedContextLimit(1000000), 1000000);
    });

    test('设置页允许的 50 万到 200 万保持原值', () {
      expect(sanitizeLoadedContextLimit(500000), 500000);
      expect(sanitizeLoadedContextLimit(2000000), 2000000);
      expect(sanitizeLoadedContextLimit(256000), 256000);
    });

    test('非法值回退默认 128k', () {
      expect(sanitizeLoadedContextLimit(0), 128000);
      expect(sanitizeLoadedContextLimit(-1), 128000);
    });
  });

  group('effectiveContextLimit', () {
    test('会话未自定义时跟随全局新建会话默认', () {
      expect(
        effectiveContextLimit(sessionContextLimit: 0, globalDefault: 1000000),
        1000000,
      );
    });

    test('会话自定义覆盖全局默认', () {
      expect(
        effectiveContextLimit(
          sessionContextLimit: 256000,
          globalDefault: 1000000,
        ),
        256000,
      );
    });

    test('全局缺失时回退 128k', () {
      expect(
        effectiveContextLimit(sessionContextLimit: 0, globalDefault: 0),
        128000,
      );
    });
  });

  group('Session.contextLimit', () {
    test('缺列或 0 表示跟随全局默认', () {
      final missing = Session.fromMap(const {
        'id': 's1',
        'title': 't',
        'model': 'm',
        'created_at': 1,
        'updated_at': 1,
      });
      expect(missing.contextLimit, 0);

      final zero = Session.fromMap(const {
        'id': 's1',
        'title': 't',
        'model': 'm',
        'created_at': 1,
        'updated_at': 1,
        'context_limit': 0,
      });
      expect(zero.contextLimit, 0);
    });

    test('自定义上下文可落库往返', () {
      final original = _session(id: 's2', contextLimit: 1000000);
      final restored = Session.fromMap(original.toMap());
      expect(restored.contextLimit, 1000000);
      expect(original.toMap()['context_limit'], 1000000);
    });
  });

  group('clientSettingsForSession', () {
    test('新建会话语义：未自定义的会话用全局默认，自定义互不串线', () {
      final state = ShiyiState()
        ..settings = AppSettings(contextLimit: 128000)
        ..sessions = [
          _session(id: 'new-default', contextLimit: 1000000),
          _session(id: 'custom', contextLimit: 256000),
          _session(id: 'legacy', contextLimit: 0),
        ];

      expect(
        state.clientSettingsForSession('new-default').contextLimit,
        1000000,
      );
      expect(state.clientSettingsForSession('custom').contextLimit, 256000);
      expect(state.clientSettingsForSession('legacy').contextLimit, 128000);
      expect(state.clientSettingsForSession(null).contextLimit, 128000);
    });
  });

  testWidgets('拾忆与 DSH 共用输入区可改本会话上下文', (tester) async {
    final input = TextEditingController();
    addTearDown(input.dispose);
    var taps = 0;

    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: LiquidGlassChatComposer(
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
                onCompress: () {},
                onContextLimit: () => taps++,
                contextLimitLabel: '1M',
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byTooltip('会话上下文'), findsOneWidget);
    expect(find.text('1M'), findsOneWidget);
    await tester.tap(find.byTooltip('会话上下文'));
    expect(taps, 1);
  });
}
