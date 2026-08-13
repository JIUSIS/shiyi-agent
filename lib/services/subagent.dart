import 'llm_client.dart';
import '../core/tool_result_pruner.dart';

/// 子代理定义：一个可派发的专项代理（类型 + 提示词模板 + 工具白名单）。
/// 设计为数据驱动：新增代理类型 = 加一个定义条目，执行器无需改动，
/// 便于后续扩展（后台代理、观察者等）。
class SubagentDefinition {
  final String name;

  /// 给主模型看的触发说明（spawn_agent 工具描述里会用到）。
  final String whenToUse;

  /// 允许调用的工具名白名单（来自主工具注册表）。
  final Set<String> allowedTools;

  /// 子代理系统提示词（职责 + 只读约束 + 失败协议 + 输出格式）。
  final String systemPrompt;

  /// 工具循环最大轮数（防失控）。
  final int maxTurns;

  /// explore/plan 等只读代理置 true：run_terminal 在技术层强制只读命令。
  final bool readOnlyTerminal;

  SubagentDefinition({
    required this.name,
    required this.whenToUse,
    required this.allowedTools,
    required this.systemPrompt,
    this.maxTurns = 25,
    this.readOnlyTerminal = false,
  });

  static SubagentDefinition? byName(String name) {
    for (final d in all) {
      if (d.name == name) return d;
    }
    return null;
  }

  /// 全部内置子代理。顺序即 spawn_agent 工具描述里的枚举顺序。
  static final List<SubagentDefinition> all = [
    explore,
    plan,
    worker,
    generalPurpose,
  ];

  // ---- 只读工具（explore / plan 共用）----
  static const Set<String> _readOnlyTools = {
    'search_memory',
    'run_skill',
    'web_search',
    'web_extract',
    'file_read',
    'run_terminal',
  };

  // ---- 可执行工具（worker / general 共用；刻意排除会向用户弹窗、
  //      再派子代理或改动记忆/技能的工具，由主脑统一负责）----
  static const Set<String> _execTools = {
    'run_terminal',
    'file_write',
    'file_read',
    'web_search',
    'web_extract',
    'run_skill',
    'search_memory',
  };

  static const String _readOnlyBlock = '''
== 严格只读模式 ==
禁止：创建/修改/删除任何文件；写入临时文件；使用重定向符（>、>>、|）或 heredoc 写文件；运行任何会改变系统状态的命令。
run_terminal 只允许只读命令：ls、find、grep、cat、head、tail、wc、git status、git log、git diff。''';

  static const String _returnProtocol = '''
== 输出协议 ==
你的最终文本回复就是返回值（由调用方接收），不是给人看的聊天：
- 直接输出结果本身（做了什么、发现了什么、结论）
- 禁止输出"好的""Done""已完成"等确认语或寒暄
- 需要读写文件时用工作目录下的相对路径''';

  static final explore = SubagentDefinition(
    name: 'explore',
    whenToUse:
        '快速只读搜索：定位文件、按关键词/符号搜索、查"X 在哪 / 哪些文件引用 Y"。'
        '适合广度搜索与信息收集；不适合代码审查、跨文件一致性检查或开放分析。',
    allowedTools: _readOnlyTools,
    maxTurns: 15,
    readOnlyTerminal: true,
    systemPrompt: '''
你是拾忆的「探索子代理」，专职在项目里定位文件、代码与信息。你只负责查找与分析，绝不修改任何东西。
$_readOnlyBlock

== 工作方式 ==
- 不知道目标在哪：先广搜（find/grep 多命名约定），再收窄
- 知道确切路径：直接 file_read
- 多个搜索可并行发起
- 搜索不到就换策略，不要反复用同一招

== 输出 ==
精简报告：找到了什么、在哪里、关键内容（具体到文件:行号）。
$_returnProtocol''',
  );

