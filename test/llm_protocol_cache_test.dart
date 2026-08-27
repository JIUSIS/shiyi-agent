import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:shiyi_agent_app/services/llm_client.dart';

void main() {
  group('协议请求体与缓存分层', () {
    final tools = <Map<String, dynamic>>[
      {
        'type': 'function',
        'function': {
          'name': 'a',
          'description': 'A',
          'parameters': {'type': 'object', 'properties': <String, dynamic>{}},
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'b',
          'description': 'B',
          'parameters': {'type': 'object', 'properties': <String, dynamic>{}},
        },
      },
    ];

    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': 'FROZEN_PREFIX'},
      {'role': 'user', 'content': 'hello'},
      {'role': 'assistant', 'content': 'hi'},
      {'role': 'system', 'content': 'TAIL_TIME'},
    ];

    test('Chat Completions：冻头在前、动尾在历史之后，不合并进第一条 system', () async {
      final captured = await _sendOnce(
        protocol: 'openai',
        model: 'llama-3.3-70b-versatile',
        messages: messages,
        sse:
            'data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}\n\n'
            'data: [DONE]\n\n',
      );
      expect(captured.uri.path, endsWith('/chat/completions'));
      final msgs = captured.body['messages'] as List;
      expect(msgs.first['role'], 'system');
      expect(msgs.first['content'], 'FROZEN_PREFIX');
      expect(msgs.last['role'], 'system');
      expect(msgs.last['content'], 'TAIL_TIME');
      expect(msgs[1]['role'], 'user');
      expect(msgs[1]['content'], 'hello');
      expect(
        msgs.where((m) => m['role'] == 'system' && m['content'] == 'FROZEN_PREFIX\n\nTAIL_TIME'),
        isEmpty,
      );
    });

    test('Claude：冻头 system 与最后一个 tool 打 cache_control', () async {
      final captured = await _sendOnce(
        protocol: 'anthropic',
        model: 'claude-sonnet-4-5',
        messages: messages,
        tools: tools,
        sse:
            'data: {"type":"message_start","message":{"usage":{"input_tokens":10}}}\n\n'
            'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"ok"}}\n\n'
            'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}\n\n'
            'data: {"type":"message_stop"}\n\n',
      );
      expect(captured.uri.path, '/v1/messages');
      expect(captured.headers['anthropic-beta'], 'prompt-caching-2024-07-31');
      final system = captured.body['system'] as List;
      expect(system.first['text'], 'FROZEN_PREFIX');
      expect(system.first['cache_control'], {'type': 'ephemeral'});
      expect(system.last['text'], 'TAIL_TIME');
      expect(system.last.containsKey('cache_control'), isFalse);
      final anthTools = captured.body['tools'] as List;
      expect(anthTools.first.containsKey('cache_control'), isFalse);
      expect(anthTools.last['cache_control'], {'type': 'ephemeral'});
    });

    test('Responses：路径 /responses，instructions/input/store:false', () async {
      final captured = await _sendOnce(
        protocol: 'responses',
        model: 'llama-3.3-70b-versatile',
        messages: messages,
        tools: tools,
        sse:
            'event: response.output_text.delta\n'
            'data: {"type":"response.output_text.delta","delta":"hello"}\n\n'
            'event: response.completed\n'
            'data: {"type":"response.completed","response":{"usage":{"input_tokens":100,"output_tokens":4,"input_tokens_details":{"cached_tokens":80}}}}\n\n',
      );
      expect(captured.uri.path, endsWith('/responses'));
      expect(captured.uri.path.endsWith('/chat/completions'), isFalse);
      expect(captured.body['instructions'], 'FROZEN_PREFIX');
      expect(captured.body['store'], isFalse);
      expect(captured.body['max_output_tokens'], isNotNull);
      expect(captured.body.containsKey('previous_response_id'), isFalse);
      expect(captured.body.containsKey('prompt_cache_key'), isFalse);
      final input = captured.body['input'] as List;
      expect(input.last['role'], 'system');
      expect(input.last['content'], 'TAIL_TIME');
      expect(input.first['role'], 'user');
      final respTools = captured.body['tools'] as List;
      expect(respTools.first['type'], 'function');
      expect(respTools.first['name'], 'a');
      expect(respTools.first.containsKey('function'), isFalse);
      expect(captured.body['tool_choice'], 'auto');
      expect(captured.body['parallel_tool_calls'], isTrue);
      expect(captured.body['include'], ['reasoning.encrypted_content']);
      expect(captured.turn?.text, 'hello');
      expect(captured.cached, 80);
    });

    test('Chat Completions：tools 时发 tool_choice 与 parallel_tool_calls', () async {
      final captured = await _sendOnce(
        protocol: 'openai',
        model: 'llama-3.3-70b-versatile',
        messages: messages,
        tools: tools,
        sse:
            'data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}\n\n'
            'data: [DONE]\n\n',
      );
      expect(captured.body['tool_choice'], 'auto');
      expect(captured.body['parallel_tool_calls'], isTrue);
      expect(captured.body.containsKey('include'), isFalse);
    });

    test('Responses：加密思考 item 原样回放，Chat 字段不进 input', () async {
      final captured = await _sendOnce(
        protocol: 'responses',
        model: 'grok-4.6',
        messages: <Map<String, dynamic>>[
          {'role': 'system', 'content': 'FROZEN_PREFIX'},
          {'role': 'user', 'content': 'hello'},
          {
            'role': 'assistant',
            'content': '',
            'reasoning_encrypted': 'enc-abc',
            'tool_calls': [
              {
                'id': 'call_1',
                'type': 'function',
                'function': {'name': 'a', 'arguments': '{}'},
              },
            ],
          },
          {'role': 'tool', 'content': 'ok', 'tool_call_id': 'call_1'},
        ],
        tools: tools,
        sse:
            'event: response.output_item.done\n'
            'data: {"type":"response.output_item.done","item":{"type":"reasoning","encrypted_content":"enc-xyz"}}\n\n'
            'event: response.output_text.delta\n'
            'data: {"type":"response.output_text.delta","delta":"好"}\n\n'
            'event: response.completed\n'
            'data: {"type":"response.completed","response":{"output_text":"好"}}\n\n',
      );
      final input = captured.body['input'] as List;
      expect(input[0]['role'], 'user');
      expect(input[1]['type'], 'reasoning');
      expect(input[1]['encrypted_content'], 'enc-abc');
      expect(input[2]['type'], 'function_call');
      expect(input[2]['name'], 'a');
      expect(input[3]['type'], 'function_call_output');
      expect(captured.turn?.reasoningEncrypted, 'enc-xyz');
      expect(jsonEncode(captured.body['input']), isNot(contains('reasoning_encrypted')));
    });

    test('Responses：Chat 图片块转成 input_image，image_url 是字符串', () async {
      final captured = await _sendOnce(
        protocol: 'responses',
        model: 'grok-4.6',
        messages: <Map<String, dynamic>>[
          {'role': 'system', 'content': 'FROZEN_PREFIX'},
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': '看看这张图'},
              {
                'type': 'image_url',
                'image_url': {'url': 'data:image/jpeg;base64,abc'},
              },
            ],
          },
        ],
        sse:
            'event: response.output_text.delta\n'
            'data: {"type":"response.output_text.delta","delta":"图"}\n\n'
            'event: response.completed\n'
            'data: {"type":"response.completed","response":{"output_text":"图"}}\n\n',
      );
      final input = captured.body['input'] as List;
      final user = input.first as Map;
      expect(user['role'], 'user');
      final content = user['content'] as List;
      expect(content[0]['type'], 'input_text');
      expect(content[0]['text'], '看看这张图');
      expect(content[1]['type'], 'input_image');
      expect(content[1]['image_url'], 'data:image/jpeg;base64,abc');
      expect(content[1]['image_url'], isA<String>());
      expect(content[1].containsKey('detail'), isFalse);
    });

    test('Chat Completions：图片仍走 image_url 对象，不改成 input_image', () async {
      final captured = await _sendOnce(
        protocol: 'openai',
        model: 'grok-4.6',
        messages: <Map<String, dynamic>>[
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': '看看这张图'},
              {
                'type': 'image_url',
                'image_url': {'url': 'data:image/jpeg;base64,abc'},
              },
            ],
          },
        ],
        sse:
            'data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}\n\n'
            'data: [DONE]\n\n',
      );
      expect(captured.uri.path, endsWith('/chat/completions'));
      final msgs = captured.body['messages'] as List;
      final content = msgs.first['content'] as List;
      expect(content[0]['type'], 'text');
      expect(content[1]['type'], 'image_url');
      expect(content[1]['image_url'], {'url': 'data:image/jpeg;base64,abc'});
    });

    test('Responses SSE 没有 [DONE] 也能在 response.completed 结束', () async {
      final captured = await _sendOnce(
        protocol: 'responses',
        model: 'llama-3.3-70b-versatile',
        messages: <Map<String, dynamic>>[
          {'role': 'user', 'content': 'hi'},
        ],
        sse:
            'data: {"type":"response.output_text.delta","delta":"完"}\n\n'
            'data: {"type":"response.completed","response":{"output_text":"完"}}\n\n',
      );
      expect(captured.turn?.text, '完');
    });
  });
}

