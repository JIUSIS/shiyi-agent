import 'dart:convert';

/// LLM 请求错误的统一分类。
///
/// 不同供应商的错误 JSON 结构并不完全一致，但 HTTP 状态码和常见的
/// error.type / error.code 足够让界面给出稳定、可行动的说明。
enum LlmErrorKind {
  invalidRequest,
  semanticInvalid,
  authentication,
  permission,
  notFound,
  timeout,
  conflict,
  tooLarge,
  rateLimit,
  server,
  unknown,
}

class LlmErrorInfo {
  final int statusCode;
  final String providerCode;
  final String providerType;
  final String providerMessage;
  final String parameter;
  final LlmErrorKind kind;

  const LlmErrorInfo({
    required this.statusCode,
    required this.providerCode,
    required this.providerType,
    required this.providerMessage,
    required this.parameter,
    required this.kind,
  });

  factory LlmErrorInfo.fromHttp(int statusCode, String rawBody) {
    final json = _tryDecode(rawBody);
    final error = json is Map && json['error'] is Map
        ? json['error'] as Map
        : json is Map
        ? json
        : const <Object?, Object?>{};
    final message =
        _stringValue(error['message']) ??
        _stringValue(json is Map ? json['message'] : null) ??
        rawBody.trim();
    final code =
        _stringValue(error['code']) ??
        _stringValue(json is Map ? json['code'] : null) ??
        '';
    final type =
        _stringValue(error['type']) ??
        _stringValue(json is Map ? json['type'] : null) ??
        '';
    final parameter = _stringValue(error['param']) ?? '';

    return LlmErrorInfo(
      statusCode: statusCode,
      providerCode: code,
      providerType: type,
      providerMessage: message.isEmpty ? '服务端未返回错误说明' : message,
      parameter: parameter,
      kind: _kindFor(statusCode, code, type, message),
    );
  }

  bool get retryable =>
      kind == LlmErrorKind.timeout ||
      kind == LlmErrorKind.conflict ||
      kind == LlmErrorKind.rateLimit ||
      kind == LlmErrorKind.server;

  String get meaning {
    switch (kind) {
      case LlmErrorKind.invalidRequest:
        return '请求参数错误';
      case LlmErrorKind.semanticInvalid:
        return '请求语义不合法';
      case LlmErrorKind.authentication:
        return '身份验证失败';
      case LlmErrorKind.permission:
        return '没有调用权限';
      case LlmErrorKind.notFound:
        return '接口或模型不存在';
      case LlmErrorKind.timeout:
        return '请求超时';
      case LlmErrorKind.conflict:
        return '请求冲突';
      case LlmErrorKind.tooLarge:
        return '请求内容过大';
      case LlmErrorKind.rateLimit:
        return '请求过于频繁或额度不足';
      case LlmErrorKind.server:
        return '模型服务端异常';
      case LlmErrorKind.unknown:
        return '未知请求错误';
    }
  }

  String get userMessage {
    final code = providerCode.isNotEmpty
        ? '，服务码 $providerCode'
        : providerType.isNotEmpty
        ? '，类型 $providerType'
        : '';
    final param = parameter.isNotEmpty ? '，参数 $parameter' : '';
    return 'HTTP $statusCode：$meaning$code$param。${providerMessage.trim()}';
  }

  Map<String, dynamic> toLogData() => {
    'statusCode': statusCode,
    'kind': kind.name,
    'meaning': meaning,
    if (providerCode.isNotEmpty) 'providerCode': providerCode,
    if (providerType.isNotEmpty) 'providerType': providerType,
    if (parameter.isNotEmpty) 'parameter': parameter,
    'message': providerMessage,
  };

  static LlmErrorKind _kindFor(
    int statusCode,
    String code,
    String type,
    String message,
  ) {
    final text = '$code $type $message'.toLowerCase();
    if (statusCode == 400 ||
        text.contains('invalid_request') ||
        text.contains('invalid parameter') ||
        text.contains('bad request')) {
      return LlmErrorKind.invalidRequest;
    }
    if (statusCode == 401 ||
        text.contains('authentication') ||
        text.contains('invalid api key') ||
        text.contains('unauthorized')) {
      return LlmErrorKind.authentication;
    }
    if (statusCode == 403 ||
        text.contains('permission') ||
        text.contains('forbidden')) {
      return LlmErrorKind.permission;
    }
    if (statusCode == 404 ||
        text.contains('not found') ||
        text.contains('model_not_found')) {
      return LlmErrorKind.notFound;
    }
    if (statusCode == 408 || text.contains('timeout')) {
      return LlmErrorKind.timeout;
    }
    if (statusCode == 409 || text.contains('conflict')) {
      return LlmErrorKind.conflict;
    }
    if (statusCode == 413 ||
        text.contains('too large') ||
        text.contains('context length')) {
      return LlmErrorKind.tooLarge;
    }
    if (statusCode == 429 ||
        text.contains('rate limit') ||
        text.contains('quota')) {
      return LlmErrorKind.rateLimit;
    }
    if (statusCode == 422) return LlmErrorKind.semanticInvalid;
    if (statusCode >= 500 && statusCode <= 599) return LlmErrorKind.server;
    return LlmErrorKind.unknown;
  }

  static Object? _tryDecode(String raw) {
    try {
      return raw.trim().isEmpty ? null : jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  static String? _stringValue(Object? value) {
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }
}
