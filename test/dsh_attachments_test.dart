import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shiyi_agent_app/services/dsh_api.dart';

/// rc.2 的附件契约（见 docs/dsh-parity.md）：
/// - 图片：`session/prompt` 的 image 块**直接内联 base64**，不用先上传；
/// - 文件：先 `fileUploads/upload(agentId,{data,name})` 换 receiptId，再用 file 块。
///
/// 改这段之前 DSH 的输入区是把本地路径拼成文本发出去的（模型看到的是手机路径）。
void main() {
  Map<String, dynamic> okValue(Map<String, dynamic> value) => {
    'type': 'server-response',
    'rpcId': 'x',
    'result': {'ok': true, 'value': value},
  };

  test('prompt：图片内联 + 文件 receiptId，文本块在前', () async {
    late http.Request captured;
    final client = DshApiClient(
      baseUrl: 'http://test.local',
      client: MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode(
            okValue({'accepted': true}),
          ),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    await client.prompt(
      'session-1',
      '看看这张图',
      images: const [
        DshImageAttachment(
          mediaType: 'image/png',
          base64: 'AAAA',
          name: 'shot.png',
        ),
      ],
      fileReceiptIds: const ['receipt-7'],
    );

    expect(captured.url.path, contains('session/prompt'));
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    final args =
        ((body['payload'] as Map)['args'] as Map).cast<String, dynamic>();
    // session/prompt 的 wire 参数是单个 request（见 _modernRpcCall）
    final request = (args['request'] as Map).cast<String, dynamic>();
    expect(request['sessionId'], 'session-1');
    expect(request['mode'], 'queue');
    final content = (request['content'] as List).cast<Map>();
    expect(content, hasLength(3));
    expect(content[0]['type'], 'text');
    expect(content[0]['text'], '看看这张图');
    expect(content[1]['type'], 'image');
    expect(content[1]['mediaType'], 'image/png');
    expect(content[1]['data'], 'AAAA');
    expect(content[1]['name'], 'shot.png');
    expect(content[2]['type'], 'file');
    expect(content[2]['receiptId'], 'receipt-7');
  });

  test('prompt：空文本 + 只有附件也能发；全空则不发请求', () async {
    var calls = 0;
    final client = DshApiClient(
      baseUrl: 'http://test.local',
      client: MockClient((req) async {
        calls++;
        return http.Response(
          jsonEncode(
            okValue({'accepted': true}),
          ),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    await client.prompt('s', '   ', fileReceiptIds: const ['r1']);
    expect(calls, 1);
    await client.prompt('s', '   ');
    expect(calls, 1); // 没有内容就不发
  });

  test('uploadFile：wire 形状与回执解析', () async {
    late http.Request captured;
    final client = DshApiClient(
      baseUrl: 'http://test.local',
      client: MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode(
            okValue({
              'receiptId': 'rcpt-1',
              'file': {
                'attachmentId': 'att-1',
                'name': '报告.pdf',
                'bytes': 1234,
              },
            }),
          ),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final receipt = await client.uploadFile(
      'session-1',
      base64: 'ZZZZ',
      name: '报告.pdf',
    );
    expect(captured.url.path, contains('fileUploads/upload'));
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    final args =
        ((body['payload'] as Map)['args'] as Map).cast<String, dynamic>();
    expect(args['agentId'], 'session-1');
    final request = (args['request'] as Map).cast<String, dynamic>();
    expect(request['data'], 'ZZZZ');
    expect(request['name'], '报告.pdf');
    expect(receipt.receiptId, 'rcpt-1');
    expect(receipt.attachmentId, 'att-1');
    expect(receipt.bytes, 1234);
  });

  test('mediaType 按扩展名推断（不认识按 jpeg）', () {
    expect(DshImageAttachment.mediaTypeForPath('/a/b.png'), 'image/png');
    expect(DshImageAttachment.mediaTypeForPath('/a/b.WEBP'), 'image/webp');
    expect(DshImageAttachment.mediaTypeForPath('/a/b.gif'), 'image/gif');
    expect(DshImageAttachment.mediaTypeForPath('/a/b.heic'), 'image/jpeg');
  });

  test('历史里的 image/file 块不再消失（渲染为占位文本）', () async {
    final client = DshApiClient(
      baseUrl: 'http://test.local',
      client: MockClient((req) async {
        return http.Response(
          jsonEncode(
            okValue({
              'records': [
                {
                  'event': {
                    'type': 'user/message',
                    'seq': 1,
                    'time': 1,
                    'data': {
                      'content': [
                        {
                          'type': 'image',
                          'mediaType': 'image/png',
                          'data': 'AAAA',
                          'name': '截图.png',
                        },
                        {'type': 'file', 'receiptId': 'r1'},
                        {'type': 'text', 'text': '这两个都看一下'},
                      ],
                    },
                  },
                },
              ],
              'hasMore': false,
            }),
          ),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final messages = await client.history('session-1');
    expect(messages, hasLength(1));
    expect(messages.single.content, contains('【图片：截图.png】'));
    expect(messages.single.content, contains('【附件】'));
    expect(messages.single.content, contains('这两个都看一下'));
  });
}