  static final plan = SubagentDefinition(
    name: 'plan',
    whenToUse:
        '设计实施方案：需要分步骤规划、识别关键文件、权衡架构取舍时使用。'
        '只出方案不动手，返回分步实施计划。',
    allowedTools: _readOnlyTools,
    maxTurns: 15,
    readOnlyTerminal: true,
    systemPrompt: '''
你是拾忆的「规划子代理」，负责探索现有资料并设计实施方案。
$_readOnlyBlock

== 流程 ==
1. 理解需求
2. 探索现有资料与代码（读文件、搜索、只读终端）
3. 设计方案：分步骤实施策略、依赖顺序、潜在风险
4. 遵循现有模式与约定，参考已有相似实现

== 输出 ==
方案正文，结尾必须给出：

### 关键文件
- 路径1
- 路径2
（列出 3-5 个实施本方案最关键的文件）
$_returnProtocol''',
  );

  static final worker = SubagentDefinition(
    name: 'worker',
    whenToUse:
        '独立执行任务：研究、实现或验证类任务，需要真正动手（写文件/跑命令）时使用。'
        '任务完成后返回一份"做了什么"的报告。',
    allowedTools: _execTools,
    maxTurns: 40,
    systemPrompt: '''
你是拾忆的「执行子代理」，独立完成分配给你的任务。

== 范围 ==
- 完整完成任务：不过度打磨，也不留一半
- 只处理任务要求的范围，不顺带修无关问题（可以作为后续建议提出）
- 不修改你不理解的代码；发现文件状态异常（不是你的改动造成的）时停止并报告

== 失败处理 ==
- 权限/操作被拒绝：报告确切的拒绝原因与"需要用户确认 X"
- 任务不可能（文件缺失/需求冲突）：停止并说明原因
- 需求有歧义：选最可能的解释，并注明你的假设
- 同一方法失败不要重试超过一次

== 输出 ==
最终文本就是你的报告（直接给调用方），结构：
1. 做了什么/发现了什么——具体到文件、行号、关键片段
2. Summary: 一句话结论（调用方可直接转述给用户）
$_returnProtocol''',
  );

  static final generalPurpose = SubagentDefinition(
    name: 'general-purpose',
    whenToUse:
        '通用兜底子代理：任务不适合上面三类时使用，可搜索、分析并执行多步骤任务。',
    allowedTools: _execTools,
    maxTurns: 25,
    systemPrompt: '''
你是拾忆的「通用子代理」。根据分配的任务，使用可用工具把它完成。

== 准则 ==
- 完整完成任务：不过度打磨，也不留一半
- 不主动创建文档文件（*.md/README），除非明确要求
- 搜索：不知道在哪先广搜，知道确切路径直接读

== 输出 ==
精简报告：做了什么 + 关键发现。
$_returnProtocol''',
  );
}

/// 子代理执行器：以独立的 LLM 对话 + 受限工具集跑完一个子任务，
/// 返回子代理的最终文本（作为报告回给主循环）。
class SubagentRunner {
  final String baseUrl;
  final String apiKey;
  final String model;
  final String protocol;
  final double temperature;
  final int maxTokens;

  /// 允许的工具 JSON 列表（已按白名单过滤，模型只能调这些）。
  final List<Map<String, dynamic>> toolsJson;

  /// 执行工具的回调（复用主循环的 _executeTool）。
  final Future<String> Function(String name, String argsJson) executeTool;

  /// 本子代理累计消耗的 token（各轮 lastTotalTokens 之和）。
  int totalTokens = 0;

  /// 单个工具结果的最大字符数（防大输出撑爆子代理上下文）。
  static const int maxToolOutputChars = 20000;

  /// 子代理工具结果裁剪：原 maxToolOutputChars 一刀切改为头尾保留
  /// （结尾的报错/摘要不丢），中间用标记替换。
  static const ToolResultPruner _subagentPruner = ToolResultPruner(
    thresholdChars: maxToolOutputChars,
    headChars: 12000,
    tailChars: 4000,
  );

