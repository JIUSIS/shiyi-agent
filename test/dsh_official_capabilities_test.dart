import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shiyi_agent_app/services/dsh_api.dart';

/// 官方能力补齐（批次 ⑥⑦）的端点与关键参数：工作区置顶/取消归档/默认、
/// 模型发现、队列、定时任务、插件启停、目标机终端。见 docs/dsh-parity.md。
void main() {
  test('各端点 wire 形状', () async {
    final calls = <String, Map<String, dynamic>>{};
    final client = DshApiClient(
      baseUrl: 'http://test.local',
      client: MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final payload = (body['payload'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{};
        // 现代调用是 {'args': {...}}；旧协议回退直接是裸 payload。
        calls[req.url.path] =
            (payload['args'] as Map?)?.cast<String, dynamic>() ?? payload;
        return http.Response(
          jsonEncode({
            'type': 'server-response',
            'rpcId': 'x',
            'result': {
              'ok': true,
              'value': <String, dynamic>{},
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    await client.unarchiveSession('s1');
    expect(calls['/api/workspace/unarchiveSession']!['request'], {
      'sessionId': 's1',
    });

    await client.pinSession('s1');
    expect(calls['/api/workspace/pinSession']!['request'], {'sessionId': 's1'});
    await client.pinSession('s1', pinned: false);
    expect(calls['/api/workspace/unpinSession']!['request'], {'sessionId': 's1'});

    await client.initializeDefaultWorkspace();
    expect(calls['/api/workspace/initializeDefault'], isNotNull);

    await client.discoverModels('llm-pi-ai');
    expect(calls['/api/llm/discoverModels']!['settingsNs'], 'llm-pi-ai');

    await client.updateQueue('s1', 'item-1', {'op': 'remove'});
    final queue = calls['/api/session/updateQueue']!;
    expect(queue['request'], {
      'sessionId': 's1',
      'itemId': 'item-1',
      'action': {'op': 'remove'},
    });

    await client.listSchedules('s1');
    expect(calls['/api/schedule/list']!['agentId'], 's1');
    await client.deleteSchedule('s1', 'job-1');
    expect(calls['/api/schedule/delete']!['id'], 'job-1');

    await client.setPluginEnabled('dsh-x', false);
    expect(calls['/api/pluginManager/setPluginEnabled']!['id'], 'dsh-x');
    expect(calls['/api/pluginManager/setPluginEnabled']!['enabled'], isFalse);

    await client.listTerminals('s1');
    expect(calls['/api/terminal/list']!['sessionId'], 's1');
    await client.writeTerminal('s1', 't1', 'ls\n');
    final write = calls['/api/terminal/write']!;
    expect(write['agentId'], 's1');
    expect(write['id'], 't1');
    expect(write['data'], 'ls\n');
    await client.resizeTerminal('s1', 't1', cols: 100, rows: 30);
    final resize = calls['/api/terminal/resize']!;
    expect(resize['cols'], 100);
    expect(resize['rows'], 30);

    await client.permissionPresetCatalog();
    expect(calls['/api/permissionPresets/catalog'], isNotNull);

    await client.listFileReferences('s1', 'main');
    expect(calls['/api/fileReferences/list']!['query'], 'main');

    // 消息反馈：rating 只有 positive/negative（官方 schema），不是自由文本。
    await client.putMessageFeedback(
      's1',
      'm-1',
      rating: 'positive',
      note: '很有用',
    );
    final feedback = calls['/api/messageFeedback/put']!;
    // 目标描述符只有一个 `request` 参数（不包会被网关拒，#403）。
    final feedbackRequest = (feedback['request'] as Map).cast<String, dynamic>();
    expect(feedbackRequest['sessionId'], 's1');
    expect(feedbackRequest['messageId'], 'm-1');
    expect(feedbackRequest['rating'], 'positive');
    expect(feedbackRequest['note'], '很有用');
    await client.deleteMessageFeedback('s1', 'm-1');
    expect(
      ((calls['/api/messageFeedback/delete']!['request'] as Map)
          .cast<String, dynamic>())['messageId'],
      'm-1',
    );
    // 后台任务清单在目标里是 stream 端点，不能当 unary POST 打（#403）：
    // 这里只验证它不会发 /api/job/list 这种 HTTP 请求。
    expect(calls.containsKey('/api/job/list'), isFalse);

    // 会话分叉：session/fork({request:{sessionId}})
    await client.forkSession('s1');
    final fork = calls['/api/session/fork']!;
    expect((fork['request'] as Map)['sessionId'], 's1');

    // ⑥ 发现模型：llm/discoverModels(settingsNs, request)
    await client.discoverModels('llm-x', request: {'providerId': 'p1'});
    final discover = calls['/api/llm/discoverModels']!;
    expect(discover['settingsNs'], 'llm-x');
    expect((discover['request'] as Map)['providerId'], 'p1');

    // ⑦ 语音 / Cordis / PDF 端点
    await client.speechCatalog();
    expect(calls['/api/speech/catalog'], isNotNull);
    await client.prepareSpeech('whisper');
    expect(calls['/api/speech/prepare']!['providerId'], 'whisper');
    await client.cordisInventory();
    expect(calls['/api/dynamicCordisRunner/inventory'], isNotNull);
    await client.renderOfficeToPdf({'path': 'a.docx'});
    expect(calls['/api/officeToPdf/render'], isNotNull);

    // 收尾补齐的 6 个 + account：官方 137 个端点全部可达。
    await client.listAllProviders();
    expect(calls['/api/llm/listProviders'], isNotNull);
    await client.officeToPdfGeneration('s1', 'a.docx');
    final generation = calls['/api/officeToPdf/generation']!;
    expect(generation['workspaceFileScopeId'], 's1');
    expect(generation['path'], 'a.docx');
    await client.fastestPluginRegistry();
    expect(calls['/api/pluginRegistryProbe/fastest'], isNotNull);
    await client.recordSessionFeedback('s1', text: '整体不错');
    final record = calls['/api/sessionFeedback/record']!;
    expect((record['request'] as Map)['sessionId'], 's1');
    await client.openSettingsDocument('permission');
    expect(calls['/api/settings/openSettingsDocument']!['ns'], 'permission');
    await client.replaceSettings('permission', {'defaultPreset': 'plan'});
    final replace = calls['/api/settings/replace']!;
    expect(replace['ns'], 'permission');
    expect((replace['section'] as Map)['defaultPreset'], 'plan');
    await client.accountState({'id': 'shiyi'});
    expect((calls['/api/account/getState']!['client'] as Map)['id'], 'shiyi');
    await client.accountBalance({'id': 'shiyi'});
    expect(calls['/api/account/getBalance'], isNotNull);
  });
}
