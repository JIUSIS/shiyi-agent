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
}
