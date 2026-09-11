import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shiyi_agent_app/services/laap_api.dart';
import 'package:shiyi_agent_app/services/laap_service.dart';

void main() {
  test('cognitive_state 解析 needs 和官方 preamble / cot_hint', () {
    final state = LaapCognitiveState.fromJson({
      'preamble': '[PSI State — Cycle 9]\nNeeds: competence=0.9',
      'cot_hint': '最高需求: relatedness — 建立情感连接',
      'state': {
        'needs': {
          'competence': 0.41,
          'autonomy': 0.5,
          'relatedness': 0.77,
          'certainty': 0.33,
          'growth': 0.5,
        },
        'valence': 0.21,
        'energy': 8.5,
        'arousal': 0.44,
        'attention_focus': 'social',
        'cognitive_cycle': 9,
      },
    });
    expect(state.needs['relatedness'], closeTo(0.77, 0.0001));
    expect(state.needs['certainty'], closeTo(0.33, 0.0001));
    expect(state.valence, closeTo(0.21, 0.0001));
    expect(state.energy, closeTo(8.5, 0.0001));
    expect(state.arousal, closeTo(0.44, 0.0001));
    expect(state.attentionFocus, 'social');
    expect(state.cognitiveCycle, 9);
    expect(state.preamble, contains('[PSI State — Cycle 9]'));
    expect(state.cotHint, contains('relatedness'));
  });

  test('没有 state 包装时也能从顶层 needs 读', () {
    final state = LaapCognitiveState.fromJson({
      'needs': {'relatedness': 0.62},
      'attentionFocus': 'task',
    });
    expect(state.needs['relatedness'], closeTo(0.62, 0.0001));
    expect(state.attentionFocus, 'task');
  });

  test('安装输出超长只留尾部', () {
    final long = 'a' * 130000;
    final out = LaapService.mergeInstallOutput('', long);
    expect(out.length, 120000);
    expect(out.endsWith('a' * 10), isTrue);
  });

  test('error 或空 state 不当成成功', () {
    expect(
      () => LaapCognitiveState.parseResponse({
        'error': 'PSI adapter unavailable',
        'preamble': '',
        'state': {},
      }),
      throwsA(isA<LaapApiException>()),
    );
    expect(
      () => LaapCognitiveState.parseResponse({'state': {}}),
      throwsA(isA<LaapApiException>()),
    );
  });

  test('PYTHONPATH 带上 aris_brain', () {
    expect(
      LaapService.pythonPathFor('/root/.laap/src'),
      '/root/.laap/src:/root/.laap/src/aris_brain',
    );
    expect(
      LaapService.pythonPathFor(r'C:\Users\me\.laap\src', posix: false),
      r'C:\Users\me\.laap\src;C:\Users\me\.laap\src\aris_brain',
    );
  });

  test('bootstrap 按官方协议唤醒 LAAP 实例', () async {
    late http.Request captured;
    final client = LaapApiClient(
      baseUrl: 'http://test.local:11546',
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'status': 'awakened',
            'identity': {'name': 'Aris', 'user_name': '用户'},
            'personality': {'preset': 'playful_spirit'},
            'bond': {'strength': 0.4},
            'ceremony': '我感觉到你了',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final result = await client.bootstrap(
      userName: '用户',
      preset: 'playful_spirit',
    );

    expect(captured.url.path, '/v1/bootstrap');
    expect(jsonDecode(captured.body), {
      'user_name': '用户',
      'preset': 'playful_spirit',
    });
    expect(result.identityName, 'Aris');
    expect(result.ceremony, '我感觉到你了');
  });

  test('recall_memory 解析官方记忆列表', () async {
    late http.Request captured;
    final client = LaapApiClient(
      baseUrl: 'http://test.local:11546',
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'query': '项目',
            'count': 2,
            'memories': [
              {'content': '用户使用 Flutter 开发拾忆'},
              {'text': '用户偏好中文交流'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final memories = await client.recallMemory('项目');

    expect(captured.url.path, '/v1/recall_memory');
    expect(jsonDecode(captured.body), {'query': '项目'});
    expect(memories.map((m) => m.content), ['用户使用 Flutter 开发拾忆', '用户偏好中文交流']);
  });

  test('reflect 按官方协议提交输出和成功反馈', () async {
    late http.Request captured;
    final client = LaapApiClient(
      baseUrl: 'http://test.local:11546',
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({'success': true}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    await client.reflect(
      '本轮回答',
      feedback: const {'success': true, 'connection': true},
    );

    expect(jsonDecode(captured.body), {
      'output': '本轮回答',
      'success': true,
      'feedback': {'success': true, 'connection': true},
    });
  });
}
