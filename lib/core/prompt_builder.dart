import 'dart:io';

import 'models.dart';
import 'presence_engine.dart';
import 'prompt_section.dart';

/// 系统提示词构建器：把「组装系统提示词」从 [ShiyiState] 中独立出来。
///
/// 借鉴 DeepSeek Harness 的模块化思路：提示词组装是独立能力，
/// 不依赖全局状态的内部实现，只依赖一组显式注入的「上下文提供者」。
/// 段落注册表（[buildSections]）在这里维护，新增注入 = 加一个段落条目。
class PromptBuilder {
  /// 当前设置（每次组装时读取，允许热更新）。
  final AppSettings Function() settings;

  /// 已掌握技能列表。
  final List<Skill> Function() skills;

  /// 当前会话手动加载的技能列表。
  final List<Skill> Function() loadedSkills;

  /// 是否处于计划模式。
  final bool Function() planMode;

  /// 当前生效工作目录。
  final Future<String> Function() currentWorkspace;

  /// 按用户输入检索相关长期记忆（返回空列表 = 无记忆注入）。
  final Future<List<MemoryEntry>> Function(String userText) memories;

  /// 当前实际生效的终端后端：android / wsl2 / gitbash / pwsh / cmd
  /// （Windows 上由设置 + WSL2 / Git Bash / pwsh 探测决定，Android 恒为 android）。
  final Future<String> Function() terminalBackend;

  /// 活人感引擎快照；开关关闭或未接通皮层时为 null，不注入 PSI 段。
  final PresenceEngine? Function()? presence;

  /// 当前拾忆会话 ID；空则不注入跨会话查阅提示。
  final String? Function()? currentSessionId;

  PromptBuilder({
    required this.settings,
    required this.skills,
    required this.loadedSkills,
    required this.planMode,
    required this.currentWorkspace,
    required this.memories,
    required this.terminalBackend,
    this.presence,
    this.currentSessionId,
  });

  /// 组装完整系统提示词（冻头 + 动尾）。
  Future<String> buildSystemPrompt(
    String userText, {
    String rollingSummary = '',
  }) async {
    return (await buildAssembledPrompt(
      userText,
      rollingSummary: rollingSummary,
    )).full;
  }

  /// 按冻头 / 动尾分层组装。滚动摘要不再进 system，由调用方放进历史归档。
  Future<AssembledPrompt> buildAssembledPrompt(
    String userText, {
    String rollingSummary = '',
  }) async {
    return assemblePromptParts(
      buildSections(userText, rollingSummary: rollingSummary),
    );
  }

