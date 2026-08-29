import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shiyi_agent_app/services/dsh_api.dart';
import 'package:shiyi_agent_app/widgets/dsh_directory_picker.dart';

Map<String, dynamic> _ok(Map<String, dynamic> value) => {
  'type': 'server-response',
  'rpcId': 'test-rpc',
  'result': {'ok': true, 'value': value},
};

Map<String, dynamic> _error(String code, String message) => {
  'type': 'server-response',
  'rpcId': 'test-rpc',
  'result': {
    'ok': false,
    'error': {'code': code, 'message': message},
  },
};

void main() {
  test('远程默认目录优先使用 DSH 主机 cwd', () async {
    final client = DshApiClient(
      baseUrl: 'http://computer.local:3080',
      client: MockClient(
        (request) async => http.Response(
          jsonEncode(
            _ok({
              'platform': 'win32',
              'cwd': r'C:\Users\dev\project',
              'home': r'C:\Users\dev',
            }),
          ),
          200,
        ),
      ),
    );

    expect(await dshHostDefaultDirectory(client), r'C:\Users\dev\project');
  });

  test('旧版 DSH 没有 host.describe 时从目录快照获取默认目录', () async {
    var calls = 0;
    final client = DshApiClient(
      baseUrl: 'http://computer.local:3080',
      client: MockClient((request) async {
        calls++;
        if (request.url.path.endsWith('/host.describe')) {
          return http.Response(
            jsonEncode(_error('not-found', 'unsupported')),
            200,
          );
        }
        return http.Response(
          jsonEncode(
            _ok({
              'path': r'D:\workspace',
              'home': r'D:\Users\dev',
              'items': const [],
            }),
          ),
          200,
        );
      }),
    );

    expect(await dshHostDefaultDirectory(client), r'D:\workspace');
    expect(calls, 2);
  });
}