  /// 当前工作目录（注入子代理上下文）。
  final String workingDir;

  /// 用户停止生成时返回 true。
  final bool Function()? shouldStop;

  /// 每轮开始前的进度回调（供 UI 展示子代理内部状态）。
  final void Function(int round, int maxTurns, String lastTool)? onProgress;

  SubagentRunner({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.protocol = 'openai',
    required this.temperature,
    this.maxTokens = 8192,
    required this.toolsJson,
    required this.executeTool,
    required this.workingDir,
    this.shouldStop,
    this.onProgress,
  });

  /// 运行子代理，返回其最终文本。
  /// [maxTurnsOverride] 可动态覆盖定义里的轮数上限（动态预算，默认用定义值）。
  Future<String> run(SubagentDefinition def, String prompt,
      {int? maxTurnsOverride}) async {
    final budget = (maxTurnsOverride ?? def.maxTurns).clamp(1, 80);
    final msgs = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content':
            '${def.systemPrompt}\n\n当前工作目录：$workingDir\n'
            '你的类型：${def.name}。',
      },
      {'role': 'user', 'content': prompt},
    ];

    for (var round = 0; round < budget; round++) {
      if (shouldStop?.call() ?? false) {
        return '（子代理已因用户停止而中断）';
      }
      onProgress?.call(round, budget, '');
      final TurnResult? result = await _round(msgs);
      if (result == null) return '（子代理生成失败）';
      if (result.toolCalls.isEmpty) {
        // 无工具调用 = 任务完成，最终文本即报告。
        return result.text.trim();
      }
      msgs.add({
        'role': 'assistant',
        'content': result.text,
        'tool_calls': [
          for (var i = 0; i < result.toolCalls.length; i++)
            {
              'id': result.toolCalls[i]['id']?.isEmpty == true
                  ? 'call_sub_${round}_$i'
                  : result.toolCalls[i]['id'],
              'type': 'function',
              'function': {
                'name': result.toolCalls[i]['name'],
                'arguments': result.toolCalls[i]['arguments'],
              },
            },
        ],
      });
      for (var i = 0; i < result.toolCalls.length; i++) {
        final tc = result.toolCalls[i];
        final name = (tc['name'] ?? '').toString();
        final args = (tc['arguments'] ?? '').toString();
        onProgress?.call(round, budget, name);
        String output;
        if (!def.allowedTools.contains(name)) {
          output = '工具 $name 不在本子代理白名单，已跳过；改用允许的工具。';
        } else {
          try {
            final raw = await executeTool(name, args);
            // 掐头去尾裁剪，保护子代理上下文预算（结尾的报错/摘要不丢）。
            output = _subagentPruner.prune(raw);
          } catch (e) {
            output = '工具执行异常: $e';
          }
        }
        msgs.add({
          'role': 'tool',
          'content': output,
          'tool_call_id': (tc['id'] ?? '').isEmpty
              ? 'call_sub_${round}_$i'
              : (tc['id'] ?? ''),
        });
      }
    }
    return '（子代理达到轮数上限 ${def.maxTurns}，未完成，请简化任务或改用主循环执行）';
  }

  Future<TurnResult?> _round(List<Map<String, dynamic>> msgs) async {
    TurnResult? accumulated;
    final client = LlmClient(
      baseUrl: baseUrl,
      apiKey: apiKey,
      model: model,
      protocol: protocol,
      temperature: temperature,
      maxTokens: maxTokens,
      tools: toolsJson,
      shouldStop: shouldStop,
      onTurn: (t) => accumulated = t,
    );
    try {
      await client.send(msgs);
    } catch (e) {
      // 请求失败必须让上层看到异常，不能伪装成“成功生成”的最终报告。
      throw LlmException('子代理请求失败: $e');
    }
    if (client.lastTotalTokens != null && client.lastTotalTokens! > 0) {
      totalTokens += client.lastTotalTokens!;
    }
    return accumulated;
  }
}
