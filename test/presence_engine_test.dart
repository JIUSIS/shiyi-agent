import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/presence_engine.dart';

void main() {
  group('PresenceEngine', () {
    test('新会话默认偏向联结，不先走能力感', () {
      final e = PresenceEngine();
      expect(e.needs['relatedness']!, greaterThan(e.needs['competence']!));
      expect(e.cognitiveCycle, 0);
      expect(e.interactionCount, 0);
      expect(e.dominantNeed, 'relatedness');
    });

    test('新会话在场段含本轮内心话，模型只负责翻译', () {
      final e = PresenceEngine();
      final p = e.promptSection();
      expect(p, contains('【在场】'));
      expect(p, contains('本轮内心'));
      expect(p, contains('刚又见面'));
      expect(p, contains('翻译成一句自然的话'));
      expect(p, contains('不要改核心意图'));
      expect(p, contains('不要工作汇报腔'));
      expect(p, contains('不要第一句给结论'));
      expect(p, isNot(contains('展示专业能力')));
      expect(p, isNot(contains('PSI')));
    });

    test('隔了很久再会，内心话带上离开的时长', () {
      final e = PresenceEngine(
        lastSeenMs: DateTime.now()
            .subtract(const Duration(hours: 8))
            .millisecondsSinceEpoch,
        interactionCount: 12,
        bondLevel: 40,
      );
      e.onUserMessage('我回来了');
      final inner = e.innerLine();
      expect(inner, contains('8'));
      expect(inner, contains('小时'));
      expect(e.promptSection(), contains(inner));
    });

    test('闲聊你好时内心话是接话，不是办事', () {
      final e = PresenceEngine();
      e.onUserMessage('你好');
      expect(e.innerLine(), contains('打了个招呼'));
      expect(e.innerLine(), isNot(contains('先给结论')));
    });

    test('闲聊你好仍保持联结主导', () {
      final e = PresenceEngine();
      e.onUserMessage('你好');
      expect(e.dominantNeed, 'relatedness');
    });

    test('用户说陪伴/一起会抬高联结需求', () {
      final e = PresenceEngine();
      e.onUserMessage('今晚一起吃饭，有你陪伴真好');
      expect(e.needs['relatedness']!, greaterThan(0.5));
      expect(e.cognitiveCycle, 1);
      expect(e.dominantNeed, 'relatedness');
    });

    test('用户问为什么/不确定会抬高确定性需求', () {
      final e = PresenceEngine();
      e.onUserMessage('为什么会这样？我不太确定');
      expect(e.needs['certainty']!, greaterThan(0.5));
    });

    test('长回复抬高能力感，暖词抬高联结', () {
      final e = PresenceEngine();
      e.onAssistantReply('理解你的处境。${'详细说明。' * 40}');
      expect(e.needs['competence']!, greaterThan(0.5));
      expect(e.needs['relatedness']!, greaterThan(0.5));
    });

    test('需求会向 0.5 缓慢回落', () {
      final e = PresenceEngine();
      e.needs['growth'] = 0.9;
      e.onUserMessage('嗯');
      expect(e.needs['growth']!, lessThan(0.9));
      expect(e.needs['growth']!, greaterThan(0.5));
    });

    test('提示词含本轮内心话，且禁止念出数值', () {
      final e = PresenceEngine();
      e.onUserMessage('我们一起把这个做完');
      final p = e.promptSection();
      expect(p, contains('【在场】'));
      expect(p, contains('本轮内心'));
      expect(p, contains(e.innerLine()));
      expect(p, contains('不要直接说出来'));
      expect(p, contains('不要每轮自我介绍'));
      expect(p, contains('覆盖上方沟通规范里的工作台腔'));
      expect(p, isNot(contains('PSI')));
    });

    test('JSON 往返保留需求、轮次和上次见面', () {
      final e = PresenceEngine();
      e.onUserMessage('想学点新的，一起探索');
      final restored = PresenceEngine.fromJson(e.toJson());
      expect(restored.cognitiveCycle, e.cognitiveCycle);
      expect(restored.needs['growth'], e.needs['growth']);
      expect(restored.needs['relatedness'], e.needs['relatedness']);
      expect(restored.interactionCount, e.interactionCount);
      expect(restored.lastSeenMs, e.lastSeenMs);
      expect(restored.bondLevel, e.bondLevel);
    });
  });
}
