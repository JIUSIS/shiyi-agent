import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/presence_engine.dart';

void main() {
  group('PresenceEngine', () {
    test('未接皮层时不注入 PSI 段，也不声称已接通', () {
      final e = PresenceEngine();
      expect(e.cortexConnected, isFalse);
      expect(e.promptSection(), isEmpty);
      expect(e.promptSection(), isNot(contains('LAAP 已接通')));
      expect(e.promptSection(), isNot(contains('本机皮层')));
    });

    test('空 applyRemote 不算接通', () {
      final e = PresenceEngine();
      expect(e.applyRemote(), isFalse);
      expect(e.cortexConnected, isFalse);
      expect(e.promptSection(), isEmpty);
    });

    test('官方 preamble / cot_hint 原样进动尾', () {
      final e = PresenceEngine();
      final applied = e.applyRemote(
        needs: {
          'competence': 0.4,
          'autonomy': 0.4,
          'relatedness': 0.35,
          'certainty': 0.86,
          'growth': 0.4,
        },
        valence: -0.2,
        energy: 7,
        attentionFocus: 'explore',
        cognitiveCycle: 12,
        preamble:
            '[PSI State — Cycle 12]\nNeeds: certainty=0.86\nDominant need: certainty (explore mode)',
        cotHint: '[认知状态] 最高需求: certainty — 提供确切的、可验证的信息 | 注意力: explore',
      );
      expect(applied, isTrue);
      expect(e.cortexConnected, isTrue);
      expect(e.dominantNeed, 'certainty');
      final prompt = e.promptSection();
      expect(prompt, contains('## PSI Cognitive State (Live)'));
      expect(prompt, contains('[PSI State — Cycle 12]'));
      expect(prompt, contains('当前最高需求 (certainty)'));
      expect(prompt, contains('提供确切的、可验证的信息'));
      expect(prompt, contains('[认知状态] 最高需求: certainty'));
      expect(prompt, isNot(contains('本机皮层')));
      expect(prompt, isNot(contains('LAAP 已接通')));
      expect(prompt, isNot(contains('本轮内心')));
      expect(prompt, isNot(contains('【在场】')));
    });

    test('只有 needs 时按官方格式补 preamble', () {
      final e = PresenceEngine();
      e.applyRemote(
        needs: {
          'competence': 0.3,
          'autonomy': 0.3,
          'relatedness': 0.8,
          'certainty': 0.3,
          'growth': 0.3,
        },
        attentionFocus: 'social',
      );
      expect(e.dominantNeed, 'relatedness');
      final prompt = e.promptSection();
      expect(prompt, contains('## PSI Cognitive State (Live)'));
      expect(prompt, contains('[PSI State —'));
      expect(prompt, contains('relatedness'));
      expect(prompt, contains('优先建立情感连接，表达温暖和理解'));
    });
  });
}
