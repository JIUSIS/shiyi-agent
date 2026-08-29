import 'package:flutter_test/flutter_test.dart';

import 'package:shiyi_agent_app/core/app_state.dart';
import 'package:shiyi_agent_app/core/models.dart';
import 'package:shiyi_agent_app/core/presence_engine.dart';
import 'package:shiyi_agent_app/core/prompt_builder.dart';
import 'package:shiyi_agent_app/core/prompt_section.dart';

void main() {
  group('assemblePromptSections', () {
    test('assemblePromptParts 冻头在前、动尾在后', () async {
      final out = await assemblePromptParts([
        const PromptSection(
          name: 'tail',
          order: 10,
          cacheTier: PromptCacheTier.tail,
          text: 'TAIL',
        ),
        const PromptSection(name: 'frozen', order: 0, text: 'FROZEN'),
      ]);
      expect(out.frozen, 'FROZEN');
      expect(out.tail, 'TAIL');
      expect(out.full, 'FROZEN\n\nTAIL');
    });

    test('按 order 升序组装（乱序输入）', () async {
      final out = await assemblePromptSections([
        const PromptSection(name: 'b', order: 200, text: 'B'),
        const PromptSection(name: 'a', order: 100, text: 'A'),
        const PromptSection(name: 'c', order: 300, text: 'C'),
      ]);
      expect(out, 'A\n\nB\n\nC');
    });

    test('空段落跳过，不产生多余空行', () async {
      final out = await assemblePromptSections([
        const PromptSection(name: 'a', order: 100, text: 'A'),
        PromptSection(name: 'empty', order: 200, builder: () async => ''),
        const PromptSection(name: 'c', order: 300, text: 'C'),
      ]);
      expect(out, 'A\n\nC');
    });

    test('静态文本优先于 builder', () async {
      final out = await assemblePromptSections([
        PromptSection(
          name: 'a',
          order: 100,
          text: '静态',
          builder: () async => '动态（不应被调用）',
        ),
      ]);
      expect(out, '静态');
    });

    test('重复段落名抛 StateError', () async {
      expect(
        () => assemblePromptSections([
          const PromptSection(name: 'dup', order: 100, text: 'A'),
          const PromptSection(name: 'dup', order: 200, text: 'B'),
        ]),
        throwsStateError,
      );
    });

    test('order 相同按注册顺序稳定', () async {
      final out = await assemblePromptSections([
        const PromptSection(name: 'x', order: 100, text: '先'),
        const PromptSection(name: 'y', order: 100, text: '后'),
      ]);
      expect(out, '先\n\n后');
    });
  });

  group('renderPromptVariables', () {
    const vars = {'model': 'deepseek-v4', 'cwd': '/tmp/x'};

    test('注册变量被替换', () {
      expect(
        renderPromptVariables('模型 {{model}}，目录 {{cwd}}', vars),
        '模型 deepseek-v4，目录 /tmp/x',
      );
    });

    test('宽容模式：未注册变量原样保留', () {
      expect(renderPromptVariables('未知 {{foo}} 保留', vars), '未知 {{foo}} 保留');
    });

    test('严格模式：未注册变量抛 StateError', () {
      expect(
        () => renderPromptVariables('未知 {{foo}}', vars, strict: true),
        throwsStateError,
      );
    });

    test('无花括号文本原样返回（不触发正则）', () {
      const text = '普通文本 {model} 单花括号';
      expect(renderPromptVariables(text, vars), text);
    });

    test('变量名只接受小写字母开头', () {
      expect(
        renderPromptVariables('{{Model}} {{x_y}} {{123}}', vars),
        '{{Model}} {{x_y}} {{123}}', // 均不匹配注册规则，原样保留
      );
    });
  });

  group('段落注册表（ShiyiState）', () {
    ShiyiState makeState() {
      final shiyi = ShiyiState();
      shiyi.currentSessionId = 's';
      shiyi.sessions = [
        Session(
          id: 's',
          title: 't',
          model: 'm',
          createdAt: 0,
          updatedAt: 0,
          workspaceDir: '/tmp/w',
        ),
      ];
      shiyi.settings = shiyi.settings.copyWith(enableMemory: false);
      shiyi.testTerminalBackendOverride = 'android';
      return shiyi;
    }

    test('段落名唯一（注册表结构合法）', () {
      final sections = makeState().buildPromptSectionsForTest('输入');
      final names = sections.map((s) => s.name).toList();
      expect(names.toSet().length, names.length);
    });

    test('活人感关闭时不注册 presence 段落', () {
      final sections = makeState().buildPromptSectionsForTest('输入');
      expect(sections.any((s) => s.name == 'presence'), isFalse);
    });

    test('活人感开启但皮层未接通时不写入 PSI 段', () async {
      final shiyi = makeState();
      shiyi.settings = shiyi.settings.copyWith(enablePresence: true);
      final prompt = await shiyi.buildSystemPromptForTest('输入');
      expect(prompt, isNot(contains('PSI Cognitive State')));
      expect(prompt, isNot(contains('【在场】')));
      expect(prompt, contains('你是「拾忆」'));
    });

    test('活人感开启时注入 presence，排在工具规则之后、时间之前，并标为动尾', () async {
      final shiyi = makeState();
      shiyi.settings = shiyi.settings.copyWith(enablePresence: true);
      shiyi.presence.applyRemote(
        needs: {
          'competence': 0.7,
          'autonomy': 0.4,
          'relatedness': 0.4,
          'certainty': 0.4,
          'growth': 0.4,
        },
        attentionFocus: 'task',
      );
      final sections = shiyi.buildPromptSectionsForTest('输入');
      final presence = sections.singleWhere((s) => s.name == 'presence');
      final persona = sections.singleWhere((s) => s.name == 'persona');
      final toolRules = sections.singleWhere((s) => s.name == 'tool-rules');
      final time = sections.singleWhere((s) => s.name == 'current-time');
      expect(presence.order, greaterThan(persona.order));
      expect(presence.order, greaterThan(toolRules.order));
      expect(presence.order, lessThan(time.order));
      expect(presence.cacheTier, PromptCacheTier.tail);
      expect(toolRules.cacheTier, PromptCacheTier.frozen);

      final text = await presence.build();
      expect(text, contains('## PSI Cognitive State (Live)'));
      expect(text, contains('[PSI State —'));
      expect(text, contains('当前最高需求 (competence)'));
      expect(text, isNot(contains('本机皮层')));
      expect(text, isNot(contains('【在场】')));
    });

    test('活人感开启时完整提示词含 PSI 段，默认人设仍在', () async {
      final shiyi = makeState();
      shiyi.settings = shiyi.settings.copyWith(enablePresence: true);
      shiyi.presence.applyRemote(
        needs: {
          'competence': 0.7,
          'autonomy': 0.4,
          'relatedness': 0.4,
          'certainty': 0.4,
          'growth': 0.4,
        },
      );
      final prompt = await shiyi.buildSystemPromptForTest('输入');
      expect(prompt, contains('## PSI Cognitive State (Live)'));
      expect(prompt, contains('你是「拾忆」'));
      expect(prompt, contains('【工具使用规则】'));
    });

    test('活人感开启时提示词随用户输入改变主导需求', () async {
      final shiyi = makeState();
      shiyi.settings = shiyi.settings.copyWith(enablePresence: true);
      shiyi.presence = PresenceEngine();
      shiyi.presence.applyRemote(
        needs: {
          'competence': 0.3,
          'autonomy': 0.3,
          'relatedness': 0.8,
          'certainty': 0.3,
          'growth': 0.3,
        },
        attentionFocus: 'social',
      );
      final prompt = await shiyi.buildSystemPromptForTest('今晚一起吃饭，有你陪伴真好');
      expect(prompt, contains('relatedness'));
      expect(prompt, contains('优先建立情感连接，表达温暖和理解'));
    });

    test('时间段落 order 最大（永远排最后，缓存前缀稳定）', () {
      final sections = makeState().buildPromptSectionsForTest('输入');
      final time = sections.singleWhere((s) => s.name == 'current-time');
      for (final s in sections) {
        expect(
          s.order <= time.order,
          isTrue,
          reason: '${s.name} (${s.order}) 不应排在时间段落之后',
        );
      }
    });

    test('计划模式进动尾，不改冻头', () async {
      final shiyi = makeState();
      shiyi.planMode = true;
      final assembled = await assemblePromptParts(
        shiyi.buildPromptSectionsForTest('输入'),
      );
      expect(assembled.frozen, isNot(contains('【计划模式】')));
      expect(assembled.tail, contains('【计划模式】'));
      expect(assembled.tail, contains('【当前时间】'));
    });

    test('静态段落求值不依赖实例状态', () async {
      final shiyi = makeState();
      final sections = shiyi.buildPromptSectionsForTest('输入');
      final toolRules = sections.singleWhere((s) => s.name == 'tool-rules');
      expect(await toolRules.build(), contains('【工具使用规则】'));
    });

    test('用户自定义提示词支持 {{变量}} 插值（宽容模式）', () async {
      final shiyi = makeState();
      shiyi.settings = shiyi.settings.copyWith(
        systemPrompt: '你是测试人设，工作目录 {{cwd}}，未知变量 {{nope}}',
      );
      final prompt = await shiyi.buildSystemPromptForTest('输入');
      expect(prompt, contains('工作目录 /tmp/w'));
      expect(prompt, contains('未知变量 {{nope}}')); // 未注册变量原样保留
    });

    test('persona 自定义提示词支持 {{user_text}}（与技能段落口径一致）', () async {
      final shiyi = makeState();
      shiyi.settings = shiyi.settings.copyWith(
        systemPrompt: '人设：用户刚说「{{user_text}}」',
      );
      final prompt = await shiyi.buildSystemPromptForTest('你好世界');
      expect(prompt, contains('用户刚说「你好世界」'));
    });

    test('工作目录段落注入当前拾忆会话 ID', () async {
      final prompt = await makeState().buildSystemPromptForTest('输入');
      expect(prompt, contains('当前拾忆会话 ID 是 s'));
      expect(prompt, contains('search_sessions'));
      expect(prompt, contains('read_session'));
    });

    test('会话世界状态进入动尾，执行闭环保持在冻头', () {
      final shiyi = makeState();
      shiyi.skills.add(
        Skill(
          id: 1,
          name: 'catalog-skill',
          description: '目录技能',
          content: '目录技能内容',
          createdAt: 0,
          files: const {},
        ),
      );
      shiyi.loadedSkills.add(
        Skill(
          id: 2,
          name: 'loaded-skill',
          description: '已加载技能',
          content: '已加载技能内容',
          createdAt: 0,
          files: const {},
        ),
      );

      final sections = shiyi.buildPromptSectionsForTest('输入');
      expect(
        sections.singleWhere((s) => s.name == 'workspace').cacheTier,
        PromptCacheTier.tail,
      );
      expect(
        sections.singleWhere((s) => s.name == 'skills').cacheTier,
        PromptCacheTier.tail,
      );
      expect(
        sections
            .singleWhere((s) => s.name == 'loaded-skill:loaded-skill')
            .cacheTier,
        PromptCacheTier.tail,
      );
      expect(
        sections.singleWhere((s) => s.name == 'execution-contract').cacheTier,
        PromptCacheTier.frozen,
      );
    });

    test('工作目录变化只改变动尾，不污染冻头', () async {
      final shiyi = makeState();
      final first = await assemblePromptParts(
        shiyi.buildPromptSectionsForTest('输入'),
      );
      shiyi.sessions.first.workspaceDir = '/tmp/other-workspace';
      final second = await assemblePromptParts(
        shiyi.buildPromptSectionsForTest('输入'),
      );

      expect(second.frozen, first.frozen);
      expect(second.tail, isNot(first.tail));
      expect(second.tail, contains('/tmp/other-workspace'));
      expect(second.frozen, contains('【执行闭环】'));
    });

    test('已加载技能内容支持 {{变量}} 插值', () async {
      final shiyi = makeState();
      shiyi.loadedSkills.add(
        Skill(
          id: 1,
          name: 'tpl',
          description: 'd',
          content: '技能模板：目录是 {{cwd}}',
          createdAt: 0,
          files: const {},
        ),
      );
      final prompt = await shiyi.buildSystemPromptForTest('输入');
      expect(prompt, contains('技能模板：目录是 /tmp/w'));
    });
  });

  group('Windows 提示词不沿用 Android', () {
    PromptBuilder makeBuilder(String backend) {
      return PromptBuilder(
        settings: () => AppSettings(enableMemory: false),
        skills: () => const [],
        loadedSkills: () => const [],
        planMode: () => false,
        currentWorkspace: () async => backend == 'android'
            ? '/storage/emulated/0/agent'
            : r'C:\Users\me\Documents\agent',
        memories: (_) async => const [],
        terminalBackend: () async => backend,
      );
    }

    test('默认人设进冻头，当前时间进动尾', () async {
      final assembled = await makeBuilder('android').buildAssembledPrompt('hi');
      expect(assembled.frozen, contains('你是「拾忆」'));
      expect(assembled.frozen, contains('【工具使用规则】'));
      expect(assembled.frozen, isNot(contains('【当前时间】')));
      expect(assembled.tail, contains('【当前时间】'));
    });

    test('Android 人设与工具规则仍是 Alpine / apk，不出现 Windows 路径或后端', () async {
      final prompt = await makeBuilder('android').buildSystemPrompt('hi');
      expect(prompt, contains('运行在 Android 手机上的个人 AI 工作台'));
      expect(prompt, contains('apk add python3'));
      expect(prompt, contains('/storage/emulated/0/agent'));
      expect(prompt, isNot(contains('文档\\agent')));
      expect(prompt, isNot(contains('WSL2')));
      expect(prompt, isNot(contains('Git Bash')));
      expect(prompt, isNot(contains('PowerShell')));
      expect(prompt, isNot(contains('Windows 桌面')));
    });

    test('WSL2 人设是 Windows 桌面，默认文档\\agent，不出现 Android 路径或 apk', () async {
      final prompt = await makeBuilder('wsl2').buildSystemPrompt('hi');
      expect(prompt, contains('运行在 Windows 桌面的个人 AI 工作台'));
      expect(prompt, contains('文档\\agent'));
      expect(prompt, contains('WSL2'));
      expect(prompt, isNot(contains('运行在 Android 手机')));
      expect(prompt, isNot(contains('apk add python3')));
      expect(prompt, isNot(contains('内嵌 Alpine Linux 的包管理')));
      expect(prompt, isNot(contains('/storage/emulated/0/agent')));
      expect(prompt, isNot(contains('proot')));
    });

    test('Git Bash / PowerShell / cmd 也不出现 Android 路径或 apk', () async {
      for (final backend in ['gitbash', 'pwsh', 'cmd']) {
        final prompt = await makeBuilder(backend).buildSystemPrompt('hi');
        expect(prompt, contains('运行在 Windows 桌面的个人 AI 工作台'), reason: backend);
        expect(prompt, contains('文档\\agent'), reason: backend);
        expect(prompt, isNot(contains('运行在 Android 手机')), reason: backend);
        expect(prompt, isNot(contains('apk add python3')), reason: backend);
        expect(
          prompt,
          isNot(contains('/storage/emulated/0/agent')),
          reason: backend,
        );
        expect(prompt, isNot(contains('proot')), reason: backend);
      }
    });
  });
}
