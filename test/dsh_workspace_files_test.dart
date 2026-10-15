import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shiyi_agent_app/services/dsh_api.dart';

/// 工作区文件（官方侧边栏用法）：`workspaceFiles/*` 的 scopeId **就是会话 id**：
/// `list(sessionId, path)` / `read(sessionId, path, range?)` /
/// `readBytes(sessionId, path, options?)` / `stat(sessionId, path)`。
/// 见 docs/dsh-parity.md。
void main() {
  Map<String, dynamic> okValue(dynamic value) => {
    'type': 'server-response',
    'rpcId': 'x',
    'result': {'ok': true, 'value': value},
  };

  DshApiClient clientWith(MockClient mock) =>
      DshApiClient(baseUrl: 'http://test.local', client: mock);

  test('listWorkspaceFiles：wire 形状（scopeId=会话 id）+ 目录/文件解析', () async {
    late http.Request captured;
    final client = clientWith(
      MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode(
            okValue({
              'path': 'src',
              'entries': [
                {'name': 'lib', 'type': 'directory'},
                {'name': 'main.dart', 'type': 'file', 'size': 1024},
                {'name': 'sock', 'type': 'other'},
              ],
              'truncated': true,
            }),
          ),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final listing = await client.listWorkspaceFiles('session-9', 'src');
    expect(captured.url.path, contains('workspaceFiles/list'));
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    final args =
        ((body['payload'] as Map)['args'] as Map).cast<String, dynamic>();
    expect(args['workspaceFileScopeId'], 'session-9');
    expect(args['path'], 'src');

    expect(listing.path, 'src');
    expect(listing.truncated, isTrue);
    expect(listing.entries.map((e) => e.name), ['lib', 'main.dart', 'sock']);
    expect(listing.entries.first.isDir, isTrue);
    expect(listing.entries[1].size, 1024);
    expect(listing.entries.last.isDir, isFalse);
  });

  test('readWorkspaceFile：文本 + eof + 绝对路径', () async {
    late http.Request captured;
    final client = clientWith(
      MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode(
            okValue({
              'offset': 0,
              'text': 'void main() {}',
              'lines': 1,
              'eof': true,
              'absolutePath': '/w/main.dart',
              'version': 'v1',
            }),
          ),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final file = await client.readWorkspaceFile('session-9', 'main.dart');
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    final args =
        ((body['payload'] as Map)['args'] as Map).cast<String, dynamic>();
    expect(args['workspaceFileScopeId'], 'session-9');
    expect(args['range'], isEmpty);
    expect(file.text, 'void main() {}');
    expect(file.eof, isTrue);
    expect(file.absolutePath, '/w/main.dart');
  });

  test('readWorkspaceFileBytes：base64 解回字节', () async {
    final client = clientWith(
      MockClient((req) async {
        return http.Response(
          jsonEncode(
            okValue({
              'offset': 0,
              'data': base64Encode([1, 2, 3, 4]),
              'eof': true,
              'absolutePath': '/w/a.png',
              'version': 'v1',
            }),
          ),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final bytes = await client.readWorkspaceFileBytes('session-9', 'a.png');
    expect(bytes, [1, 2, 3, 4]);
  });

  test('statWorkspaceFile：元信息', () async {
    final client = clientWith(
      MockClient((req) async {
        return http.Response(
          jsonEncode(
            okValue({
              'absolutePath': '/w/a.txt',
              'version': 'v1',
              'bytes': 42,
            }),
          ),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final stat = await client.statWorkspaceFile('session-9', 'a.txt');
    expect(stat.absolutePath, '/w/a.txt');
    expect(stat.bytes, 42);
  });
}