class _Captured {
  _Captured(this.body, this.uri, this.headers, this.turn, this.cached);
  final Map<String, dynamic> body;
  final Uri uri;
  final Map<String, String?> headers;
  final TurnResult? turn;
  final int? cached;
}

Future<_Captured> _sendOnce({
  required String protocol,
  required String model,
  required List<Map<String, dynamic>> messages,
  List<Map<String, dynamic>> tools = const [],
  required String sse,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  late Map<String, dynamic> body;
  late Uri uri;
  final headers = <String, String?>{};
  server.listen((request) async {
    uri = request.uri;
    headers['anthropic-beta'] = request.headers.value('anthropic-beta');
    body = jsonDecode(await utf8.decoder.bind(request).join())
        as Map<String, dynamic>;
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8')
      ..write(sse);
    await request.response.close();
  });

  TurnResult? lastTurn;
  int? cached;
  try {
    final client = LlmClient(
      baseUrl: 'http://${server.address.host}:${server.port}/v1',
      apiKey: 'test-key',
      model: model,
      protocol: protocol,
      temperature: 0.2,
      maxTokens: 1024,
      tools: tools,
      onTurn: (turn) => lastTurn = turn,
    );
    await client.send(messages);
    cached = client.lastCachedTokens;
    return _Captured(body, uri, headers, lastTurn, cached);
  } finally {
    await server.close(force: true);
  }
}
