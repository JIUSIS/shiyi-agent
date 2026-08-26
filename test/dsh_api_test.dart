import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shiyi_agent_app/core/models.dart';
import 'package:shiyi_agent_app/services/dsh_api.dart';

/// DSH API 客户端测试：mock HTTP 响应，验证 RPC 封装与事件重建。
void main() {
  DshApiClient clientWith(MockClient mock) =>
      DshApiClient(baseUrl: 'http://test.local', client: mock);

  Map<String, dynamic> okValue(Map<String, dynamic> value) => {
    'type': 'server-response',
    'rpcId': 'test-rpc',
    'result': {'ok': true, 'value': value},
  };

  Map<String, dynamic> errValue(String code, String message) => {
    'type': 'server-response',
    'rpcId': 'test-rpc',
    'result': {
      'ok': false,
      'error': {'code': code, 'message': message},
    },
  };

  Map<String, dynamic> event(String type, int seq, Map<String, dynamic> data) =>
      {'type': type, 'seq': seq, 'time': 1786000000000 + seq, 'data': data};

  test('RPC 请求封装：POST /api/<method>，client-request 信封', () async {
    late http.Request captured;
    final mock = MockClient((req) async {
      captured = req;
      return http.Response(
        jsonEncode(okValue({'items': []})),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final client = clientWith(mock);
    await client.listSessions();
    expect(captured.url.toString(), 'http://test.local/api/session.list');
    expect(captured.method, 'POST');
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(body['type'], 'client-request');
    expect(body['method'], 'session.list');
    expect(body['rpcId'], isA<String>());
    expect(body['payload'], isA<Map>());
  });

  test('createSession：带 cwd 时写入 session.create payload', () async {
    late http.Request captured;
    final mock = MockClient((req) async {
      captured = req;
      return http.Response(
        jsonEncode(okValue({'sessionId': 'sess-1'})),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final id = await clientWith(
      mock,
    ).createSession(cwd: '/storage/emulated/0/docs');
    expect(id, 'sess-1');
    expect(captured.url.toString(), 'http://test.local/api/session.create');
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(body['method'], 'session.create');
    expect(body['payload']['cwd'], '/storage/emulated/0/docs');
  });

  test('RPC 错误：ok=false 时抛 DshApiException（含 code）', () async {
    final mock = MockClient(
      (req) async => http.Response(
        jsonEncode(errValue('agent-busy', 'agent is busy')),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final client = clientWith(mock);
    await expectLater(
      client.listSessions(),
      throwsA(
        isA<DshApiException>()
            .having((e) => e.code, 'code', 'agent-busy')
            .having((e) => e.message, 'message', 'agent is busy'),
      ),
    );
  });

  test('rpcPing：RPC 就绪返回 true，并发探测合并为一次请求', () async {
    var calls = 0;
    final mock = MockClient((req) async {
      calls++;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return http.Response(
        jsonEncode(okValue({'items': []})),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final client = clientWith(mock);
    final a = client.rpcPing();
    final b = client.rpcPing();
    expect(await a, isTrue);
    expect(await b, isTrue);
    expect(calls, 1);
  });

  test('rpcPing：HTTP 错误返回 false，不抛异常', () async {
    final mock = MockClient((req) async => http.Response('oops', 500));
    expect(await clientWith(mock).rpcPing(), isFalse);
  });

  test('history：user/message + assistant/message 重建为消息（文本/思考）', () async {
    final mock = MockClient(
      (req) async => http.Response(
        jsonEncode(
          okValue({
            'events': [
              {
                'event': event('user/message', 1, {
                  'content': [
                    {'type': 'text', 'text': '介绍一下你自己'},
                  ],
                  'role': 'user',
                  'id': 'msg-user-1',
                }),
              },
              {
                'event': event('assistant/message', 2, {
                  'turn': 1,
                  'step': 1,
                  'message': {
                    'role': 'assistant',
                    'content': [
                      {'type': 'reasoning', 'text': '用户在问自我介绍，我直接回答。'},
                      {'type': 'text', 'text': '我是拾忆，你的 AI 助手。'},
                    ],
                  },
                }),
              },
              // 工具调用应挂到前一条助手消息上。
              {
                'event': event('tool/call', 3, {
                  'turn': 1,
                  'step': 2,
                  'callId': 'call_1',
                  'name': 'web_search',
                  'arguments': '{"q":"test"}',
                }),
              },
            ],
            'hasMore': false,
          }),
        ),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final client = clientWith(mock);
    final msgs = await client.history('session-test');

    expect(msgs, hasLength(2));
    expect(msgs[0].role, 'user');
    expect(msgs[0].content, '介绍一下你自己');
    expect(msgs[1].role, 'assistant');
    expect(msgs[1].content, '我是拾忆，你的 AI 助手。');
    expect(msgs[1].reasoning, '用户在问自我介绍，我直接回答。');
    expect(msgs[1].toolCalls, hasLength(1));
    expect(msgs[1].toolCalls.first.name, 'web_search');
  });

  test('history：正文里的 think 标签拆进 reasoning', () async {
    final mock = MockClient(
      (req) async => http.Response(
        jsonEncode(
          okValue({
            'events': [
              {
                'event': event('assistant/message', 1, {
                  'message': {
                    'role': 'assistant',
                    'content': [
                      {'type': 'text', 'text': '<think>先分析</think>最终回答'},
                    ],
                  },
                }),
              },
            ],
            'hasMore': false,
          }),
        ),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final msgs = await clientWith(mock).history('session-think');
    expect(msgs.single.content, '最终回答');
    expect(msgs.single.reasoning, '先分析');
  });

  test('history：未收口的 assistant/chunk 不产生消息，留给 live', () async {
    final mock = MockClient(
      (req) async => http.Response(
        jsonEncode(
          okValue({
            'events': [
              {
                'event': event('assistant/chunk', 10, {
                  'turn': 1,
                  'step': 1,
                  'chunk': {'type': 'reasoning-delta', 'index': 0, 'text': '思'},
                }),
              },
              {
                'event': event('assistant/chunk', 11, {
                  'turn': 1,
                  'step': 1,
                  'chunk': {'type': 'text-delta', 'index': 0, 'text': '好'},
                }),
              },
            ],
            'hasMore': false,
          }),
        ),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final client = clientWith(mock);
    final msgs = await client.history('session-test');
    expect(msgs, isEmpty);
  });

  test('history：chunks + turn/end 无 assistant/message 时冻成最后一条完整回复', () async {
    final mock = MockClient(
      (req) async => http.Response(
        jsonEncode(
          okValue({
            'events': [
              {
                'event': event('user/message', 1, {
                  'content': [
                    {'type': 'text', 'text': '把这段写完'},
                  ],
                  'role': 'user',
                  'id': 'msg-user-1',
                }),
              },
              {
                'event': event('assistant/chunk', 2, {
                  'turn': 1,
                  'step': 1,
                  'chunk': {
                    'type': 'reasoning-delta',
                    'index': 0,
                    'text': '先组织后半段。',
                  },
                }),
              },
              {
                'event': event('assistant/chunk', 3, {
                  'turn': 1,
                  'step': 1,
                  'chunk': {'type': 'text-delta', 'index': 1, 'text': '这是前半'},
                }),
              },
              {
                'event': event('assistant/chunk', 4, {
                  'turn': 1,
                  'step': 1,
                  'chunk': {'type': 'text-delta', 'index': 1, 'text': '段完整输出。'},
                }),
              },
              {
                'event': event('turn/end', 5, {
                  'reason': {'kind': 'completed'},
                }),
              },
            ],
            'hasMore': false,
          }),
        ),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final bundle = await clientWith(mock).historyBundle('session-partial');
    expect(bundle.messages, hasLength(2));
    expect(bundle.messages.first.role, 'user');
    expect(bundle.messages.last.role, 'assistant');
    expect(bundle.messages.last.content, '这是前半段完整输出。');
    expect(bundle.messages.last.reasoning, '先组织后半段。');
    expect(bundle.messages.last.id, 'dsh-asst-5');
    expect(bundle.live.open, isFalse);
    expect(bundle.live.hasVisible, isFalse);
    expect(bundle.turnEnded, isTrue);
  });

  test('history：chunks + aborted turn/end 同样冻成最后一条助手消息', () async {
    final mock = MockClient(
      (req) async => http.Response(
        jsonEncode(
          okValue({
            'events': [
              {
                'event': event('user/message', 1, {
                  'content': [
                    {'type': 'text', 'text': '继续'},
                  ],
                  'role': 'user',
                  'id': 'u-abort',
                }),
              },
              {
                'event': event('assistant/chunk', 2, {
                  'chunk': {'type': 'text-delta', 'index': 0, 'text': '已经写到一半'},
                }),
              },
              {
                'event': event('tool/call', 3, {
                  'callId': 'call_partial',
                  'name': 'fs_read',
                  'arguments': '{"path":"/a"}',
                }),
              },
              {
                'event': event('turn/end', 4, {
                  'reason': {'kind': 'aborted'},
                }),
              },
            ],
          }),
        ),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final msgs = await clientWith(mock).history('session-aborted');
    expect(msgs, hasLength(2));
    expect(msgs.last.content, '已经写到一半');
    expect(msgs.last.toolCalls, hasLength(1));
    expect(msgs.last.toolCalls.first.name, 'fs_read');
  });

  test('history：已有 assistant/message 时 chunk 缓冲不再冻成第二条', () async {
    final mock = MockClient(
      (req) async => http.Response(
        jsonEncode(
          okValue({
            'events': [
              {
                'event': event('assistant/chunk', 1, {
                  'chunk': {'type': 'text-delta', 'index': 0, 'text': 'half'},
                }),
              },
              {
                'event': event('assistant/message', 2, {
                  'message': {
                    'role': 'assistant',
                    'content': [
                      {'type': 'text', 'text': 'full reply'},
                    ],
                  },
                }),
              },
              {
                'event': event('turn/end', 3, {
                  'reason': {'kind': 'completed'},
                }),
              },
            ],
          }),
        ),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final msgs = await clientWith(mock).history('session-finalized');
    expect(msgs, hasLength(1));
    expect(msgs.single.content, 'full reply');
  });

  test('listSessions：过滤 origin=subagent 的子代理会话', () async {
    Map<String, dynamic> item(String id, {String? origin, String? title}) => {
      'sessionId': id,
      'updatedAt': 1786000000000,
      'running': false,
      'blank': false,
      'origin': ?origin,
      'projections': {
        'values': {
          'title': ?title,
          'sessionStats': {'turns': 1, 'steps': 2},
        },
      },
    };
    final mock = MockClient(
      (req) async => http.Response(
        jsonEncode(
          okValue({
            'items': [
              item('session-user-1', title: '正常会话'),
              item('session-sub-1', origin: 'subagent', title: '子代理任务'),
              item('session-user-2', title: '另一个会话'),
              item('session-sub-2', origin: 'subagent'),
            ],
          }),
        ),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final client = clientWith(mock);
    final sessions = await client.listSessions();
    expect(sessions, hasLength(2));
    expect(sessions.map((s) => s.sessionId), isNot(contains('session-sub-1')));
    expect(sessions.map((s) => s.sessionId), isNot(contains('session-sub-2')));
    expect(
      sessions.map((s) => s.sessionId),
      containsAll(['session-user-1', 'session-user-2']),
    );
  });

  test('listSessions：解析 sessionStats 与 tokenUsage 到统计栏字段', () async {
    final mock = MockClient(
      (req) async => http.Response(
        jsonEncode(
          okValue({
            'items': [
              {
                'sessionId': 'session-stats',
                'updatedAt': 1786000000000,
                'running': false,
                'blank': false,
                'projections': {
                  'values': {
                    'sessionStats': {
                      'turns': 3,
                      'steps': 7,
                      'llmMs': 17000,
                      'toolMs': 300,
                      'ttftMs': 2500,
                      'ttftSteps': 1,
                      'decodeMs': 3000,
                      'decodeTokens': 354,
                    },
                    'tokenUsage': {
                      'uncachedInputTokens': 340,
                      'cacheReadTokens': 16260,
                      'cacheWriteTokens': 0,
                      'outputTokens': 1433,
                    },
                  },
                },
              },
            ],
          }),
        ),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final s = (await clientWith(mock).listSessions()).single;
    expect(s.turnCount, 3);
    expect(s.stepCount, 7);
    expect(s.llmMs, 17000);
    expect(s.toolMs, 300);
    expect(s.ttftMs, 2500);
    expect(s.ttftSteps, 1);
    expect(s.decodeMs, 3000);
    expect(s.decodeTokens, 354);
    expect(s.uncachedInputTokens, 340);
    expect(s.cacheReadTokens, 16260);
    expect(s.cacheWriteTokens, 0);
    expect(s.outputTokens, 1433);
    expect(s.billedInputTokens, 16600);
    expect(s.hasBilling, isTrue);
  });

  test('answerQuestion：POST /api/respond 并回显 rpcId 与答案', () async {
    late http.Request captured;
    final mock = MockClient((req) async {
      captured = req;
      return http.Response(
        jsonEncode({'accepted': true}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final client = clientWith(mock);
    await client.answerQuestion('rpc-q1', 'sess-1', [
      {
        'id': 'q1',
        'selected': ['A'],
      },
      {'id': 'q2', 'selected': <String>[], 'custom': '自由回答'},
    ]);
    expect(captured.url.toString(), 'http://test.local/api/respond');
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(body['type'], 'client-response');
    expect(body['rpcId'], 'rpc-q1');
    final value = (body['result'] as Map)['value'] as Map;
    expect(value['sessionId'], 'sess-1');
    final answers = ((value['answer'] as Map)['answers'] as List);
    expect(answers, hasLength(2));
    expect(answers[1]['custom'], '自由回答');
  });

  test('cancelQuestion：ok=false cancelled 且响应 accepted', () async {
    late http.Request captured;
    final mock = MockClient((req) async {
      captured = req;
      return http.Response(
        jsonEncode({'accepted': true}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    await clientWith(mock).cancelQuestion('rpc-q1');
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    final result = body['result'] as Map;
    expect(result['ok'], isFalse);
    expect((result['error'] as Map)['code'], 'cancelled');
  });

  test('agentEngine 设置随 JSON 往返持久化', () {
    expect(AppSettings().agentEngine, 'shiyi');
    expect(AppSettings.fromJson({}).agentEngine, 'shiyi');
    expect(AppSettings.fromJson({'agentEngine': 'dsh'}).agentEngine, 'dsh');
    final saved = AppSettings(agentEngine: 'dsh').toJson();
    expect(AppSettings.fromJson(saved).agentEngine, 'dsh');
  });

  test('主页列表缓存：DshWorkspace / DshSessionSummary JSON 往返', () {
    final ws = DshWorkspace(
      workspaceId: 'ws-1',
      path: '/agent',
      title: '默认',
      sessionIds: const ['s-1'],
      createdAt: '2026-08-16T10:00:00Z',
      updatedAt: '2026-08-16T10:01:00Z',
    );
    final restoredWs = DshWorkspace.fromJson(ws.toJson());
    expect(restoredWs.workspaceId, 'ws-1');
    expect(restoredWs.path, '/agent');
    expect(restoredWs.sessionIds, ['s-1']);

    final s = DshSessionSummary(
      sessionId: 's-1',
      title: '测试会话',
      updatedAt: 1786000000000,
      running: true,
      blank: false,
      cwd: '/agent',
      turnCount: 3,
      stepCount: 7,
      llmMs: 120,
      toolMs: 80,
      ttftMs: 300,
      ttftSteps: 2,
      decodeMs: 900,
      decodeTokens: 45,
      uncachedInputTokens: 10,
      cacheReadTokens: 20,
      cacheWriteTokens: 5,
      outputTokens: 45,
    );
    final restored = DshSessionSummary.fromJson(s.toJson());
    expect(restored.sessionId, 's-1');
    expect(restored.title, '测试会话');
    expect(restored.updatedAt, 1786000000000);
    expect(restored.running, true);
    expect(restored.turnCount, 3);
    expect(restored.stepCount, 7);
    expect(restored.ttftMs, 300);
    expect(restored.decodeTokens, 45);
    expect(restored.uncachedInputTokens, 10);
    expect(restored.cacheReadTokens, 20);
    expect(restored.outputTokens, 45);
  });

  test('会话历史缓存：ChatMessage toMap/fromMap 往返保留消息', () {
    final msg = ChatMessage(
      id: 'm-1',
      sessionId: 's-1',
      role: 'assistant',
      content: '你好',
      reasoning: '思考',
      toolCalls: [
        ToolCall(id: 't-1', name: 'fs_read', arguments: '{"path":"/a"}'),
      ],
      createdAt: 1786000000000,
      streaming: true,
      runtimeContext: '上下文',
    );
    final restored = ChatMessage.fromMap(msg.toMap());
    expect(restored.id, 'm-1');
    expect(restored.sessionId, 's-1');
    expect(restored.role, 'assistant');
    expect(restored.content, '你好');
    expect(restored.reasoning, '思考');
    expect(restored.toolCalls.single.name, 'fs_read');
    expect(restored.toolCalls.single.arguments, '{"path":"/a"}');
    expect(restored.createdAt, 1786000000000);
  });

  test('history：inbox 回滚 + turn/end 错误时保留用户消息并露出失败原因', () async {
    final mock = MockClient(
      (req) async => http.Response(
        jsonEncode(
          okValue({
            'events': [
              {
                'event': event('agent/inbox/spliced', 0, {
                  'target': 'next-turn',
                  'start': 0,
                  'inserted': [
                    {
                      'content': [
                        {'type': 'text', 'text': 'hi'},
                      ],
                      'role': 'user',
                      'id': 'u1',
                    },
                  ],
                }),
              },
              {
                'event': event('agent/inbox/spliced', 2, {
                  'target': 'next-turn',
                  'start': 0,
                  'removedCount': 1,
                  'inserted': [],
                }),
              },
              {
                'event': event('turn/end', 3, {
                  'turn': 1,
                  'reason': {
                    'kind': 'error',
                    'error': {
                      'message':
                          'EACCES: permission denied, link tmp -> session.jsonl.zstd',
                      'code': 'UNKNOWN',
                    },
                  },
                }),
              },
            ],
          }),
        ),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final client = clientWith(mock);
    final msgs = await client.history('session-test');
    expect(msgs, hasLength(2));
    expect(msgs.first.role, 'user');
    expect(msgs.first.content, 'hi');
    expect(msgs.last.role, 'assistant');
    expect(msgs.last.content, contains('EACCES'));
  });

  test('mutateSettings：POST /api/settings.mutate，带 ns 与 ops', () async {
    late http.Request captured;
    final mock = MockClient((req) async {
      captured = req;
      return http.Response(
        jsonEncode(okValue({})),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final client = clientWith(mock);
    await client.mutateSettings('llm-pi-ai', [
      {
        'op': 'set',
        'path': ['providers', 'shiyi'],
        'value': {'api': 'openai-completions'},
      },
    ]);
    expect(captured.url.toString(), 'http://test.local/api/settings.mutate');
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(body['method'], 'settings.mutate');
    final payload = body['payload'] as Map<String, dynamic>;
    expect(payload['ns'], 'llm-pi-ai');
    expect(payload['ops'], isA<List>());
    expect((payload['ops'] as List).first['path'], ['providers', 'shiyi']);
  });

  test('credentials.set：payload 用 ref 字符串，不用 path 数组', () async {
    late http.Request captured;
    final mock = MockClient((req) async {
      captured = req;
      return http.Response(
        jsonEncode(okValue({})),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    await clientWith(mock).setCredential('SHIYI_API_KEY', 'sk-test');
    expect(captured.url.toString(), 'http://test.local/api/credentials.set');
    final payload =
        (jsonDecode(captured.body) as Map<String, dynamic>)['payload']
            as Map<String, dynamic>;
    expect(payload['ref'], 'SHIYI_API_KEY');
    expect(payload['value'], 'sk-test');
    expect(payload.containsKey('path'), isFalse);
  });

  test('credentials.unset：payload 用 ref 字符串', () async {
    late http.Request captured;
    final mock = MockClient((req) async {
      captured = req;
      return http.Response(
        jsonEncode(okValue({})),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    await clientWith(mock).unsetCredential('SHIYI_API_KEY');
    final payload =
        (jsonDecode(captured.body) as Map<String, dynamic>)['payload']
            as Map<String, dynamic>;
    expect(payload['ref'], 'SHIYI_API_KEY');
    expect(payload.containsKey('path'), isFalse);
  });

  test('credentials.describe：解析 credentials 映射，并查询已知 refs', () async {
    late http.Request captured;
    final mock = MockClient((req) async {
      captured = req;
      return http.Response(
        jsonEncode(
          okValue({
            'credentials': {
              'SHIYI_API_KEY': {'configured': true, 'writable': true},
              'DEEPSEEK_API_KEY': {'configured': false, 'writable': true},
            },
          }),
        ),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final slots = await clientWith(mock).describeCredentials();
    final payload =
        (jsonDecode(captured.body) as Map<String, dynamic>)['payload']
            as Map<String, dynamic>;
    expect(payload['refs'], [
      'SHIYI_API_KEY',
      'SHIYI_DSH_SEARCH_KEY',
      'DEEPSEEK_API_KEY',
    ]);
    expect(slots.map((e) => e.ref), ['SHIYI_API_KEY', 'DEEPSEEK_API_KEY']);
    expect(slots.first.set, isTrue);
    expect(slots.last.set, isFalse);
  });

  test('history：DSH runtime-context 快照挂到下一条真实消息，不单独成气泡', () async {
    const snap =
        'Current runtime context. This snapshot supersedes earlier '
        'runtime-context snapshots.\n\nCurrent DSH file policy: workspace-write. '
        'Any available operation enforced by the DSH file sandbox may modify files '
        'under the session workspace: "/storage/emulated/0/agent".';
    expect(DshApiClient.isInjectedRuntimeContext(snap), isTrue);
    expect(DshApiClient.isInjectedRuntimeContext('hi'), isFalse);

    final mock = MockClient(
      (req) async => http.Response(
        jsonEncode(
          okValue({
            'events': [
              {
                'event': event('user/message', 1, {
                  'content': [
                    {'type': 'text', 'text': snap},
                  ],
                  'role': 'user',
                  'id': 'ctx-1',
                }),
              },
              {
                'event': event('user/message', 2, {
                  'content': [
                    {'type': 'text', 'text': 'hi'},
                  ],
                  'role': 'user',
                  'id': 'msg-user-2',
                }),
              },
            ],
          }),
        ),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final msgs = await clientWith(mock).history('session-test');
    expect(msgs, hasLength(1));
    expect(msgs.single.content, 'hi');
    expect(msgs.single.role, 'user');
    expect(msgs.single.runtimeContext, contains('Current runtime context'));
    expect(msgs.single.runtimeContext, contains('Current DSH file policy:'));
  });

  test('history：只有 runtime-context 时不单独成气泡', () async {
    const snap =
        'Current runtime context. This snapshot supersedes earlier '
        'runtime-context snapshots.\n\nCurrent DSH file policy: workspace-write.';
    final mock = MockClient(
      (req) async => http.Response(
        jsonEncode(
          okValue({
            'events': [
              {
                'event': event('user/message', 1, {
                  'content': [
                    {'type': 'text', 'text': snap},
                  ],
                  'role': 'user',
                  'id': 'ctx-only',
                }),
              },
            ],
          }),
        ),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final msgs = await clientWith(mock).history('session-test');
    expect(msgs, isEmpty);
  });

  test('history：skill 目录注入折叠挂到相邻气泡，不单独成气泡', () async {
    const catalog =
        '<system-reminder>\n'
        'A skill is a reusable set of task-specific instructions. '
        'The following skills are available in this session:\n'
        '\n'
        '<available_skills>\n'
        '- `cordis-plugin-development`: Create, modify, debug dynamic Cordis Plugins.\n'
        '- `editing-cordis-compositions`: Use when creating a Cordis composition.\n'
        '</available_skills>\n'
        'If the user names a skill, call the `skill` tool with the exact skill name.\n'
        '</system-reminder>';
    expect(DshApiClient.isInjectedSkillCatalog(catalog), isTrue);
    expect(DshApiClient.isInjectedSkillCatalog('hi'), isFalse);

    final mock = MockClient(
      (req) async => http.Response(
        jsonEncode(
          okValue({
            'events': [
              {
                'event': event('user/message', 1, {
                  'content': [
                    {'type': 'text', 'text': catalog},
                  ],
                  'role': 'user',
                  'id': 'catalog-1',
                }),
              },
              {
                'event': event('user/message', 2, {
                  'content': [
                    {'type': 'text', 'text': '帮我写个插件'},
                  ],
                  'role': 'user',
                  'id': 'msg-user-2',
                }),
              },
              {
                'event': event('user/message', 3, {
                  'content': [
                    {'type': 'text', 'text': catalog},
                  ],
                  'role': 'user',
                  'id': 'catalog-2',
                }),
              },
              {
                'event': event('assistant/message', 4, {
                  'message': {
                    'content': [
                      {'type': 'text', 'text': '好的，你想做什么？'},
                    ],
                  },
                  'id': 'asst-1',
                }),
              },
            ],
          }),
        ),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final msgs = await clientWith(mock).history('session-test');
    expect(msgs, hasLength(2));
    expect(msgs[0].content, '帮我写个插件');
    expect(msgs[0].role, 'user');
    expect(msgs[0].runtimeContext, contains('A skill is a reusable set'));
    expect(msgs[1].content, '好的，你想做什么？');
    expect(msgs[1].role, 'assistant');
  });

  test('history：skill 目录注入在 splice 插入里也折叠挂载', () async {
    const catalog =
        '<system-reminder>\n'
        'A skill is a reusable set of task-specific instructions.\n'
        '<available_skills>\n- `x`: y\n</available_skills>\n'
        '</system-reminder>';
    final mock = MockClient(
      (req) async => http.Response(
        jsonEncode(
          okValue({
            'events': [
              {
                'event': event('agent/inbox/spliced', 1, {
                  'removedCount': 0,
                  'inserted': [
                    {
                      'content': [
                        {'type': 'text', 'text': catalog},
                      ],
                      'role': 'user',
                      'id': 'splice-catalog',
                    },
                    {
                      'content': [
                        {'type': 'text', 'text': '继续'},
                      ],
                      'role': 'user',
                      'id': 'splice-real',
                    },
                  ],
                }),
              },
            ],
          }),
        ),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final msgs = await clientWith(mock).history('session-test');
    expect(msgs, hasLength(1));
    expect(msgs.single.content, '继续');
    expect(msgs.single.runtimeContext, contains('A skill is a reusable set'));
  });

  test('history：子代理 settled 通知显示为左侧助手消息并带标记', () async {
    final mock = MockClient(
      (req) async => http.Response(
        jsonEncode(
          okValue({
            'events': [
              {
                'event': event('agent/inbox/spliced', 1, {
                  'removedCount': 0,
                  'inserted': [
                    {
                      'content': [
                        {'type': 'text', 'text': 'SUBAGENT_OK'},
                      ],
                      'role': 'user',
                      'id': 'subagent-result',
                      'source': {
                        'kind': 'subagent-settled',
                        'senderSessionId': 'child-1',
                      },
                    },
                  ],
                }),
              },
            ],
          }),
        ),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final msgs = await clientWith(mock).history('session-test');
    expect(msgs, hasLength(1));
    expect(msgs.single.role, 'assistant');
    expect(msgs.single.content, '<子代理返回信息>\nSUBAGENT_OK');
  });

  test('subagent.history：用户来源提示词显示为左侧折叠消息，主会话不变', () async {
    final mock = MockClient(
      (req) async => http.Response(
        jsonEncode(
          okValue({
            'events': [
              {
                'event': event('user/message', 1, {
                  'content': [
                    {'type': 'text', 'text': '请只读检查这些文件'},
                  ],
                  'source': {'kind': 'user'},
                  'role': 'user',
                  'id': 'subagent-prompt',
                }),
              },
            ],
          }),
        ),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final client = clientWith(mock);

    final mainMessages = await client.history('session-main');
    expect(mainMessages.single.role, 'user');
    expect(mainMessages.single.content, '请只读检查这些文件');

    final childMessages = await client.subagentHistory(
      'session-main',
      'session-child',
      mode: 'continuable',
    );
    expect(childMessages.single.role, 'assistant');
    expect(childMessages.single.content, '<子代理提示词注入>\n请只读检查这些文件');
  });

  test('history：子代理返回后的主模型总结显示为左侧折叠消息', () async {
    final mock = MockClient(
      (req) async => http.Response(
        jsonEncode(
          okValue({
            'events': [
              {
                'event': event('user/message', 1, {
                  'content': [
                    {'type': 'text', 'text': 'SUBAGENT_OK'},
                  ],
                  'source': {
                    'kind': 'subagent-report',
                    'senderSessionId': 'child-1',
                  },
                  'role': 'user',
                  'id': 'subagent-report',
                }),
              },
              {
                'event': event('assistant/message', 2, {
                  'message': {
                    'content': [
                      {'type': 'text', 'text': '两个子代理均已完成。'},
                    ],
                  },
                }),
              },
            ],
          }),
        ),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );

    final msgs = await clientWith(mock).history('session-test');
    expect(msgs, hasLength(2));
    expect(msgs.first.content, '<子代理返回信息>\nSUBAGENT_OK');
    expect(msgs.last.role, 'assistant');
    expect(msgs.last.content, '两个子代理均已完成。');
    expect(msgs.last.subagentSummary, '');
  });

  test('history：子代理返回后的 reasoning 单独折叠，正文正常显示', () async {
    final mock = MockClient(
      (req) async => http.Response(
        jsonEncode(
          okValue({
            'events': [
              {
                'event': event('user/message', 1, {
                  'content': [
                    {'type': 'text', 'text': 'SUBAGENT_OK'},
                  ],
                  'source': {
                    'kind': 'subagent-report',
                    'senderSessionId': 'child-1',
                  },
                  'role': 'user',
                  'id': 'subagent-report',
                }),
              },
              {
                'event': event('assistant/message', 2, {
                  'message': {
                    'content': [
                      {'type': 'reasoning', 'text': '模型内部总结'},
                      {'type': 'text', 'text': '展示给用户的主模型正文'},
                    ],
                  },
                }),
              },
            ],
          }),
        ),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );

    final msgs = await clientWith(mock).history('session-test');
    expect(msgs, hasLength(2));
    expect(msgs.last.subagentSummary, '模型内部总结');
    expect(msgs.last.reasoning, '');
    expect(msgs.last.content, '展示给用户的主模型正文');
  });

  test('history：splice 子代理通知转正式消息时不重复', () async {
    Map<String, dynamic> resultMessage() => {
      'content': [
        {'type': 'text', 'text': 'SUBAGENT_OK'},
      ],
      'source': {'kind': 'subagent-settled', 'senderSessionId': 'child-1'},
      'role': 'user',
      'id': 'subagent-result',
    };
    final mock = MockClient(
      (req) async => http.Response(
        jsonEncode(
          okValue({
            'events': [
              {
                'event': event('agent/inbox/spliced', 1, {
                  'removedCount': 0,
                  'inserted': [resultMessage()],
                }),
              },
              {
                'event': event('agent/inbox/spliced', 2, {
                  'removedCount': 1,
                  'inserted': const [],
                }),
              },
              {'event': event('user/message', 3, resultMessage())},
            ],
          }),
        ),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );

    final msgs = await clientWith(mock).history('session-test');
    expect(msgs, hasLength(1));
    expect(msgs.single.content, '<子代理返回信息>\nSUBAGENT_OK');
  });

  test('history：已消费的子代理报告重放时不再触发重复助手回复', () async {
    Map<String, dynamic> resultMessage() => {
      'content': [
        {'type': 'text', 'text': 'SUBAGENT_OK'},
      ],
      'source': {'kind': 'subagent-report', 'senderSessionId': 'child-1'},
      'role': 'user',
      'id': 'subagent-result',
    };
    final mock = MockClient(
      (req) async => http.Response(
        jsonEncode(
          okValue({
            'events': [
              {
                'event': event('agent/inbox/spliced', 1, {
                  'removedCount': 0,
                  'inserted': [resultMessage()],
                }),
              },
              {
                'event': event('assistant/message', 2, {
                  'message': {
                    'content': [
                      {'type': 'text', 'text': '已汇总。'},
                    ],
                  },
                }),
              },
              // DSH 将同一条 inbox 报告再次物化为 user/message。
              {'event': event('user/message', 3, resultMessage())},
              {
                'event': event('assistant/message', 4, {
                  'message': {
                    'content': [
                      {'type': 'text', 'text': '重复确认。'},
                    ],
                  },
                }),
              },
            ],
          }),
        ),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );

    final msgs = await clientWith(mock).history('session-test');
    expect(msgs, hasLength(2));
    expect(msgs.first.content, '<子代理返回信息>\nSUBAGENT_OK');
    expect(msgs.last.content, '已汇总。');
  });

  test('historyBundle：提取上游真实 responseModel', () async {
    final mock = MockClient(
      (req) async => http.Response(
        jsonEncode(
          okValue({
            'events': [
              {
                'event': event('assistant/message', 1, {
                  'message': {
                    'content': [
                      {'type': 'text', 'text': '完成'},
                    ],
                    'source': {
                      'replayState': {'responseModel': 'deepseek-v4-flash'},
                    },
                  },
                }),
              },
            ],
          }),
        ),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final bundle = await clientWith(mock).historyBundle('session-test');
    expect(bundle.responseModels, {'deepseek-v4-flash'});
  });

  test('historyBundle：最新用户回合收到 turn/end 后才标记结束', () async {
    var includeTurnEnd = false;
    final mock = MockClient(
      (req) async => http.Response(
        jsonEncode(
          okValue({
            'events': [
              {
                'event': event('user/message', 1, {
                  'content': [
                    {'type': 'text', 'text': '开始'},
                  ],
                  'role': 'user',
                  'id': 'u1',
                }),
              },
              {
                'event': event('assistant/message', 2, {
                  'message': {
                    'content': [
                      {'type': 'text', 'text': '处理中'},
                    ],
                  },
                }),
              },
              if (includeTurnEnd)
                {
                  'event': event('turn/end', 3, {
                    'reason': {'kind': 'completed'},
                  }),
                },
            ],
          }),
        ),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final client = clientWith(mock);

    expect((await client.historyBundle('session-test')).turnEnded, isFalse);
    includeTurnEnd = true;
    expect((await client.historyBundle('session-test')).turnEnded, isTrue);
  });

  test('skill.list：携带会话并解析官方技能字段', () async {
    late Map<String, dynamic> payload;
    final mock = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      payload = (body['payload'] as Map).cast<String, dynamic>();
      return http.Response(
        jsonEncode(
          okValue({
            'skills': [
              {
                'name': 'write-tests',
                'description': '补充回归测试',
                'whenToUse': '修改核心行为后',
                'modelInvocable': true,
              },
              {
                'name': 'manual-only',
                'description': '只允许手动调用',
                'modelInvocable': false,
              },
              {'name': '', 'description': '无效条目'},
            ],
          }),
        ),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final skills = await clientWith(mock).listSkills(sessionId: ' session-1 ');

    expect(payload, {'sessionId': 'session-1'});
    expect(skills.map((e) => e.name), ['manual-only', 'write-tests']);
    expect(skills.first.modelInvocable, isFalse);
    expect(skills.last.description, '补充回归测试');
    expect(skills.last.whenToUse, '修改核心行为后');
    await expectLater(
      clientWith(mock).listSkills(sessionId: '  '),
      throwsA(isA<DshApiException>()),
    );
  });

  test('skill.list：冷会话失败时不再回退到空 payload', () async {
    var calls = 0;
    final mock = MockClient((req) async {
      calls++;
      return http.Response(
        jsonEncode(errValue('session-not-found', 'session not attached')),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    await expectLater(
      clientWith(mock).listSkills(sessionId: 'cold-session'),
      throwsA(
        isA<DshApiException>().having(
          (e) => e.code,
          'code',
          'session-not-found',
        ),
      ),
    );
    expect(calls, 1);
  });

  test('host.listDirectory：可读取宿主 home，官方目录条目默认为文件夹', () async {
    late Map<String, dynamic> payload;
    final mock = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      payload = (body['payload'] as Map).cast<String, dynamic>();
      return http.Response(
        jsonEncode(
          okValue({
            'home': '/root',
            'path': '/root/.dsh/skills',
            'entries': [
              {
                'name': 'global-skill',
                'path': '/root/.dsh/skills/global-skill',
                'hidden': false,
              },
            ],
            'crumbs': const [],
            'truncated': false,
          }),
        ),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final client = clientWith(mock);

    expect(await client.hostHome(), '/root');
    expect(payload, isEmpty);
    final entries = await client.listDirectory('/root/.dsh/skills');
    expect(entries.single.name, 'global-skill');
    expect(entries.single.isDirectory, isTrue);
  });

  test('subagent.list：按官方 id/label/activity 条目解析', () async {
    final mock = MockClient(
      (req) async => http.Response(
        jsonEncode(
          okValue({
            'entries': [
              {
                'kind': 'child',
                'id': 'sub-1',
                'mode': 'continuable',
                'activity': 'running',
                'hasChildren': false,
                'label': '审查代码',
              },
              {
                'kind': 'child',
                'id': 'sub-2',
                'mode': 'one-shot',
                'activity': 'inactive',
                'hasChildren': true,
              },
            ],
            'parentAvailable': true,
          }),
        ),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final r = await clientWith(mock).listSubagents('parent');
    expect(r.parentAvailable, isTrue);
    expect(r.entries, hasLength(2));
    expect(r.entries.first.sessionId, 'sub-1');
    expect(r.entries.first.title, '审查代码');
    expect(r.entries.first.running, isTrue);
    expect(r.entries.first.mode, 'continuable');
    expect(r.entries.last.running, isFalse);
    expect(r.entries.last.mode, 'one-shot');
    expect(r.entries.first.hasChildren, isFalse);
    expect(r.entries.last.hasChildren, isTrue);
    expect(r.entries.last.kind, 'child');
  });

  test('subagent.history bundle：mode 透传 + live token + 投影统计', () async {
    late Map<String, dynamic> historyPayload;
    final mock = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      historyPayload = (body['payload'] as Map).cast<String, dynamic>();
      return http.Response(
        jsonEncode(
          okValue({
            'events': [
              {
                'event': event('user/message', 1, {
                  'content': [
                    {'type': 'text', 'text': '继续'},
                  ],
                  'role': 'user',
                  'id': 'msg-u1',
                }),
              },
              {
                'event': event('assistant/chunk', 2, {
                  'turn': 1,
                  'step': 1,
                  'chunk': {
                    'type': 'reasoning-delta',
                    'index': 0,
                    'text': '正在',
                  },
                }),
              },
              {
                'event': event('assistant/chunk', 3, {
                  'turn': 1,
                  'step': 1,
                  'chunk': {'type': 'text-delta', 'index': 0, 'text': '好的'},
                }),
              },
            ],
            'hasMore': false,
            'projections': {
              'values': {
                'sessionStats': {
                  'turns': 2,
                  'steps': 3,
                  'llmMs': 1200,
                  'toolMs': 400,
                },
                'tokenUsage': {
                  'uncachedInputTokens': 100,
                  'cacheReadTokens': 900,
                  'cacheWriteTokens': 0,
                  'outputTokens': 50,
                },
              },
            },
          }),
        ),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final client = clientWith(mock);
    final bundle = await client.subagentHistoryBundle(
      'parent',
      'child',
      mode: 'continuable',
    );
    expect(historyPayload['parentSessionId'], 'parent');
    expect(historyPayload['childSessionId'], 'child');
    expect(historyPayload['mode'], 'continuable');
    expect(bundle.messages, hasLength(1));
    expect(bundle.messages.first.content, '继续');
    expect(bundle.live.text, '好的');
    expect(bundle.live.reasoning, '正在');
    expect(bundle.live.open, isTrue);
    expect(bundle.summary, isNotNull);
    expect(bundle.summary!.turnCount, 2);
    expect(bundle.summary!.stepCount, 3);
    expect(bundle.summary!.llmMs, 1200);
    expect(bundle.summary!.cacheReadTokens, 900);
  });

  test('subagent.prompt / interrupt：continuable 地址与 mode 正确', () async {
    final methods = <String>[];
    late Map<String, dynamic> promptPayload;
    final mock = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      methods.add(body['method'] as String);
      if (body['method'] == 'subagent.prompt') {
        promptPayload = (body['payload'] as Map).cast<String, dynamic>();
        return http.Response(
          jsonEncode(okValue({'messageId': 'm1'})),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode(okValue({'accepted': true})),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final client = clientWith(mock);
    await client.subagentPrompt('parent', 'child', '继续');
    await client.subagentInterrupt('parent', 'child');
    expect(methods, ['subagent.prompt', 'subagent.interrupt']);
    expect(promptPayload['parentSessionId'], 'parent');
    expect(promptPayload['childSessionId'], 'child');
    expect(promptPayload['mode'], 'continuable');
    expect(promptPayload['content'], [
      {'type': 'text', 'text': '继续'},
    ]);
  });

  test('listPresets：解析 isDefault / name / broken 字段', () async {
    final mock = MockClient(
      (req) async => http.Response(
        jsonEncode(
          okValue({
            'presets': [
              {
                'id': 'standard',
                'trust': 'system',
                'isDefault': true,
                'name': '标准模式',
                'description': '标准工具集',
              },
              {
                'id': 'broken-yaml',
                'trust': 'user',
                'isDefault': false,
                'broken': 'not valid YAML',
              },
            ],
            'authorable': true,
          }),
        ),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final r = await clientWith(mock).listPresets();
    expect(r.authorable, isTrue);
    expect(r.presets, hasLength(2));
    expect(r.presets.first.id, 'standard');
    expect(r.presets.first.isDefault, isTrue);
    expect(r.presets.first.name, '标准模式');
    expect(r.presets.first.broken, isNull);
    expect(r.presets.last.broken, 'not valid YAML');
  });

  test('setDefaultPreset：settings.update 写 agent-presets.default', () async {
    late http.Request captured;
    final mock = MockClient((req) async {
      captured = req;
      return http.Response(
        jsonEncode(okValue({})),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    await clientWith(mock).setDefaultPreset('minimal');
    expect(captured.url.toString(), 'http://test.local/api/settings.update');
    final payload =
        (jsonDecode(captured.body) as Map<String, dynamic>)['payload']
            as Map<String, dynamic>;
    expect(payload['ns'], 'agent-presets');
    expect(payload['patch'], {'default': 'minimal'});
    expect(payload.containsKey('expectedRevision'), isFalse);
  });

  test('moveSessionToWorkspace：POST /__shiyi/move-session', () async {
    late http.Request captured;
    final mock = MockClient((req) async {
      captured = req;
      return http.Response(
        jsonEncode({'ok': true, 'moved': true, 'sessionId': 'session-1'}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final result = await clientWith(mock).moveSessionToWorkspace(
      sessionId: 'session-1',
      workspaceId: 'ws-2',
      workspacePath: '/storage/emulated/0/docs',
    );
    expect(result['moved'], true);
    expect(captured.url.toString(), 'http://test.local/__shiyi/move-session');
    expect(captured.method, 'POST');
    expect(jsonDecode(captured.body), {
      'sessionId': 'session-1',
      'workspaceId': 'ws-2',
      'workspacePath': '/storage/emulated/0/docs',
    });
  });

  test('moveSessionToWorkspace：404 视为插件未加载', () async {
    final mock = MockClient((req) async => http.Response('not found', 404));
    try {
      await clientWith(
        mock,
      ).moveSessionToWorkspace(sessionId: 'session-1', workspaceId: 'ws-2');
      fail('should throw');
    } on DshApiException catch (e) {
      expect(e.code, 'plugin-missing');
    }
  });

  test('insertWorkspaceBefore：before 为 null 时省略锚点（挪到末尾）', () async {
    late http.Request captured;
    final mock = MockClient((req) async {
      captured = req;
      return http.Response(
        jsonEncode(
          okValue({
            'workspaceIds': ['ws-2', 'ws-1'],
          }),
        ),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final ids = await clientWith(mock).insertWorkspaceBefore('ws-1');
    expect(ids, ['ws-2', 'ws-1']);
    expect(
      captured.url.toString(),
      'http://test.local/api/workspace.insertBefore',
    );
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(body['method'], 'workspace.insertBefore');
    expect(body['payload'], {'workspaceId': 'ws-1'});
  });

  test('insertWorkspaceBefore：带锚点时写入 beforeWorkspaceId', () async {
    late http.Request captured;
    final mock = MockClient((req) async {
      captured = req;
      return http.Response(
        jsonEncode(
          okValue({
            'workspaceIds': ['ws-1', 'ws-2'],
          }),
        ),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    await clientWith(
      mock,
    ).insertWorkspaceBefore('ws-1', beforeWorkspaceId: 'ws-2');
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(body['payload'], {
      'workspaceId': 'ws-1',
      'beforeWorkspaceId': 'ws-2',
    });
  });

  test('createSession：带 workspaceId 时不写 cwd', () async {
    late http.Request captured;
    final mock = MockClient((req) async {
      captured = req;
      return http.Response(
        jsonEncode(okValue({'sessionId': 'sess-ws'})),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final id = await clientWith(
      mock,
    ).createSession(cwd: '/storage/emulated/0/docs', workspaceId: 'ws-1');
    expect(id, 'sess-ws');
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(body['method'], 'session.create');
    expect(body['payload'], {'workspaceId': 'ws-1'});
  });

  test('createSession：带 sessionId 时复用已有会话（唤醒挂载）', () async {
    late http.Request captured;
    final mock = MockClient((req) async {
      captured = req;
      return http.Response(
        jsonEncode(okValue({'sessionId': 'session-cold'})),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final id = await clientWith(mock).createSession(
      cwd: '/storage/emulated/0/agent',
      sessionId: ' session-cold ',
    );
    expect(id, 'session-cold');
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(body['method'], 'session.create');
    expect(body['payload'], {
      'cwd': '/storage/emulated/0/agent',
      'sessionId': 'session-cold',
    });
  });

  test('selectModel：默认省略 effort，显式档位原样发送', () async {
    final payloads = <Map<String, dynamic>>[];
    final mock = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final payload = (body['payload'] as Map).cast<String, dynamic>();
      payloads.add(payload);
      return http.Response(
        jsonEncode(
          okValue({
            'selected': {
              'provider': payload['provider'],
              'model': payload['model'],
              if (payload.containsKey('reasoningEffort'))
                'reasoningEffort': payload['reasoningEffort'],
            },
          }),
        ),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final client = clientWith(mock);

    await client.selectModel('s1', 'provider', 'model');
    await client.selectModel('s1', 'provider', 'model', reasoningEffort: '');
    for (final effort in ['off', 'low', 'high', 'max']) {
      await client.selectModel(
        's1',
        'provider',
        'model',
        reasoningEffort: effort,
      );
    }

    expect(payloads[0].containsKey('reasoningEffort'), isFalse);
    expect(payloads[1].containsKey('reasoningEffort'), isFalse);
    expect(payloads.skip(2).map((payload) => payload['reasoningEffort']), [
      'off',
      'low',
      'high',
      'max',
    ]);
  });

  test('compactSession：调用官方 commands/execute 并解析成功结果', () async {
    late http.Request captured;
    final mock = MockClient((req) async {
      captured = req;
      return http.Response(
        jsonEncode(
          okValue({
            'commandId': 'cmd-1',
            'result': {
              'kind': 'success',
              'text': 'Compacted 12 history items.',
              'sourceEventSeq': 42,
            },
          }),
        ),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final execution = await clientWith(mock).compactSession('session-1');
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(captured.url.toString(), 'http://test.local/api/commands/execute');
    expect(body['method'], 'commands/execute');
    expect(body['payload'], {
      'args': {'agentId': 'session-1', 'line': '/compact'},
    });
    expect(execution.ok, isTrue);
    expect(execution.commandId, 'cmd-1');
    expect(execution.result, 'Compacted 12 history items.');
    expect(execution.sourceEventSeq, 42);
    expect(execution.error, isNull);
  });

  test('commands/execute：解析命令级错误而不是误报成功', () async {
    final mock = MockClient(
      (req) async => http.Response(
        jsonEncode(
          okValue({
            'commandId': 'cmd-2',
            'result': {'kind': 'error', 'text': 'agent is busy'},
          }),
        ),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );

    final execution = await clientWith(
      mock,
    ).executeCommand(sessionId: 'session-1', line: '/compact');
    expect(execution.ok, isFalse);
    expect(execution.error, 'agent is busy');
    expect(execution.result, isNull);
  });

  test('history：surface replace 用 checkpoint 替换旧 transcript', () async {
    Map<String, dynamic> surfaced(
      String type,
      int seq,
      Map<String, dynamic> data,
      Object surfaceOp,
    ) => {...event(type, seq, data), 'surfaceOp': surfaceOp};

    final mock = MockClient(
      (req) async => http.Response(
        jsonEncode(
          okValue({
            'events': [
              {
                'event': surfaced('user/message', 1, {
                  'id': 'old-user',
                  'role': 'user',
                  'content': [
                    {'type': 'text', 'text': '旧问题'},
                  ],
                }, 'append'),
              },
              {
                'event': surfaced('assistant/message', 2, {
                  'message': {
                    'role': 'assistant',
                    'content': [
                      {'type': 'text', 'text': '旧回答'},
                    ],
                  },
                }, 'append'),
              },
              {
                'event': event('tool/call', 3, {
                  'callId': 'old-call',
                  'name': 'old_tool',
                  'arguments': '{}',
                }),
              },
              {
                'event': surfaced('user/message', 4, {
                  'id': 'old-user-2',
                  'role': 'user',
                  'content': [
                    {'type': 'text', 'text': '旧追问'},
                  ],
                }, 'append'),
              },
              {
                'event': surfaced('assistant/message', 5, {
                  'message': {
                    'role': 'assistant',
                    'content': [
                      {'type': 'text', 'text': '旧追答'},
                    ],
                  },
                }, 'append'),
              },
              {
                'event': surfaced(
                  'user/message',
                  6,
                  {
                    'id': 'compact-checkpoint',
                    'role': 'user',
                    'content': [
                      {'type': 'text', 'text': '压缩摘要'},
                    ],
                  },
                  {'op': 'replace', 'start': 1, 'end': 5},
                ),
              },
              {
                'event': surfaced('user/message', 7, {
                  'id': 'new-user',
                  'role': 'user',
                  'content': [
                    {'type': 'text', 'text': '压缩后问题'},
                  ],
                }, 'append'),
              },
              {
                'event': surfaced('assistant/message', 8, {
                  'message': {
                    'role': 'assistant',
                    'content': [
                      {'type': 'text', 'text': '压缩后回答'},
                    ],
                  },
                }, 'append'),
              },
            ],
          }),
        ),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );

    final messages = await clientWith(mock).history('session-compact');
    expect(messages.map((message) => message.content), [
      '压缩摘要',
      '压缩后问题',
      '压缩后回答',
    ]);
    expect(messages.expand((message) => message.toolCalls), isEmpty);
  });
}