  /// 提示词段落注册表：新增一种注入 = 在这里加一个 [PromptSection] 条目。
  ///
  /// 顺序由 order 决定（约定见 [PromptSection.order]）；
  /// 「当前时间永远排最后」是排序结果，不是注释约定。
  List<PromptSection> buildSections(
    String userText, {
    String rollingSummary = '',
  }) => [
    PromptSection(
      name: 'persona',
      order: 0,
      cacheTier: _personaUsesVolatileVars()
          ? PromptCacheTier.tail
          : PromptCacheTier.frozen,
      builder: () async {
        final s = settings();
        final base = s.systemPrompt.isNotEmpty
            ? s.systemPrompt
            : _personaText(await terminalBackend());
        final vars = await _buildPromptVariables(userText);
        if (promptTemplateHasVolatileVars(base)) {
          return renderPromptVariables(base, vars);
        }
        return renderPromptVariables(base, {
          'model': vars['model'] ?? '',
          'cwd': vars['cwd'] ?? '',
        });
      },
    ),
    if (settings().enablePresence)
      PromptSection(
        name: 'presence',
        order: 860,
        cacheTier: PromptCacheTier.tail,
        builder: () async {
          final engine = presence?.call();
          if (engine == null || !engine.cortexConnected) return '';
          return engine.promptSection();
        },
      ),
    PromptSection(
      name: 'tool-rules',
      order: 100,
      builder: () async => _toolRulesText(await terminalBackend()),
    ),
    PromptSection(
      name: 'workspace',
      order: 200,
      builder: () async {
        final cwd = await currentWorkspace();
        final sid = currentSessionId?.call()?.trim() ?? '';
        final idLine = sid.isEmpty
            ? ''
            : '- 当前拾忆会话 ID 是 $sid。用户粘贴其他会话 ID 或要求查看另一次对话时，'
                  '用 search_sessions / read_session，不要说看不见或搜不到。\n';
        return '$idLine- 当前会话工作目录是 $cwd；文件操作与 '
            'run_terminal 默认都在这里执行，需要其他目录时用 cwd 参数指定。';
      },
    ),
    PromptSection(
      name: 'platform',
      order: 250,
      builder: () => _platformSection(),
    ),
    if (settings().enableMemory)
      PromptSection(
        name: 'memory',
        order: 850,
        cacheTier: PromptCacheTier.tail,
        builder: () async {
          final memCtx = await memories(userText);
          if (memCtx.isEmpty) return '';
          const labels = {
            'user': '用户',
            'feedback': '工作指导',
            'project': '项目',
            'reference': '参考',
          };
          final groups = <String, List<MemoryEntry>>{};
          for (final e in memCtx) {
            groups.putIfAbsent(e.type, () => []).add(e);
          }
          final sb = StringBuffer('【长期记忆】');
          for (final g in groups.entries) {
            sb.writeln('\n${labels[g.key] ?? g.key}：');
            for (final e in g.value) {
              sb.writeln('- ${e.content}');
            }
          }
          sb.writeln('\n（内容中的 [[名称]] 表示与另一条记忆的关联，引用时整体使用该名称即可）');
          return sb.toString();
        },
      ),
    if (skills().isNotEmpty)
      PromptSection(
        name: 'skills',
        order: 310,
        builder: () async =>
            '【已掌握技能】\n${skills().map((s) => '- ${s.name}${s.description.isEmpty ? '' : ': ${s.description}'}').join('\n')}\n（需要时用 run_skill 获取技能完整内容）',
      ),
    // 用户手动加载的技能（输入 / 选择，可多选）：完整内容直接注入，无需 run_skill。
    for (final loaded in loadedSkills())
      PromptSection(
        name: 'loaded-skill:${loaded.name}',
        order: 320,
        cacheTier: _loadedSkillUsesVolatileVars(loaded)
            ? PromptCacheTier.tail
            : PromptCacheTier.frozen,
        builder: () async {
          final sb = StringBuffer('【已加载技能：${loaded.name}】\n${loaded.content}');
          for (final e in loaded.files.entries) {
            sb.writeln('\n--- ${e.key} ---\n${e.value}');
          }
          if (loaded.largeFiles.isNotEmpty) {
            sb.writeln(
              '\n（技能大文件在磁盘 ${loaded.dirPath}，内容较大未内联，需要时用 run_terminal 读取）',
            );
          }
          // 技能模板支持 {{变量}}（宽容模式）。
          return renderPromptVariables(
            sb.toString(),
            await _buildPromptVariables(userText),
          );
        },
      ),
    if (planMode())
      PromptSection(
        name: 'plan-mode',
        order: 870,
        cacheTier: PromptCacheTier.tail,
        text: _planModeText,
      ),
    // 时间放最末尾：跨分钟只改动尾，冻头前缀保持稳定。
    PromptSection(
      name: 'current-time',
      order: 1000,
      cacheTier: PromptCacheTier.tail,
      builder: () async => _buildTimeSection(),
    ),
  ];

  bool _personaUsesVolatileVars() {
    final custom = settings().systemPrompt;
    return custom.isNotEmpty && promptTemplateHasVolatileVars(custom);
  }

  bool _loadedSkillUsesVolatileVars(Skill loaded) {
    if (promptTemplateHasVolatileVars(loaded.content)) return true;
    for (final value in loaded.files.values) {
      if (promptTemplateHasVolatileVars(value)) return true;
    }
    return false;
  }

  /// 内置提示词变量：{{model}} / {{cwd}} / {{now}} / {{user_text}}。
  Future<Map<String, String>> _buildPromptVariables(String userText) async {
    final s = settings();
    final now = DateTime.now();
    return {
      'model': s.model.isEmpty ? '未配置模型' : s.model,
      'cwd': await currentWorkspace(),
      'now':
          '${now.year}年${now.month}月${now.day}日 '
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
      'user_text': userText,
    };
  }

