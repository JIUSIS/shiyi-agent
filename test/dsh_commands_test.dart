import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shiyi_agent_app/services/dsh_api.dart';

/// 官方斜杠命令：`commands/list(agentId)` → `[{name,description,input?:{hint,attachments?}}]`；
/// `commands/execute(agentId, line, submittedAttachments)`。
/// 见 docs/dsh-parity.md。
void main() {
  Map<String, dynamic> okValue(dynamic value) => {
    'type': 'server-response',
    'rpcId': 'x',
    'result': {'ok': true, 'value': value},
  };

  test('listCommands：契约里的数组结果 + 参数提示解析', () async {
    late http.Request captured;
    final client = DshApiClient(
      baseUrl: 'http://test.local',
      client: MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode(
            okValue([
              {
                'name': 'compact',
                'description': '压缩当前会话上下文',
              },
              {
                'name': 'permission',
                'description': '切换权限预设',
                'input': {'hint': '<preset>'},
              },
              {
                'name': 'attach',
                'description': '带附件执行',
                'input': {'hint': '说明', 'attachments': true},
              },
            ]),
          ),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final commands = await client.listCommands('session-1');
    expect(captured.url.path, contains('commands/list'));
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    final args =
        ((body['payload'] as Map)['args'] as Map).cast<String, dynamic>();
    expect(args['agentId'], 'session-1');

    expect(commands, hasLength(3));
    final compact = commands.firstWhere((c) => c.name == 'compact');
    expect(compact.needsArgs, isFalse);
    expect(compact.description, '压缩当前会话上下文');
    final permission = commands.firstWhere((c) => c.name == 'permission');
    expect(permission.needsArgs, isTrue);
    expect(permission.hint, '<preset>');
    final attach = commands.firstWhere((c) => c.name == 'attach');
    expect(attach.acceptsAttachments, isTrue);
  });

  test('executeCommand：三个 wire 参数（含附件）', () async {
    late http.Request captured;
    final client = DshApiClient(
      baseUrl: 'http://test.local',
      client: MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode(okValue({'ok': true})),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    await client.executeCommand(
      sessionId: 'session-1',
      line: '/permission plan',
      submittedAttachments: [
        {
          'type': 'image',
          'mediaType': 'image/png',
          'data': 'AAAA',
        },
      ],
    );
    expect(captured.url.path, contains('commands/execute'));
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    final args =
        ((body['payload'] as Map)['args'] as Map).cast<String, dynamic>();
    expect(args['agentId'], 'session-1');
    expect(args['line'], '/permission plan');
    final attachments = (args['submittedAttachments'] as List).cast<Map>();
    expect(attachments.single['type'], 'image');
    expect(attachments.single['data'], 'AAAA');
  });
}
