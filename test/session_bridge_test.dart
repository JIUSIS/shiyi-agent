import 'package:flutter_test/flutter_test.dart';

import 'package:shiyi_agent_app/core/app_state.dart';
import 'package:shiyi_agent_app/core/models.dart';
import 'package:shiyi_agent_app/core/prompt_builder.dart';
import 'package:shiyi_agent_app/core/session_bridge.dart';
import 'package:shiyi_agent_app/widgets/tool_pill.dart';

void main() {
  group('SessionBridge 识别会话 ID', () {
    test('拾忆会话 ID 原样识别', () {
      expect(SessionBridge.extractSessionId('s1710000000000_123456'),
          's1710000000000_123456');
    });

    test('粘贴时带空格或前后说明仍能抽出 ID', () {
      expect(
        SessionBridge.extractSessionId('  看这个会话 s1710000000000_123456  '),
        's1710000000000_123456',
      );
      expect(
        SessionBridge.extractSessionId('会话ID：s1710000000000_123456'),
        's1710000000000_123456',
      );
    });

    test('普通关键词不是会话 ID', () {
      expect(SessionBridge.extractSessionId('小说大纲'), isNull);
      expect(SessionBridge.extractSessionId(''), isNull);
    });
  });

  group('SessionBridge 搜索结果', () {
    test('按完整会话 ID 命中时必须出现该会话，即使标题和正文都没有这段 ID', () {
      final target = Session(
        id: 's1710000000000_123456',
        title: '小说大纲',
        model: 'm',
        createdAt: 1,
        updatedAt: 1,
        messageCount: 4,
      );
      final text = SessionBridge.formatSearchResults(
        query: 's1710000000000_123456',
        exact: target,
        hits: const [],
        currentSessionId: 's999_1',
      );
      expect(text, contains('s1710000000000_123456'));
      expect(text, contains('小说大纲'));
      expect(text, isNot(contains('没有找到')));
    });

    test('当前会话在结果里会标注，避免模型以为看不见自己', () {
      final current = Session(
        id: 's111_1',
        title: '当前',
        model: 'm',
        createdAt: 1,
        updatedAt: 1,
      );
      final text = SessionBridge.formatSearchResults(
        query: 's111_1',
        exact: current,
        hits: const [],
        currentSessionId: 's111_1',
      );
      expect(text, contains('当前会话'));
    });

    test('没有命中时明确说找不到，并提示用完整 ID', () {
      final text = SessionBridge.formatSearchResults(
        query: 's1710000000000_999999',
        exact: null,
        hits: const [],
        currentSessionId: 's111_1',
      );
      expect(text, contains('没有找到'));
      expect(text, contains('s1710000000000_999999'));
    });
  });

  group('SessionBridge 阅读会话', () {
    test('能读出另一会话的用户和助手消息', () {
      final session = Session(
        id: 's1710000000000_123456',
        title: '小说大纲',
        model: 'm',
        createdAt: 1,
        updatedAt: 1,
        rollingSummary: '已定主角叫阿禾',
      );
      final messages = [
        ChatMessage(
          id: 'm1',
          sessionId: session.id,
          role: 'user',
          content: '帮我写一个大纲',
          createdAt: 1,
        ),
        ChatMessage(
          id: 'm2',
          sessionId: session.id,
          role: 'assistant',
          content: '主角叫阿禾，从山村出发。',
          createdAt: 2,
        ),
        ChatMessage(
          id: 'm3',
          sessionId: session.id,
          role: 'tool',
          content: '工具原始输出不应进入跨会话阅读',
          createdAt: 3,
        ),
      ];
      final text = SessionBridge.formatTranscript(
        session: session,
        messages: messages,
        currentSessionId: 's999_1',
      );
      expect(text, contains('s1710000000000_123456'));
      expect(text, contains('小说大纲'));
      expect(text, contains('帮我写一个大纲'));
      expect(text, contains('主角叫阿禾，从山村出发。'));
      expect(text, contains('已定主角叫阿禾'));
      expect(text, isNot(contains('工具原始输出不应进入跨会话阅读')));
    });

    test('会话不存在时说明找不到，不要空结果', () {
      expect(
        SessionBridge.missingSession('s1710000000000_999999'),
        contains('没有找到会话'),
      );
    });
  });

  group('拾忆工具目录暴露跨会话查阅', () {
    test('search_sessions 与 read_session 都在，且计划模式可用', () {
      final tools = ShiyiState.buildToolRegistryForTest(windows: false);
      final byName = {for (final t in tools) t.name: t};
      expect(byName.containsKey('search_sessions'), isTrue);
      expect(byName.containsKey('read_session'), isTrue);
      expect(byName['search_sessions']!.readOnly, isTrue);
      expect(byName['read_session']!.readOnly, isTrue);
      expect(byName['search_sessions']!.description, contains('会话 ID'));
      expect(byName['read_session']!.description, contains('session_id'));
    });

    test('工具胶囊有中文标签', () {
      expect(toolEventLabel('search_sessions'), '查会话');
      expect(toolEventLabel('read_session'), '读会话');
    });
  });

  group('提示词告知模型可查阅其他会话', () {
    PromptBuilder builder() => PromptBuilder(
      settings: () => AppSettings(enableMemory: false),
      skills: () => const [],
      loadedSkills: () => const [],
      planMode: () => false,
      currentWorkspace: () async => '/tmp/w',
      memories: (_) async => const [],
      terminalBackend: () async => 'android',
      currentSessionId: () => 's111_1',
    );

    test('人设和工具规则提到 search_sessions / read_session', () async {
      final prompt = await builder().buildSystemPrompt('hi');
      expect(prompt, contains('search_sessions'));
      expect(prompt, contains('read_session'));
      expect(prompt, contains('s111_1'));
      expect(prompt, contains('会话 ID'));
    });
  });
}
