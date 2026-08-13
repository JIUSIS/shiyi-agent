import 'package:flutter/foundation.dart';

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

/// 子代理执行状态（借鉴 DeepSeek Harness assistant-output / run-settlement 的思路）：
/// 状态类型化，主循环按类型决策，不再靠字符串括号标记区分成败。
enum SubagentStatus {
  /// 正常完成，[SubagentResult.report] 为最终报告。
  success,

  /// 用户停止生成。
  stopped,

  /// 达到轮数上限未完成。
  turnLimit,

  /// 单轮生成失败（无有效回合结果）。
  generationFailed,

  /// LLM 请求失败（网络/网关/鉴权等）。
  requestFailed,
}

/// 子代理执行结果：状态 + 报告 + 失败原因 + token 统计（内聚，不靠外部累加）。
class SubagentResult {
  final SubagentStatus status;

  /// 成功时：子代理最终文本（报告）。失败时为空串。
  final String report;

  /// 失败原因（人类可读，供日志/UI 展示）。
  final String? error;

  /// 本子代理累计消耗的 token。
  final int totalTokens;

  SubagentResult.success(this.report, {this.totalTokens = 0})
      : status = SubagentStatus.success,
        error = null;

  SubagentResult.stopped({this.totalTokens = 0})
      : status = SubagentStatus.stopped,
        report = '',
        error = null;

  SubagentResult.turnLimit(int maxTurns, {this.totalTokens = 0})
      : status = SubagentStatus.turnLimit,
        report = '',
        error = '达到轮数上限 $maxTurns';

  SubagentResult.generationFailed({this.totalTokens = 0})
      : status = SubagentStatus.generationFailed,
        report = '',
        error = '单轮生成失败';

  SubagentResult.requestFailed(String message, {this.totalTokens = 0})
      : status = SubagentStatus.requestFailed,
        report = '',
        error = message;

  bool get isSuccess => status == SubagentStatus.success;

  /// 展示给模型的文本：成功 = 报告原文；失败 = 带括号标记的失败说明
  /// （与历史文本一致，避免破坏既有行为；类型化让主循环可以进一步决策）。
  String toModelText() {
    switch (status) {
      case SubagentStatus.success:
        return report;
      case SubagentStatus.stopped:
        return '（子代理已因用户停止而中断）';
      case SubagentStatus.turnLimit:
        return '（子代理$error，未完成，请简化任务或改用主循环执行）';
      case SubagentStatus.generationFailed:
        return '（子代理生成失败）';
      case SubagentStatus.requestFailed:
        return '（子代理异常：$error）';
    }
  }
}

/// 子代理执行器：以独立的 LLM 对话 + 受限工具集跑完一个子任务，
/// 返回 [SubagentResult]（状态类型化，不再返回裸字符串报告）。
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

  /// 子代理上下文预算（token，与主循环估算口径一致）。
  /// <= 0 表示不裁剪；超预算时裁剪早期工具轮，防复杂任务撑爆上下文。
  final int contextBudgetTokens;

  /// 测试专用：覆盖单轮执行（默认 null 走真实 LlmClient）。
  @visibleForTesting
  Future<TurnResult?> Function(List<Map<String, dynamic>> msgs)? roundOverride;

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
    this.contextBudgetTokens = 0,
    this.roundOverride,
  });

  /// 运行子代理，返回类型化结果。
  /// [maxTurnsOverride] 可动态覆盖定义里的轮数上限（动态预算，默认用定义值）。
  Future<SubagentResult> run(SubagentDefinition def, String prompt,
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
        return SubagentResult.stopped(totalTokens: totalTokens);
      }
      onProgress?.call(round, budget, '');
      final TurnResult? result;
      try {
        result = roundOverride != null
            ? await roundOverride!(msgs)
            : await _round(msgs);
      } on LlmException catch (e) {
        // 请求失败必须如实返回失败状态，不能伪装成成功报告。
        return SubagentResult.requestFailed(
          '子代理请求失败: $e',
          totalTokens: totalTokens,
        );
      }
      if (result == null) {
        return SubagentResult.generationFailed(totalTokens: totalTokens);
      }
      if (result.toolCalls.isEmpty) {
        // 无工具调用 = 任务完成，最终文本即报告。
        return SubagentResult.success(
          result.text.trim(),
          totalTokens: totalTokens,
        );
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
      // 超预算时裁剪早期工具轮（保留 system + user + 最近轮）。
      _enforceContextBudget(msgs);
    }
    return SubagentResult.turnLimit(def.maxTurns, totalTokens: totalTokens);
  }

  /// 上下文预算裁剪：估算超预算时从最早的工具轮开始成组删除
  /// （assistant 的 tool_calls + 其后的 tool 结果），直到预算内或无可删轮。
  /// 只删完整组，不会留下孤儿 tool 消息（孤儿 tool 消息会让 API 报 400）。
  void _enforceContextBudget(List<Map<String, dynamic>> msgs) {
    if (contextBudgetTokens <= 0) return;
    var guard = 0;
    while (_estimateMessagesTokens(msgs) > contextBudgetTokens && guard++ < 20) {
      int? groupStart;
      for (var i = 1; i < msgs.length; i++) {
        if (msgs[i]['role'] == 'assistant' && msgs[i]['tool_calls'] != null) {
          groupStart = i;
          break;
        }
      }
      if (groupStart == null) break; // 没有可删的工具轮
      var groupEnd = groupStart + 1;
      while (groupEnd < msgs.length && msgs[groupEnd]['role'] == 'tool') {
        groupEnd++;
      }
      msgs.removeRange(groupStart, groupEnd);
    }
  }

  /// 估算消息列表 token（与主循环口径一致：中文约 1 token/字，英文约 4 字符/token）。
  static int _estimateMessagesTokens(List<Map<String, dynamic>> msgs) {
    var total = 0;
    for (final m in msgs) {
      final c = m['content'];
      if (c is String) total += _estimateTokens(c);
      final tcs = m['tool_calls'];
      if (tcs is List && tcs.isNotEmpty) {
        total += _estimateTokens(tcs.join());
      }
    }
    return total;
  }

  /// 估算文本 token 数（与 ShiyiState._estimateTokens 同口径）。
  static int _estimateTokens(String text) {
    var cjk = 0, other = 0;
    for (final r in text.runes) {
      if (r >= 0x4E00 && r <= 0x9FFF) {
        cjk++;
      } else {
        other++;
      }
    }
    return cjk + (other / 4).ceil();
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
