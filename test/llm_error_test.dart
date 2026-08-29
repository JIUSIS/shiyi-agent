import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/services/llm_error.dart';

void main() {
  test('400 保留 code/type/param，并标记为不可通用重试', () {
    final info = LlmErrorInfo.fromHttp(400, '''
{"error":{"message":"Unsupported parameter: reasoning_effort","type":"invalid_request_error","param":"reasoning_effort","code":"invalid_parameter"}}
''');

    expect(info.kind, LlmErrorKind.invalidRequest);
    expect(info.meaning, '请求参数错误');
    expect(info.providerCode, 'invalid_parameter');
    expect(info.providerType, 'invalid_request_error');
    expect(info.parameter, 'reasoning_effort');
    expect(info.retryable, isFalse);
    expect(info.userMessage, contains('HTTP 400：请求参数错误'));
    expect(info.userMessage, contains('参数 reasoning_effort'));
  });

  test('常见状态码给出稳定含义和重试边界', () {
    expect(LlmErrorInfo.fromHttp(401, '').kind, LlmErrorKind.authentication);
    expect(LlmErrorInfo.fromHttp(403, '').kind, LlmErrorKind.permission);
    expect(LlmErrorInfo.fromHttp(404, '').kind, LlmErrorKind.notFound);
    expect(LlmErrorInfo.fromHttp(413, '').kind, LlmErrorKind.tooLarge);
    expect(LlmErrorInfo.fromHttp(422, '').kind, LlmErrorKind.semanticInvalid);
    expect(LlmErrorInfo.fromHttp(429, '').retryable, isTrue);
    expect(LlmErrorInfo.fromHttp(502, '').retryable, isTrue);
    expect(LlmErrorInfo.fromHttp(400, '').retryable, isFalse);
  });

  test('非 JSON 错误也保留可读原文', () {
    final info = LlmErrorInfo.fromHttp(502, 'bad gateway');
    expect(info.meaning, '模型服务端异常');
    expect(info.providerMessage, 'bad gateway');
    expect(info.userMessage, contains('bad gateway'));
  });
}
