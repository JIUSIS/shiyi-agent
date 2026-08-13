import 'package:flutter_test/flutter_test.dart';

import 'package:shiyi_agent_app/core/app_state.dart';
import 'package:shiyi_agent_app/core/models.dart';
import 'package:shiyi_agent_app/core/prompt_section.dart';

void main() {
  group('assemblePromptSections', () {
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
      expect(
        renderPromptVariables('未知 {{foo}} 保留', vars),
        '未知 {{foo}} 保留',
      );
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
      return shiyi;
    }

    test('段落名唯一（注册表结构合法）', () {
      final sections = makeState().buildPromptSectionsForTest('输入');
      final names = sections.map((s) => s.name).toList();
      expect(names.toSet().length, names.length);
    });

    test('时间段落 order 最大（永远排最后，缓存前缀稳定）', () {
      final sections = makeState().buildPromptSectionsForTest('输入');
      final time = sections.singleWhere((s) => s.name == 'current-time');
      for (final s in sections) {
        expect(s.order <= time.order, isTrue,
            reason: '${s.name} (${s.order}) 不应排在时间段落之后');
      }
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
}
