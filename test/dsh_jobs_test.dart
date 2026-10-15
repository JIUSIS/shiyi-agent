import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shiyi_agent_app/services/dsh_api.dart';

/// 后台任务：`job/list({sessionId})` → `{type:'rows', jobs:[…]}`；
/// `job/kill({sessionId, jobId})` → `{outcome}`。见 docs/dsh-parity.md。
void main() {
  Map<String, dynamic> okValue(dynamic value) => {
    'type': 'server-response',
    'rpcId': 'x',
    'result': {'ok': true, 'value': value},
  };

  test('listJobs 是 stream 端点：不当 unary POST 打（#403）', () async {
    // 目标里 `job/list` 的 mode 是 stream，必须走 WS mux：
    // 当 unary POST 打会被网关拒（gateway/signature-invalid）。
    // 这里没有 WS 可用，所以不应该发出 /api/job/list 的 HTTP 请求。
    var httpCalls = 0;
    final client = DshApiClient(
      baseUrl: 'http://test.local',
      client: MockClient((req) async {
        httpCalls++;
        return http.Response(
          jsonEncode(okValue({'type': 'rows', 'jobs': const []})),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    await client.listJobs('session-1').catchError((_) => <DshJobInfo>[]);
    expect(httpCalls, 0);
  });

  test('行解析：running / finished（DshJobInfo.fromJson）', () {
    final running = DshJobInfo.fromJson({
      'id': 'job-1',
      'kind': 'bash',
      'label': 'npm test',
      'status': 'running',
      'progress': '12/30',
      'startedAt': 1786000000000,
    });
    expect(running.label, 'npm test');
    expect(running.running, isTrue);
    expect(running.progress, '12/30');
    final finished = DshJobInfo.fromJson({
      'id': 'job-2',
      'kind': 'bash',
      'label': 'build',
      'status': 'completed',
      'startedAt': 1786000000000,
      'finishedAt': 1786000001000,
    });
    expect(finished.running, isFalse);
    expect(finished.finishedAt, 1786000001000);
  });
  test('killJob：wire 形状与 outcome', () async {
    late http.Request captured;
    final client = DshApiClient(
      baseUrl: 'http://test.local',
      client: MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode(
            okValue({'outcome': 'requested'}),
          ),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final outcome = await client.killJob('session-1', 'job-9');
    expect(captured.url.path, contains('job/kill'));
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    final args =
        ((body['payload'] as Map)['args'] as Map).cast<String, dynamic>();
    final request = (args['request'] as Map).cast<String, dynamic>();
    expect(request['sessionId'], 'session-1');
    expect(request['jobId'], 'job-9');
    expect(outcome, 'requested');
  });
}