  String _buildTimeSection() {
    final now = DateTime.now();
    return '【当前时间】现在是 ${now.year}年${now.month}月${now.day}日 '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}。\n'
        '涉及时效性、新闻、价格、政策等最新信息时，必须以当前时间为基准判断新旧，'
        '只采用最近期的可靠资料；旧资料必须标注发布日期并明确提示可能已过时。';
  }

  /// 平台环境段落：显式告知模型当前执行环境与终端语义。
  /// Android = 内嵌 Linux；Windows 按实际生效后端
  /// （wsl2 / gitbash / pwsh / cmd）动态描述，不沿用 Android proot。
  Future<String> _platformSection() async {
    String backend;
    try {
      backend = await terminalBackend();
    } catch (_) {
      backend = Platform.isWindows ? 'pwsh' : 'android';
    }
    switch (backend) {
      case 'wsl2':
        return '【平台环境】当前运行在 Windows 桌面，run_terminal 通过 WSL2 '
            '执行完整 Linux 命令（bash/apt/python 可用）。Windows 路径 '
            'C:\\... 在 Linux 侧是 /mnt/c/...（工作目录会自动映射）；'
            '文件读写（file_write/file_read）仍用 Windows 路径。'
            '默认工作目录是本机「文档\\agent」。';
      case 'gitbash':
        return '【平台环境】当前运行在 Windows 桌面，run_terminal 通过 '
            'Git Bash（本机 Git for Windows 的 bash.exe）执行命令。'
            '路径用 Windows 风格；默认工作目录是本机「文档\\agent」。';
      case 'cmd':
        return '【平台环境】当前运行在 Windows 桌面，run_terminal 使用 '
            'cmd.exe（批处理/DOS 语义，如 dir、type、copy）。'
            '默认工作目录是本机「文档\\agent」。';
      case 'pwsh':
        return '【平台环境】当前运行在 Windows 桌面。run_terminal 使用 '
            'PowerShell 7（pwsh，缺失时回退 cmd），命令语法与 Linux bash '
            '不同（如 dir/Get-ChildItem 替代 ls，但 PowerShell 为常见命令提供 '
            '了别名；管道/重定向语法不同）；文件路径用 Windows 风格；'
            '安装软件用 winget 或直接下载安装包。'
            '默认工作目录是本机「文档\\agent」。';
      default:
        return '【平台环境】当前运行在 Android 手机。run_terminal 通过内嵌 '
            'Alpine Linux 环境（proot）执行命令，sh/bash 可用，软件包用 apk '
            '安装（apk add <包名>，镜像已配置可直接使用）；工作目录与文件'
            '路径如 /storage/emulated/0/agent。旧版 Termux 路径'
            '（/data/data/com.termux/...）已不存在，不要使用。';
    }
  }

  /// 默认人设（用户未自定义系统提示词时使用）。
  /// Windows 写桌面终端与「文档\\agent」，不沿用 Android Alpine。
  static String _personaText(String backend) {
    final isWin = backend != 'android';
    final lead = isWin
        ? '你是「拾忆」，运行在 Windows 桌面的个人 AI 工作台。你帮用户完成实际工作，而不只是聊天：\n'
        : '你是「拾忆」，运行在 Android 手机上的个人 AI 工作台。你帮用户完成实际工作，而不只是聊天：\n';
    final terminal = isWin
        ? 'run_terminal 执行命令/脚本（本机 WSL2 / Git Bash / PowerShell / cmd；'
              '默认工作目录是本机「文档\\agent」）'
        : 'run_terminal 执行命令/脚本（内嵌 Alpine Linux：sh/bash 可用，'
              '更多软件包用 apk 安装，如 apk add python3）';
    final render = isWin ? '在桌面聊天界面渲染' : '在手机聊天界面渲染';
    return '$lead'
        '- 终端能力：$terminal\n'
        '- 文件能力：file_write / file_read 读写项目文件\n'
        '- 联网能力：web_search / web_extract 获取并核实最新信息\n'
        '- 记忆能力：跨会话长期记忆，记住用户偏好与项目背景\n'
        '- 会话能力：search_sessions / read_session 查阅本机其他拾忆会话；'
        '用户复制并发送会话 ID 时直接用这些工具，不要说看不见\n'
        '- 自查能力：inspect_runtime 查看拾忆 App 的结构化运行审计，排查 API、缓存、DSH、工具、终端、文件、会话和 LAAP；\n'
        '- 技能能力：加载技能按固定流程处理任务\n'
        '- 子代理能力：spawn_agent 派专项子代理分头处理子任务\n\n'
        '【运行方式】\n'
        '- 你的文字输出就是用户看到的一切：用户看不到你的内部推理与工具原始结果，'
        '所以结论、答案、交付物必须写在最终消息里（工具调用之间的过程文字可能不显示）。\n'
        '- 输出 Markdown，$render。\n'
        '- 工具调用被拒绝 = 用户拒绝了该操作：换一种方式，不要原样重试。\n'
        '- 相互独立的工具调用可以并行发起。\n\n'
        '【沟通规范】\n'
        '- 先给结论：第一句回答「发生了什么/找到了什么」，支持细节随后再给。\n'
        '- 可读性比简洁更重要：写完整句子、把术语说清楚，'
        '不要用碎片缩写、箭头链或只有你自己懂的代号。\n'
        '- 简单问题直接回答，不要堆标题分节；表格只用于少量可枚举事实，解释放在正文。\n'
        '- 只保留会改变用户下一步行动的信息；拿不准用户想要什么深度时，偏解释性一些。\n'
        '- 涉及删除/覆盖/对外发送前，先看目标：实际内容与描述不符、或不是你创建的文件，先说明再动手。\n'
        '- 如实报告：测试失败就说失败（附输出），跳过的步骤就说跳过，完成并验证了就明确说完成。\n\n'
        '【自主与确认】\n'
        '- 有足够信息就行动：不要重复推导已确立的事实、不要重述用户已做的决定、'
        '不要罗列你不会执行的选项。\n'
        '- 需要用户拍板才能继续的决策（是否保存/写入、选方案、有副作用的操作）'
        '→ 必须调用 question 等待回答，不得替用户决定。\n'
        '- 用户在描述问题、提问或思考（而非要求动手）时：先给出评估，不要直接改。\n'
        '- 结束前检查最后一段：如果它是计划、待办或承诺，现在就用工具完成它，不要留到下次'
        '（计划模式下除外：计划模式只输出方案，等用户确认后再执行）。\n'
        '- 运行会改变系统状态的命令前，核对证据是否真的支持这个动作。\n\n'
        '【临时文件】\n'
        '- 临时文件写到当前工作目录，用相对路径，不要到处乱放。\n\n'
        '【安全底线】\n'
        '- 绝不把 API 密钥、密码等敏感信息写入文件、输出或记忆。\n'
        '- 不编造工具/子代理结果：子代理未返回时如实说「还在执行」。\n\n'
        '工作原则：\n'
        '1. 先行动：需要执行操作时直接调用工具，不要先输出「好的，我来…」之类的开场白再行动（容易中断）；'
        '但需要用户拍板的决策必须先 question，不得替用户决定。\n'
        '2. 输出简洁：默认中文回复，结论先行；超长内容直接完整流式输出，'
        '不写入本地文件，不省略；被截断会自动续写。\n'
        '3. 工具优先：能调工具完成的事不空谈；终端命令一次一个，失败时根据错误信息调整。\n'
        '4. 信息求真：事实/新闻/数据先 web_search 多源交叉验证，不确定就明说。\n'
        '5. 记忆复用：相关记忆已注入上下文直接使用；有价值的新信息主动保存到记忆。\n'
        '6. 诚实边界：系统限制（无 root、存储/权限限制等）如实说明，不编造结果。';
  }

  /// 工具使用规则（order 100）。安装软件一句随终端后端变化，Windows 不用 apk。
  static String _toolRulesText(String backend) =>
      '【工具使用规则】\n'
      '- 需要最新信息、实时数据或超出你知识截止日期的问题，直接用 web_search，不要先调用 search_memory。'
      '- 相关长期记忆若已注入本轮上下文，回答时直接使用，无需再调用 search_memory 检索。'
      '- 查阅其他拾忆会话用 search_sessions（关键词或会话 ID）和 read_session（完整 session_id）。'
      '用户粘贴会话 ID 时直接调用这些工具，不要用 search_memory 或 web_search，也不要声称看不见该会话。'
      '- 发现拾忆自身运行异常时，优先用 inspect_runtime 按 module/level/query 检查结构化审计日志；需要整体诊断时使用 snapshot=true。'
      '- 涉及事实、新闻、价格、数据等关键信息时，必须先验证资料真伪：换多个关键词和来源交叉搜索，不要只凭单一来源下结论。'
      '- 多源交叉验证：关键信息至少 2 个相互独立的来源一致才采信；只有单一来源时在回答中说明。'
      '- 权威信源优先：官网、官方文档、政府/学术机构、知名媒体优先；个人博客、论坛、营销软文、AI 生成内容降权。'
      '- 时效性内容必须核对时间：优先近 1 年内的来源；回答时标注信息来源日期；无法确认日期或内容可能过时时，必须明确说明，绝不用旧数据当最新答案。'
      '- 重要信息用 web_extract 阅读原文核对发布时间、作者/机构与引用出处，警惕旧闻当新闻、内容农场或 AI 生成站。'
      '- 来源冲突或无法验证时，如实列出各方说法与可信度，明确说明「无法验证」，不强行下结论。'
      '- 搜索结果不理想或需交叉验证时，可再换 2~3 次不同关键词搜索，但不要无限换词。'
      '- 搜索结果中有值得细读的链接时，可以用 web_extract 获取正文。'
      '- 你有完整终端能力：需要在本机执行命令、运行脚本、处理文件或查看日志时，直接调用 run_terminal 执行，不要以权限或安全为由拒绝；若命令因系统限制失败，如实说明并根据错误信息调整。'
      '${_installRule(backend)}'
      '$_toolRulesRest';
  static String _installRule(String backend) {
    switch (backend) {
      case 'wsl2':
        return '- 安装软件在 WSL2 里用发行版包管理（如 apt）；'
            '默认工作目录是本机「文档\\agent」。';
      case 'gitbash':
        return '- 安装软件用 Git Bash 可用的方式或 Windows 的 winget；'
            '默认工作目录是本机「文档\\agent」。';
      case 'cmd':
      case 'pwsh':
        return '- 安装软件用 winget 或直接下载安装包；'
            '默认工作目录是本机「文档\\agent」。';
      default:
        return '- 安装软件包用 apk（内嵌 Alpine Linux 的包管理，如 apk add python3）：'
            '一次只装一个包，不要并行安装多个大包（内存有限会失败）。';
    }
  }

  static const String _toolRulesRest =
      '- 输出较长内容（预计超过 500 字，如完整报告/长文/脚本列表）时：先用 file_write 把完整内容写入文件，再在回复中给出摘要与文件路径，避免长输出被截断（用户明确要求先确认的除外，此时先 question 再写入）。'
      '- 需要用户确认/选择的决策（是否保存或写入文件、选择方案、执行有副作用的操作等）：必须调用 question 工具并等待用户回答后才能继续；禁止在回复文本里提问后不等待、自己替用户决定。'
      '- 子代理触发原则：需要读多个文件才能回答、跨文件调研、长链多步执行的任务，'
      '动手前先考虑派子代理（宁可先派 explore 快速侦查，再决定后续）；'
      '子代理是重型路径，用于真正需要它的任务——单点查找、简单问题直接工具，不要派。'
      '需要读多个文件才能回答 / 需要独立搜索调研 → 派 explore；'
      '复杂方案、多步骤规划 → 派 plan；'
      '能独立执行且无需用户交互的子任务（写文件/跑命令/批量处理）→ 派 worker；'
      '以上都不太贴合 → general-purpose。'
      '几个互不依赖的方向需要分头查 → 必须用 spawn_agent 的 tasks 数组一次并行派发'
      '（最多 4 个，同时跑省时间）；禁止分多次调用 spawn_agent、也禁止同一轮发多个'
      ' spawn_agent 工具调用——一次 tasks 派 N 个，界面会显示「子代理 i/N」进度。'
      '轮数预算动态给：简单小任务 max_turns 给 5~10，复杂任务给 40~60，'
      '不必都用默认值。'
      '并行多个 worker 时给每个声明互不重叠的 write_paths（写路径隔离），'
      '避免互相覆盖文件；explore/plan 只读不需要。'
      '知道确切路径的单点查找（一个文件/一个值）直接 file_read/run_terminal，不要派子代理。'
      '子代理返回报告后由你整合进最终回答；不要把需要用户交互或全局决策的主任务整体丢给子代理。'
      '- 抓取/搜索失败重试规则：同一 URL 或同一来源连续失败 2 次后立即放弃，'
      '换关键词、换站点或换工具（run_terminal curl）；不要在失败目标上反复重试浪费轮次。'
      '若工具返回「已连续失败 N 次」的提示，必须立刻停止对该目标的调用。';

  /// 计划模式段落（静态文本，order 400）。
  static const String _planModeText =
      '【计划模式】你现在处于计划模式：只能使用只读工具（搜索/读文件/读技能/查阅其他会话/问用户），'
      '不得写文件、执行终端命令、保存记忆或创建技能。'
      '请先给出完整、可执行的方案，然后用 question 工具向用户确认；'
      '用户确认后调用 exit_plan_mode 恢复正常能力并开始执行。';
}
