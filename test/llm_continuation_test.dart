import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:shiyi_agent_app/services/llm_client.dart';

void main() {
  test('明显思考模型默认启用 high reasoning effort', () {
    expect(LlmClient.defaultReasoningEffort('deepseek-v4-flash'), 'high');
    expect(LlmClient.defaultReasoningEffort('vendor/qwq-32b'), 'high');
    expect(LlmClient.defaultReasoningEffort('o3-mini'), 'high');
    expect(LlmClient.defaultReasoningEffort('gpt-4.1-mini'), isNull);
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
        model: 'gpt-4.1-mini',
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
}
