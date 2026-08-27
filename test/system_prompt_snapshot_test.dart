import 'package:flutter_test/flutter_test.dart';

import 'package:shiyi_agent_app/core/app_state.dart';
import 'package:shiyi_agent_app/core/models.dart';

import 'snapshot_helper.dart';

/// 系统提示词快照：守护 _buildSystemPrompt 的渲染结果。
/// 人设 / 工具规则 / 注入段落 / 工作目录 / 时间位置等改动都会触发 diff——
/// 提示词是模型每次请求的前缀，改动直接影响 token 数与缓存命中。
void main() {
  group('系统提示词快照', () {
    ShiyiState makeState() {
      final shiyi = ShiyiState();
      shiyi.currentSessionId = 'snap-session';
      shiyi.sessions = [
        Session(
          id: 'snap-session',
          title: '快照会话',
          model: 'test-model',
          createdAt: 0,
          updatedAt: 0,
          workspaceDir: '/tmp/test-workspace',
        ),
      ];
      // 关闭记忆注入，避免测试触碰数据库；记忆段落有独立的行为测试。
      shiyi.settings = shiyi.settings.copyWith(enableMemory: false);
      // 人设 / 工具规则随终端后端变化；快照固定 Android，Windows 另有行为测试。
      shiyi.testTerminalBackendOverride = 'android';
      return shiyi;
    }

    test('默认人设渲染（记忆/技能关闭，非计划模式）', () async {
      final shiyi = makeState();
      final prompt = await shiyi.buildSystemPromptForTest('测试输入');
      expectSnapshot(
        _normalize(prompt),
        'test/snapshots/system-prompt-default.txt',
      );
    });

    test('自定义人设 + 计划模式渲染（滚动摘要不再进 system）', () async {
      final shiyi = makeState();
      shiyi.settings = shiyi.settings.copyWith(
        systemPrompt: '你是测试人设。\n- 规则一\n- 规则二',
      );
      shiyi.planMode = true;
      final prompt = await shiyi.buildSystemPromptForTest(
        '测试输入',
        rollingSummary: '早期历史摘要：完成了 A 和 B。',
      );
      expectSnapshot(
        _normalize(prompt),
        'test/snapshots/system-prompt-custom.txt',
      );
    });

    test('提示词顺序契约：时间段落必须是最后一个【】段落（缓存前缀稳定）', () async {
      final shiyi = makeState();
      final prompt = await shiyi.buildSystemPromptForTest('测试输入');
      final lastSection =
          prompt.split('\n\n').lastWhere((s) => s.trim().isNotEmpty);
      expect(lastSection, startsWith('【当前时间】'));
    });
  });
}

/// 动态内容打码，保证快照跨平台 / 跨时刻稳定：
/// - 时间行（运行时刻不同）
/// - 工作目录段落（Windows Temp 路径 / Android 存储路径随平台不同）
/// - 平台环境段落（Android 与 Windows 文本不同，两端都移除）
String _normalize(String prompt) {
  var s = prompt.replaceAll(
    RegExp(r'【当前时间】现在是 \d+年\d+月\d+日 \d{2}:\d{2}。'),
    '【当前时间】现在是 YYYY年MM月DD日 HH:MM。',
  );
  s = s.replaceAll(
    RegExp(r'- 当前会话工作目录是 [^\n]+'),
    '- 当前会话工作目录是 {WORKSPACE}',
  );
  s = s.replaceAll(RegExp(r'\n\n【平台环境】[^\n]*'), '');
  return s;
}
