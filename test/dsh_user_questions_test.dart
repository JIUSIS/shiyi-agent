import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shiyi_agent_app/services/dsh_api.dart';

/// rc.2 官方提问应答是 `userQuestions/answer(agentId, callId, {answers})` —— 纯
/// HTTP，局域网（WS 被转发层挡）也答得通；旧路径 `$events/result` 依赖那条 WS、
/// `POST /api/respond` 在 rc.2 已不存在。见 docs/fix-log.md #398。
void main() {
  test('answerQuestion 走 userQuestions/answer，参数与 schema 对齐', () async {
    late http.Request captured;
    final client = DshApiClient(
      baseUrl: 'http://test.local',
      client: MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode({
            'type': 'server-response',
            'rpcId': 'x',
            'result': {
              'ok': true,
              'value': true,
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    await client.answerQuestion('rpc-1', 'session-1', [
      {
        'id': 'q1',
        'selected': ['选项A'],
      },
      {
        'id': 'q2',
        'selected': <String>[],
        'custom': '自己填的',
      },
    ], callId: 'call-9');

    expect(captured.url.path, contains('userQuestions/answer'));
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    final args =
        ((body['payload'] as Map)['args'] as Map).cast<String, dynamic>();
    expect(args['agentId'], 'session-1');
    expect(args['callId'], 'call-9');
    final answer = (args['answer'] as Map).cast<String, dynamic>();
    final answers = (answer['answers'] as List).cast<Map>();
    expect(answers, hasLength(2));
    expect(answers.first['id'], 'q1');
    expect(answers.first['selected'], ['选项A']);
    expect(answers.last['custom'], '自己填的');
  });

  test('没有 callId 时退回 rpcId', () async {
    late http.Request captured;
    final client = DshApiClient(
      baseUrl: 'http://test.local',
      client: MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode({
            'type': 'server-response',
            'rpcId': 'x',
            'result': {
              'ok': true,
              'value': true,
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    await client.answerQuestion('rpc-fallback', 'session-1', [
      {'id': 'q1', 'selected': ['A']},
    ]);
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    final args =
        ((body['payload'] as Map)['args'] as Map).cast<String, dynamic>();
    expect(args['callId'], 'rpc-fallback');
  });
}
