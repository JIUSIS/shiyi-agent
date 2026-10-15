import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shiyi_agent_app/services/dsh_api.dart';

/// rc.2 的 `session/search` 只回 `{items:[{sessionId, snippet}], hasMore}`：
/// 没有标题/时间，必须与 `session/list` join，否则搜索结果全是空标题。
/// 见 docs/fix-log.md #396。
void main() {
  Map<String, dynamic> okValue(Map<String, dynamic> value) => {
    'type': 'server-response',
    'rpcId': 'test-rpc',
    'result': {'ok': true, 'value': value},
  };

  DshSessionSummary session(String id, {String? title, bool subagent = false}) =>
      DshSessionSummary(
        sessionId: id,
        title: title,
        updatedAt: 1786000000000,
        running: false,
        blank: false,
        isSubagent: subagent,
      );

  test('搜索结果与会话列表 join：标题/时间补回来，片段带上', () async {
    final client = DshApiClient(
      baseUrl: 'http://test.local',
      client: MockClient((req) async {
        final path = req.url.path;
        if (path.contains('session/search')) {
          return http.Response(
            jsonEncode(
              okValue({
                'items': [
                  {'sessionId': 's1', 'snippet': '命中的正文片段'},
                  {'sessionId': 'gone', 'snippet': '已删除会话'},
                ],
                'hasMore': false,
              }),
            ),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode(
            okValue({
              'items': [
                {
                  'sessionId': 's1',
                  'updatedAt': 1786000000000,
                  'running': false,
                  'blank': false,
                  'projections': {
                    'values': {
                      'title': '真实标题',
                    },
                  },
                },
                {
                  'sessionId': 'sub',
                  'origin': 'subagent',
                  'updatedAt': 1786000000001,
                  'running': false,
                  'blank': false,
                },
              ],
            }),
          ),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final hits = await client.searchSessions(
      '片段',
      knownSessions: [
        session('s1', title: '真实标题'),
        session('sub', title: '子代理', subagent: true),
      ],
    );
    expect(hits, hasLength(1));
    expect(hits.single.sessionId, 's1');
    expect(hits.single.title, '真实标题');
    expect(hits.single.updatedAt, 1786000000000);
    expect(hits.single.searchSnippet, '命中的正文片段');
  });

  test('不在列表里的命中（已删除）与子代理都不显示', () async {
    final client = DshApiClient(
      baseUrl: 'http://test.local',
      client: MockClient((req) async {
        if (req.url.path.contains('session/search')) {
          return http.Response(
            jsonEncode(
              okValue({
                'items': [
                  {'sessionId': 'gone', 'snippet': 'x'},
                  {'sessionId': 'sub', 'snippet': 'y'},
                ],
                'hasMore': false,
              }),
            ),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode(
            okValue({
              'items': [
                {
                  'sessionId': 'sub',
                  'origin': 'subagent',
                  'updatedAt': 1786000000001,
                  'running': false,
                  'blank': false,
                },
              ],
            }),
          ),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    expect(
      await client.searchSessions('x', knownSessions: const []),
      isEmpty,
    );
  });
}
