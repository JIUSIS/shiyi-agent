import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:shiyi_agent_app/services/llm_client.dart';

/// 长文本 / 长推理 / 流式断连的回归测试。
///
/// 覆盖：
/// - 输出上限截断后的自动续写必须把多轮正文拼成一条完整回复（不丢前几轮）；
/// - 续写接缝处的重复内容要裁掉，不能整段重抄；
/// - 思考内容跨续写轮累计，不能被正文覆盖；
/// - 连接中途断开时按断点续写，而不是把已生成内容丢掉重来；
/// - 网关静默结束（无 finish_reason / 无 [DONE]）补一次续写确认；
/// - finish_reason=length + 工具参数收齐 → 照常完成（截断不影响执行）；
/// - 超大单帧（> 1MB 单行）不丢数据；
/// - 续写轮数上限可配置，用尽且服务商确实截断时标记 incomplete。
void main() {
  /// 起一个本地 SSE 服务，按 [scripts] 依次响应每个请求；
  /// 请求数超出脚本数时沿用最后一个脚本。脚本返回 null = 直接掐断连接。
  Future<({HttpServer server, List<Map<String, dynamic>> bodies})> serve(
    List<String? Function(int index)> scripts,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bodies = <Map<String, dynamic>>[];
    var index = 0;
    server.listen((request) async {
      bodies.add(
        jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>,
      );
      final i = index++;
      final script = scripts[i < scripts.length ? i : scripts.length - 1];
      final payload = script(i);
      if (payload == null) {
        // 直接掐断连接：模拟流式过程中网络断开。
        await request.response.close();
        return;
      }
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        )
        ..write(payload);
      await request.response.close();
    });
    return (server: server, bodies: bodies);
  }

  String chunk(String content, {String? finish}) =>
      'data: ${jsonEncode({
        'choices': [
          {
            'delta': {'content': content},
            if (finish != null) 'finish_reason': finish,
          },
        ],
      })}\n\n';

  String reasoningChunk(String text) =>
      'data: ${jsonEncode({
        'choices': [
          {
            'delta': {'reasoning_content': text},
          },
        ],
      })}\n\n';

  const done = 'data: [DONE]\n\n';

  test('输出上限截断：多轮续写拼成完整正文，不丢前面几轮', () async {
    final s = await serve([
      // 第 1 轮：写一半就被输出上限截断
      (_) => '${chunk('第一段内容，', finish: 'length')}$done',
      // 第 2 轮：继续写
      (_) => '${chunk('第二段内容，', finish: 'length')}$done',
      // 第 3 轮：收尾
      (_) => '${chunk('第三段结束。', finish: 'stop')}$done',
    ]);
    try {
      final turns = <TurnResult>[];
      final client = LlmClient(
        baseUrl: 'http://${s.server.address.host}:${s.server.port}/v1',
        apiKey: 'k',
        model: 'deepseek-v4-flash',
        temperature: 0.2,
        maxTokens: 1024,
        tools: const [],
        onTurn: turns.add,
      );
      await client.send([
        {'role': 'user', 'content': '写一篇长文'},
      ]);

      // 关键回归：最终一条必须是三轮拼接后的完整正文。
      expect(turns.last.text, '第一段内容，第二段内容，第三段结束。');
      expect(client.continuationRounds, 2);
      expect(client.endedIncomplete, isFalse);
      // 续写请求里带上了上一轮已输出的内容（从断点继续）。
      expect(s.bodies, hasLength(3));
      final second = (s.bodies[1]['messages'] as List).cast<Map>();
      expect(second.any((m) => m['content'] == '第一段内容，'), isTrue);
    } finally {
      await s.server.close(force: true);
    }
  });

  test('续写接缝重复内容被裁掉，不整段重抄', () async {
    final s = await serve([
      (_) => '${chunk('春天来了，万物复苏。')}\n\n',
      // 第 2 轮把上一轮的结尾重抄了一遍再继续
      (_) => '${chunk('春天来了，万物复苏。夏天到了。', finish: 'stop')}$done',
    ]);
    try {
      // 第 1 轮没有 finish_reason 也没有 [DONE] → 触发一次续写确认。
      final turns = <TurnResult>[];
      final client = LlmClient(
        baseUrl: 'http://${s.server.address.host}:${s.server.port}/v1',
        apiKey: 'k',
        model: 'gpt-5',
        temperature: 0.2,
        maxTokens: 1024,
        tools: const [],
        onTurn: turns.add,
      );
      await client.send([
        {'role': 'user', 'content': '写四季'},
      ]);
      expect(turns.last.text, '春天来了，万物复苏。夏天到了。');
    } finally {
      await s.server.close(force: true);
    }
  });

  test('跨续写轮的思考内容累计，不被正文覆盖', () async {
    final s = await serve([
      (_) =>
          '${reasoningChunk('先想第一步。')}${chunk('正文一。', finish: 'length')}$done',
      (_) => '${reasoningChunk('再想第二步。')}${chunk('正文二。', finish: 'stop')}$done',
    ]);
    try {
      final turns = <TurnResult>[];
      final client = LlmClient(
        baseUrl: 'http://${s.server.address.host}:${s.server.port}/v1',
        apiKey: 'k',
        model: 'deepseek-v4-flash',
        temperature: 0.2,
        maxTokens: 1024,
        tools: const [],
        onTurn: turns.add,
      );
      await client.send([
        {'role': 'user', 'content': '慢慢想'},
      ]);
      expect(turns.last.text, '正文一。正文二。');
      expect(turns.last.reasoning, '先想第一步。再想第二步。');
    } finally {
      await s.server.close(force: true);
    }
  });

  test('流式断连：保留已生成内容并从断点续写，不丢内容重来', () async {
    final s = await serve([
      // 写了半句就断线（没有 finish_reason、没有 [DONE]，直接关连接）
      (_) => chunk('前半句没有写完'),
      (_) => '${chunk('，后半句补上。', finish: 'stop')}$done',
    ]);
    try {
      final turns = <TurnResult>[];
      final client = LlmClient(
        baseUrl: 'http://${s.server.address.host}:${s.server.port}/v1',
        apiKey: 'k',
        model: 'gpt-4o',
        temperature: 0.2,
        maxTokens: 1024,
        tools: const [],
        onTurn: turns.add,
      );
      await client.send([
        {'role': 'user', 'content': '说一句完整的话'},
      ]);
      // 断线不再抛异常，而是续写；已生成内容全部保留。
      expect(turns.last.text, '前半句没有写完，后半句补上。');
      expect(client.lastRoundInterrupted, isTrue);
      expect(s.bodies, hasLength(2));
    } finally {
      await s.server.close(force: true);
    }
  });

  test('续写轮数上限可配置：用尽且服务商报截断 → endedIncomplete', () async {
    final s = await serve([
      (int i) => '${chunk('第${i + 1}段', finish: 'length')}$done',
    ]);
    try {
      final turns = <TurnResult>[];
      final client = LlmClient(
        baseUrl: 'http://${s.server.address.host}:${s.server.port}/v1',
        apiKey: 'k',
        model: 'deepseek-v4-flash',
        temperature: 0.2,
        maxTokens: 1024,
        tools: const [],
        maxContinuationRounds: 2,
        onTurn: turns.add,
      );
      await client.send([
        {'role': 'user', 'content': '写不完的长文'},
      ]);
      // 2 轮续写 + 首次请求 = 3 次请求，然后如实标记不完整。
      expect(s.bodies, hasLength(3));
      expect(client.endedIncomplete, isTrue);
      expect(client.lastFinishReason, 'length');
      expect(turns.last.text, '第1段第2段第3段');
    } finally {
      await s.server.close(force: true);
    }
  });

  test('maxContinuationRounds=0 时不续写，直接标记不完整', () async {
    final s = await serve([(_) => '${chunk('截断内容', finish: 'length')}$done']);
    try {
      final client = LlmClient(
        baseUrl: 'http://${s.server.address.host}:${s.server.port}/v1',
        apiKey: 'k',
        model: 'deepseek-v4-flash',
        temperature: 0.2,
        maxTokens: 1024,
        tools: const [],
        maxContinuationRounds: 0,
      );
      await client.send([
        {'role': 'user', 'content': '长文'},
      ]);
      expect(s.bodies, hasLength(1));
      expect(client.endedIncomplete, isTrue);
    } finally {
      await s.server.close(force: true);
    }
  });

  test('finish_reason=length 但工具参数已收齐 → 照常完成不续写', () async {
    final toolCall =
        'data: ${jsonEncode({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call_1',
                    'function': {'name': 'run_terminal', 'arguments': '{"command":"ls"}'},
                  },
                ],
              },
              'finish_reason': 'length',
            },
          ],
        })}\n\n';
    final s = await serve([(_) => '$toolCall$done']);
    try {
      final turns = <TurnResult>[];
      final client = LlmClient(
        baseUrl: 'http://${s.server.address.host}:${s.server.port}/v1',
        apiKey: 'k',
        model: 'gpt-5',
        temperature: 0.2,
        maxTokens: 1024,
        tools: const [
          {
            'type': 'function',
            'function': {
              'name': 'run_terminal',
              'parameters': {'type': 'object'},
            },
          },
        ],
        onTurn: turns.add,
      );
      await client.send([
        {'role': 'user', 'content': '看看目录'},
      ]);
      expect(s.bodies, hasLength(1));
      expect(client.endedIncomplete, isFalse);
      expect(turns.last.toolCalls.single['name'], 'run_terminal');
      expect(turns.last.toolCalls.single['arguments'], '{"command":"ls"}');
    } finally {
      await s.server.close(force: true);
    }
  });

  test('超大单帧（>1MB 单行）不丢数据', () async {
    final big = 'x' * (1100 * 1024);
    final s = await serve([(int _) => '${chunk(big, finish: 'stop')}$done']);
    try {
      final turns = <TurnResult>[];
      final client = LlmClient(
        baseUrl: 'http://${s.server.address.host}:${s.server.port}/v1',
        apiKey: 'k',
        model: 'gpt-4o',
        temperature: 0.2,
        maxTokens: 1024,
        tools: const [],
        onTurn: turns.add,
      );
      await client.send([
        {'role': 'user', 'content': '输出一大段'},
      ]);
      expect(turns.last.text.length, big.length);
    } finally {
      await s.server.close(force: true);
    }
  });

  group('长时间推理 / 空闲超时', () {
    /// 起一个「写一半就静默不发数据」的服务：验证空闲超时可配置，
    /// 并且不是直接把已生成内容丢掉重来。
    Future<HttpServer> silentServer({
      required String firstChunk,
      required String restPayload,
    }) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var index = 0;
      server.listen((request) async {
        try {
          await utf8.decoder.bind(request).join();
          final i = index++;
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType(
              'text',
              'event-stream',
              charset: 'utf-8',
            );
          if (i == 0) {
            request.response.write(firstChunk);
            await request.response.flush();
            // 之后长时间不出字（模拟模型还在思考 / 网关挂住）。
            await Future<void>.delayed(const Duration(seconds: 8));
          } else {
            request.response.write(restPayload);
          }
          await request.response.close();
        } catch (_) {
          // 客户端已取消连接：忽略写失败。
        }
      });
      return server;
    }

    test('收到内容后长时间无数据：保留内容并判定为可续写（不丢回空气泡）', () async {
      // 用受控字节流精确复现「已经出字、之后网关挂住」的时序：
      // 真实 socket 在 flutter test 里要等响应结束才投递 body，控制不了时序。
      final controller = StreamController<List<int>>();
      final turns = <TurnResult>[];
      final client = LlmClient(
        baseUrl: 'http://127.0.0.1:1/v1',
        apiKey: 'k',
        model: 'gpt-4o',
        temperature: 0.2,
        maxTokens: 1024,
        tools: const [],
        streamWaitTimeout: const Duration(milliseconds: 200),
        onTurn: turns.add,
      );
      final pending = client.parseOpenAiStreamForTest(controller.stream);
      controller.add(utf8.encode(chunk('已经写了半句')));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final needContinue = await pending;
      expect(needContinue, isTrue);
      expect(client.lastRoundInterrupted, isTrue);
      expect(turns.last.text, '已经写了半句');
      await controller.close();
    });

    test('空闲超时且什么都没收到 → 抛可重试的中断异常（不当成正常完成）', () async {
      final server = await silentServer(
        firstChunk: ': keep-alive\n\n',
        restPayload: '',
      );
      try {
        final client = LlmClient(
          baseUrl: 'http://${server.address.host}:${server.port}/v1',
          apiKey: 'k',
          model: 'gpt-4o',
          temperature: 0.2,
          maxTokens: 1024,
          tools: const [],
          streamWaitTimeout: const Duration(seconds: 2),
        );
        await expectLater(
          client.send([
            {'role': 'user', 'content': '在吗'},
          ]),
          throwsA(isA<LlmInterruptedException>()),
        );
      } finally {
        await server.close(force: true);
      }
    });
  });

  test('Anthropic：stop_reason=max_tokens 时自动续写并拼完整', () async {
    final s = await serve([
      (_) =>
          'event: content_block_delta\n'
          'data: {"type":"content_block_delta","index":0,'
          '"delta":{"type":"text_delta","text":"第一段。"}}\n\n'
          'event: message_delta\n'
          'data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"}}\n\n',
      (_) =>
          'event: content_block_delta\n'
          'data: {"type":"content_block_delta","index":0,'
          '"delta":{"type":"text_delta","text":"第二段。"}}\n\n'
          'event: message_delta\n'
          'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}\n\n'
          'event: message_stop\n'
          'data: {"type":"message_stop"}\n\n',
    ]);
    try {
      final turns = <TurnResult>[];
      final client = LlmClient(
        baseUrl: 'http://${s.server.address.host}:${s.server.port}',
        apiKey: 'k',
        model: 'claude-sonnet-4-5',
        protocol: 'anthropic',
        temperature: 0.2,
        maxTokens: 4096,
        tools: const [],
        onTurn: turns.add,
      );
      await client.send([
        {'role': 'user', 'content': '写两段'},
      ]);
      expect(turns.last.text, '第一段。第二段。');
      expect(client.lastFinishReason, 'end_turn');
      expect(client.continuationRounds, 1);
      expect(client.endedIncomplete, isFalse);
    } finally {
      await s.server.close(force: true);
    }
  });

  test('Responses：response.incomplete(max_output_tokens) 自动续写', () async {
    final s = await serve([
      (_) =>
          'data: {"type":"response.output_text.delta","delta":"第一段。"}\n\n'
          'data: {"type":"response.incomplete","response":'
          '{"incomplete_details":{"reason":"max_output_tokens"}}}\n\n',
      (_) =>
          'data: {"type":"response.output_text.delta","delta":"第二段。"}\n\n'
          'data: {"type":"response.completed","response":{}}\n\n',
    ]);
    try {
      final turns = <TurnResult>[];
      final client = LlmClient(
        baseUrl: 'http://${s.server.address.host}:${s.server.port}/v1',
        apiKey: 'k',
        model: 'gpt-5',
        protocol: 'responses',
        temperature: 0.2,
        maxTokens: 4096,
        tools: const [],
        onTurn: turns.add,
      );
      await client.send([
        {'role': 'user', 'content': '写两段'},
      ]);
      expect(turns.last.text, '第一段。第二段。');
      expect(client.continuationRounds, 1);
    } finally {
      await s.server.close(force: true);
    }
  });

  group('mergeContinuedText', () {
    test('无重叠直接拼接', () {
      expect(LlmClient.mergeContinuedText('前半', '后半'), '前半后半');
    });

    test('裁掉长重叠，保留一份', () {
      expect(
        LlmClient.mergeContinuedText('今天天气很好，我们', '我们一起去爬山。'),
        '今天天气很好，我们一起去爬山。',
      );
    });

    test('短重叠（<2 字符）不裁，避免误伤正常接续用词', () {
      expect(LlmClient.mergeContinuedText('他说的', '的话都对'), '他说的的话都对');
    });

    test('空串安全', () {
      expect(LlmClient.mergeContinuedText('', 'a'), 'a');
      expect(LlmClient.mergeContinuedText('a', ''), 'a');
    });
  });
}
