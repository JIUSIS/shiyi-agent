import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:shiyi_agent_app/services/runtime_logger.dart';

void main() {
  test('运行日志序列化包含请求关联字段', () {
    const entry = RuntimeLogEntry(
      timestamp: '2026-08-27T00:00:00Z',
      level: 'info',
      module: 'LLM',
      event: 'response.completed',
      sessionId: 'session-a',
      requestId: 'request-a',
      durationMs: 123,
      result: 'HTTP 200',
      data: {'protocol': 'responses', 'cachedTokens': 80},
    );
    final restored = RuntimeLogEntry.fromJson(entry.toJson());
    expect(restored.sessionId, 'session-a');
    expect(restored.requestId, 'request-a');
    expect(restored.durationMs, 123);
    expect(restored.data['cachedTokens'], 80);
  });

  test('运行日志按字段名和常见密钥格式脱敏', () {
    final value = RuntimeLogger.redactMapForTest({
      'apiKey': 'random-secret-value',
      'token': 'random-token-value',
      'message': 'Authorization: Bearer sk-test-secret-123456789',
    });
    expect(value['apiKey'], '<redacted>');
    expect(value['token'], '<redacted>');
    expect(value['message'], isNot(contains('sk-test-secret-123456789')));
  });

  test('uiRoute/uiStep 让后续日志带上页面与步骤上下文', () {
    final logger = RuntimeLogger.instance;
    logger.uiRoute('chat');
    logger.uiStep('stream');
    unawaited(logger.error('Ui', 'probe_error', data: {'x': 1}).catchError((_) {}));
    final entry =
        logger.recent(limit: 10).firstWhere((e) => e.event == 'probe_error');
    expect(entry.data['ui'], <String, dynamic>{
      'route': 'chat',
      'step': 'stream',
    });
    logger.uiRoute('');
    logger.uiStep('');
  });

  test('uiGuard 成功时记录 ui.operation 并返回结果', () async {
    final logger = RuntimeLogger.instance;
    final v = await logger.uiGuard<int>(
      route: 'chat',
      operation: 'sendMessage',
      body: () async => 42,
    );
    expect(v, 42);
    final op =
        logger.recent(limit: 20).firstWhere((e) => e.event == 'ui.operation');
    expect(op.level, 'info');
    expect(op.data['operation'], 'sendMessage');
    expect(op.data['route'], 'chat');
    expect(logger.recent(limit: 20).where((e) => e.event == 'ui.error'), isEmpty);
  });

  test('uiGuard 失败时记录出错步骤并重抛', () async {
    final logger = RuntimeLogger.instance;
    Object? thrown;
    try {
      await logger.uiGuard<int>(
        route: 'chat',
        operation: 'sendMessage',
        body: () async {
          logger.uiStep('stream');
          throw Exception('boom');
        },
      );
    } catch (e) {
      thrown = e;
    }
    expect(thrown, isNotNull);
    final err =
        logger.recent(limit: 30).firstWhere((e) => e.event == 'ui.error');
    expect(err.level, 'error');
    expect(err.data['operation'], 'sendMessage');
    expect(err.data['route'], 'chat');
    expect(err.data['step'], 'stream');
    final errVal = err.data['error'] as String?;
    expect(errVal, contains('boom'));
  });
}
