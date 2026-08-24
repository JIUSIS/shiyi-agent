import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:shiyi_agent_app/services/llm_client.dart';

void main() {
  test('明显思考模型默认启用 high reasoning effort', () {
    expect(LlmClient.defaultReasoningEffort('deepseek-v4-flash'), 'high');
    expect(LlmClient.defaultReasoningEffort('vendor/qwq-32b'), 'high');
    expect(LlmClient.defaultReasoningEffort('o3-mini'), 'high');
    expect(LlmClient.defaultReasoningEffort('llama-3.3-70b-versatile'), isNull);
    expect(LlmClient.usesDeepSeekThinkingParam('deepseek-v4-flash'), isTrue);
    expect(LlmClient.usesDeepSeekThinkingParam('deepseek-reasoner'), isTrue);
    expect(LlmClient.usesDeepSeekThinkingParam('o3-mini'), isFalse);
  });

  test('opencode 类网关思考模型只发 reasoning_effort，不发 thinking', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    late Map<String, dynamic> requestBody;
    final handled = () async {
      final request = await server.first;
      requestBody =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        )
        ..write('data: {"choices":[{"delta":{"reasoning":"思考"}}]}\n\n')
        ..write(
          'data: {"choices":[{"delta":{"content":"答案"},'
          '"finish_reason":"stop"}]}\n\n',
        )
        ..write('data: [DONE]\n\n');
      await request.response.close();
    }();

    TurnResult? lastTurn;
    try {
      final client = LlmClient(
        baseUrl: 'http://${server.address.host}:${server.port}/v1',
        apiKey: 'test-key',
        model: 'deepseek-v4-flash',
        temperature: 0.2,
        maxTokens: 1024,
        tools: const [],
        onTurn: (turn) => lastTurn = turn,
      );
      await client.send([
        {'role': 'user', 'content': '测试'},
      ]);
      await handled;

      expect(requestBody.containsKey('thinking'), isFalse);
      expect(requestBody['reasoning_effort'], 'high');
      expect(requestBody['max_completion_tokens'], 1024);
      expect(requestBody.containsKey('max_tokens'), isFalse);
      // 思考模式与 DSH 引擎对齐：不带 temperature / tool_choice。
      expect(requestBody.containsKey('temperature'), isFalse);
      expect(requestBody.containsKey('tool_choice'), isFalse);
      expect(lastTurn?.reasoning, '思考');
      expect(lastTurn?.text, '答案');
    } finally {
      await server.close(force: true);
    }
  });

  test('DeepSeek 官方 API 网关思考模型发送 thinking + reasoning_effort', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    late Map<String, dynamic> requestBody;
    final handled = () async {
      final request = await server.first;
      requestBody =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        )
        ..write('data: {"choices":[{"delta":{"reasoning_content":"思考"}}]}\n\n')
        ..write(
          'data: {"choices":[{"delta":{"content":"答案"},'
          '"finish_reason":"stop"}]}\n\n',
        )
        ..write('data: [DONE]\n\n');
      await request.response.close();
    }();

    TurnResult? lastTurn;
    try {
      final client = LlmClient(
        // 用 api.deepseek.com 风格 baseUrl 触发 thinking 参数。
        baseUrl:
            'http://${server.address.host}:${server.port}/api.deepseek.com/v1',
        apiKey: 'test-key',
        model: 'deepseek-v4-flash',
        temperature: 0.2,
        maxTokens: 1024,
        tools: const [],
        onTurn: (turn) => lastTurn = turn,
      );
      await client.send([
        {'role': 'user', 'content': '测试'},
      ]);
      await handled;

      expect(requestBody['thinking'], {'type': 'enabled'});
      expect(requestBody['reasoning_effort'], 'high');
      expect(requestBody.containsKey('temperature'), isFalse);
      expect(requestBody.containsKey('tool_choice'), isFalse);
      expect(lastTurn?.reasoning, '思考');
      expect(lastTurn?.text, '答案');
    } finally {
      await server.close(force: true);
    }
  });

  test('显式思考强度覆盖默认值，off 与省略语义分离', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bodies = <Map<String, dynamic>>[];
    final handled = () async {
      await for (final request in server) {
        bodies.add(
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>,
        );
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          )
          ..write(
            'data: {"choices":[{"delta":{"content":"答案"},'
            '"finish_reason":"stop"}]}\n\n',
          )
          ..write('data: [DONE]\n\n');
        await request.response.close();
        if (bodies.length == 2) break;
      }
    }();

    try {
      final baseUrl =
          'http://${server.address.host}:${server.port}/api.deepseek.com/v1';
      for (final effort in ['low', 'off']) {
        final client = LlmClient(
          baseUrl: baseUrl,
          apiKey: 'test-key',
          model: 'deepseek-v4-flash',
          temperature: 0.2,
          maxTokens: 1024,
          tools: const [],
          reasoningEffortOverride: effort,
        );
        await client.send([
          {'role': 'user', 'content': '测试'},
        ]);
      }
      await handled;

      expect(bodies[0]['reasoning_effort'], 'low');
      expect(bodies[0]['thinking'], {'type': 'enabled'});
      expect(bodies[1]['reasoning_effort'], 'off');
      expect(bodies[1].containsKey('thinking'), isFalse);
    } finally {
      await server.close(force: true);
    }
  });

  test('普通模型不发送 thinking / reasoning_effort', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    late Map<String, dynamic> requestBody;
    final handled = () async {
      final request = await server.first;
      requestBody =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        )
        ..write(
          'data: {"choices":[{"delta":{"content":"答案"},'
          '"finish_reason":"stop"}]}\n\n',
        )
        ..write('data: [DONE]\n\n');
      await request.response.close();
    }();

    try {
      final client = LlmClient(
        baseUrl: 'http://${server.address.host}:${server.port}/v1',
        apiKey: 'test-key',
        model: 'llama-3.3-70b-versatile',
        temperature: 0.2,
        maxTokens: 1024,
        tools: const [],
      );
      await client.send([
        {'role': 'user', 'content': '测试'},
      ]);
      await handled;
      expect(requestBody.containsKey('thinking'), isFalse);
      expect(requestBody.containsKey('reasoning_effort'), isFalse);
    } finally {
      await server.close(force: true);
    }
  });

  test('Claude 原生协议开启思考时发 thinking.budget_tokens，不发 temperature', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    late Map<String, dynamic> requestBody;
    final handled = () async {
      final request = await server.first;
      requestBody =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        )
        ..write(
          'event: content_block_delta\n'
          'data: {"type":"content_block_delta","index":0,'
          '"delta":{"type":"thinking_delta","thinking":"先想"}}\n\n',
        )
        ..write(
          'event: content_block_delta\n'
          'data: {"type":"content_block_delta","index":1,'
          '"delta":{"type":"text_delta","text":"答案"}}\n\n',
        )
        ..write(
          'event: message_delta\n'
          'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}\n\n',
        )
        ..write(
          'event: message_stop\n'
          'data: {"type":"message_stop"}\n\n',
        );
      await request.response.close();
    }();

    TurnResult? lastTurn;
    try {
      final client = LlmClient(
        baseUrl: 'http://${server.address.host}:${server.port}',
        apiKey: 'sk-ant-test',
        model: 'claude-sonnet-4-5',
        protocol: 'anthropic',
        temperature: 0.2,
        maxTokens: 16384,
        tools: const [],
        onTurn: (turn) => lastTurn = turn,
      );
      await client.send([
        {'role': 'user', 'content': '测试'},
      ]);
      await handled;
      expect(requestBody.containsKey('temperature'), isFalse);
      expect(requestBody.containsKey('reasoning_effort'), isFalse);
      expect(requestBody['thinking'], {
        'type': 'enabled',
        'budget_tokens': 15360,
      });
      expect(lastTurn?.reasoning, '先想');
      expect(lastTurn?.text, '答案');
    } finally {
      await server.close(force: true);
    }
  });

  test('GPT-5 关闭思考发 reasoning_effort=none', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    late Map<String, dynamic> requestBody;
    final handled = () async {
      final request = await server.first;
      requestBody =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        )
        ..write(
          'data: {"choices":[{"delta":{"content":"答案"},'
          '"finish_reason":"stop"}]}\n\n',
        )
        ..write('data: [DONE]\n\n');
      await request.response.close();
    }();

    try {
      final client = LlmClient(
        baseUrl: 'http://${server.address.host}:${server.port}/v1',
        apiKey: 'test-key',
        model: 'gpt-5',
        temperature: 0.2,
        maxTokens: 1024,
        tools: const [],
        reasoningEffortOverride: 'off',
      );
      await client.send([
        {'role': 'user', 'content': '测试'},
      ]);
      await handled;
      expect(requestBody['reasoning_effort'], 'none');
      expect(requestBody.containsKey('thinking'), isFalse);
    } finally {
      await server.close(force: true);
    }
  });

  test('网关拒绝 thinking 时去掉该参数重试成功', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bodies = <Map<String, dynamic>>[];
    final handled = () async {
      var first = true;
      await for (final request in server) {
        final body =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        bodies.add(body);
        if (first) {
          first = false;
          request.response
            ..statusCode = HttpStatus.badRequest
            ..write('{"error":{"message":"unknown parameter: thinking"}}');
          await request.response.close();
          continue;
        }
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          )
          ..write(
            'data: {"choices":[{"delta":{"reasoning_content":"思考"}}]}\n\n',
          )
          ..write('data: [DONE]\n\n');
        await request.response.close();
        break;
      }
    }();

    try {
      final client = LlmClient(
        baseUrl:
            'http://${server.address.host}:${server.port}/api.deepseek.com/v1',
        apiKey: 'test-key',
        model: 'deepseek-v4-flash',
        temperature: 0.2,
        maxTokens: 1024,
        tools: const [],
      );
      await client.send([
        {'role': 'user', 'content': '测试'},
      ]);
      await handled;
      expect(bodies, hasLength(2));
      expect(bodies.first.containsKey('thinking'), isTrue);
      expect(bodies.last.containsKey('thinking'), isFalse);
      expect(bodies.last['reasoning_effort'], 'high');
    } finally {
      await server.close(force: true);
    }
  });

  test('网关拒绝 reasoning_effort 时去掉该参数重试成功', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bodies = <Map<String, dynamic>>[];
    final handled = () async {
      var first = true;
      await for (final request in server) {
        final body =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        bodies.add(body);
        if (first) {
          first = false;
          request.response
            ..statusCode = HttpStatus.badRequest
            ..write(
              '{"error":{"message":"unknown parameter: reasoning_effort"}}',
            );
          await request.response.close();
          continue;
        }
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          )
          ..write(
            'data: {"choices":[{"delta":{"content":"答案"}]},"'
            'finish_reason":"stop"}\n\n',
          )
          ..write('data: [DONE]\n\n');
        await request.response.close();
        break;
      }
    }();

    try {
      final client = LlmClient(
        baseUrl: 'http://${server.address.host}:${server.port}/v1',
        apiKey: 'test-key',
        model: 'deepseek-v4-flash',
        temperature: 0.2,
        maxTokens: 1024,
        tools: const [],
      );
      await client.send([
        {'role': 'user', 'content': '测试'},
      ]);
      await handled;
      expect(bodies, hasLength(2));
      expect(bodies.first.containsKey('reasoning_effort'), isTrue);
      expect(bodies.last.containsKey('reasoning_effort'), isFalse);
      expect(bodies.last.containsKey('thinking'), isFalse);
    } finally {
      await server.close(force: true);
    }
  });

  test('MiMo 模糊 400 时去掉 reasoning_effort 再试，思考开关仍开着', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bodies = <Map<String, dynamic>>[];
    final handled = () async {
      var first = true;
      await for (final request in server) {
        final body =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        bodies.add(body);
        if (first) {
          first = false;
          request.response
            ..statusCode = HttpStatus.badRequest
            ..write(
              '{"error":{"message":"Invalid request parameters","type":"BadRequestError"}}',
            );
          await request.response.close();
          continue;
        }
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          )
          ..write(
            'data: {"choices":[{"delta":{"content":"答案"},'
            '"finish_reason":"stop"}]}\n\n',
          )
          ..write('data: [DONE]\n\n');
        await request.response.close();
        break;
      }
    }();

    try {
      final client = LlmClient(
        baseUrl: 'http://${server.address.host}:${server.port}/v1',
        apiKey: 'test-key',
        model: 'mimo-v2.5-pro',
        temperature: 0.2,
        maxTokens: 8192,
        tools: const [
          {
            'type': 'function',
            'function': {
              'name': 'run_terminal',
              'parameters': {'type': 'object'},
            },
          },
        ],
        reasoningEffortOverride: 'high',
      );
      await client.send([
        {'role': 'user', 'content': '测试'},
        {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'call_1',
              'type': 'function',
              'function': {'name': 'run_terminal', 'arguments': '{}'},
            },
          ],
        },
        {'role': 'tool', 'tool_call_id': 'call_1', 'content': 'ok'},
      ]);
      await handled;
      expect(bodies, hasLength(2));
      expect(bodies.first['reasoning_effort'], 'high');
      expect(bodies.last.containsKey('reasoning_effort'), isFalse);
      expect(bodies.last.containsKey('thinking'), isFalse);
    } finally {
      await server.close(force: true);
    }
  });

  test('拾忆把 content 当正文，思考只来自 reasoning_content', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final handled = () async {
      final request = await server.first;
      await utf8.decoder.bind(request).join();
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        )
        ..write('data: {"choices":[{"delta":{"content":"<think>先想"}}]}\n\n')
        ..write(
          'data: {"choices":[{"delta":{"content":"一下</think>答案"},'
          '"finish_reason":"stop"}]}\n\n',
        )
        ..write('data: [DONE]\n\n');
      await request.response.close();
    }();

    TurnResult? lastTurn;
    try {
      final client = LlmClient(
        baseUrl: 'http://${server.address.host}:${server.port}/v1',
        apiKey: 'test-key',
        model: 'deepseek-v4-flash',
        temperature: 0.2,
        maxTokens: 1024,
        tools: const [],
        onTurn: (turn) => lastTurn = turn,
      );
      await client.send([
        {'role': 'user', 'content': '测试'},
      ]);
      await handled;
      expect(lastTurn?.reasoning, isEmpty);
      expect(lastTurn?.text, '<think>先想一下</think>答案');
    } finally {
      await server.close(force: true);
    }
  });

  group('buildContinuationPrompt', () {
    test('plan ending with colon and tools available returns tool wake-up', () {
      final prompt = LlmClient.buildContinuationPrompt('开始测试：', hasTools: true);

      expect(prompt, contains('还没有实际执行任何工具'));
      expect(prompt, contains('直接调用需要的工具'));
      expect(prompt, isNot(contains('继续完成上述输出')));
    });

    test('real truncation without plan keeps continue-writing prompt', () {
      final prompt = LlmClient.buildContinuationPrompt(
        '这是被截断的内容',
        hasTools: true,
      );

      expect(prompt, contains('继续完成上述输出'));
      expect(prompt, isNot(contains('还没有实际执行任何工具')));
    });

    test('no tools keeps continue-writing prompt even with colon', () {
      final prompt = LlmClient.buildContinuationPrompt(
        '开始测试：',
        hasTools: false,
      );

      expect(prompt, contains('继续完成上述输出'));
      expect(prompt, isNot(contains('直接调用需要的工具')));
    });
  });

  group('listModels', () {
    LlmClient makeClient({
      required String baseUrl,
      String protocol = 'openai',
    }) {
      return LlmClient(
        baseUrl: baseUrl,
        apiKey: 'sk-ant-test',
        model: 'claude-sonnet-4-5',
        protocol: protocol,
        temperature: 0,
        tools: const [],
      );
    }

    test('Anthropic 协议请求 GET /v1/models 并带原生请求头', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      late Uri hit;
      late String? apiKeyHeader;
      late String? versionHeader;
      late String? authHeader;
      server.listen((request) async {
        hit = request.uri;
        apiKeyHeader = request.headers.value('x-api-key');
        versionHeader = request.headers.value('anthropic-version');
        authHeader = request.headers.value('authorization');
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'data': [
                {'id': 'claude-sonnet-4-5'},
                {'id': 'claude-opus-4-1'},
              ],
              'has_more': false,
            }),
          );
        await request.response.close();
      });

      try {
        final ids = await makeClient(
          baseUrl: 'http://${server.address.host}:${server.port}',
          protocol: 'anthropic',
        ).listModels();
        expect(hit.path, '/v1/models');
        expect(hit.queryParameters['limit'], '100');
        expect(apiKeyHeader, 'sk-ant-test');
        expect(versionHeader, '2023-06-01');
        expect(authHeader, isNull);
        expect(ids, ['claude-sonnet-4-5', 'claude-opus-4-1']);
      } finally {
        await server.close(force: true);
      }
    });

    test('Anthropic 结尾带 /v1 的网关不会拼成 /v1/v1/models', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      late String path;
      server.listen((request) async {
        path = request.uri.path;
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'data': [
                {'id': 'claude-haiku-4-5'},
              ],
            }),
          );
        await request.response.close();
      });

      try {
        final ids = await makeClient(
          baseUrl: 'http://${server.address.host}:${server.port}/v1',
          protocol: 'anthropic',
        ).listModels();
        expect(path, '/v1/models');
        expect(ids, ['claude-haiku-4-5']);
      } finally {
        await server.close(force: true);
      }
    });

    test('Anthropic has_more 时按 last_id 翻页合并全部模型', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final afterIds = <String?>[];
      server.listen((request) async {
        final after = request.uri.queryParameters['after_id'];
        afterIds.add(after);
        final page = after == null
            ? {
                'data': [
                  {'id': 'claude-sonnet-4-5'},
                ],
                'has_more': true,
                'last_id': 'claude-sonnet-4-5',
              }
            : {
                'data': [
                  {'id': 'claude-opus-4-1'},
                ],
                'has_more': false,
                'last_id': 'claude-opus-4-1',
              };
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(page));
        await request.response.close();
      });

      try {
        final ids = await makeClient(
          baseUrl: 'http://${server.address.host}:${server.port}',
          protocol: 'anthropic',
        ).listModels();
        expect(afterIds, [null, 'claude-sonnet-4-5']);
        expect(ids, ['claude-sonnet-4-5', 'claude-opus-4-1']);
      } finally {
        await server.close(force: true);
      }
    });

    test('OpenAI 协议仍走 GET {base}/models', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      late String path;
      late String? authHeader;
      server.listen((request) async {
        path = request.uri.path;
        authHeader = request.headers.value('authorization');
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'data': [
                {'id': 'gpt-4o'},
              ],
            }),
          );
        await request.response.close();
      });

      try {
        final ids = await makeClient(
          baseUrl: 'http://${server.address.host}:${server.port}/v1',
        ).listModels();
        expect(path, '/v1/models');
        expect(authHeader, 'Bearer sk-ant-test');
        expect(ids, ['gpt-4o']);
      } finally {
        await server.close(force: true);
      }
    });
  });
}
