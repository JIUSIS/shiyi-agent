import 'package:flutter_test/flutter_test.dart';
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
}
