import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../core/models.dart';
import 'dsh_endpoint.dart';
import 'dsh_live.dart';
import 'runtime_logger.dart';

/// DSH（DeepSeek Harness）HTTP RPC API 客户端。
///
/// 协议（实测于 dsh 0.1.0-rc.6，`dsh-host-apiproxy`）：
/// - 请求：`POST /api/<method>`，body `{type:'client-request', rpcId, method, payload}`
/// - 响应：`{type:'server-response', rpcId, result: {ok:true, value} | {ok:false, error:{code,message}}}`
/// - 下行：`ws://<host>/api/events.mux` 与 `/api/events.host`，每条文本是 ServerRequest；
///   `assistant/chunk` 就是 token 流（text-delta / reasoning-delta）。
///
/// 适配层单点封装：DSH 协议升级只改本文件。
class DshApiException implements Exception {
  final String message;
  final String? code;
  DshApiException(this.message, {this.code});
  @override
  String toString() => code == null ? message : '$message (code: $code)';
}

class DshCommandExecution {
  final String? commandId;
  final bool ok;
  final String? result;
  final String? error;
  final int? sourceEventSeq;

  const DshCommandExecution({
    required this.commandId,
    required this.ok,
    this.result,
    this.error,
    this.sourceEventSeq,
  });

  factory DshCommandExecution.fromJson(Map<String, dynamic> json) {
    final outcome = (json['result'] as Map?)?.cast<String, dynamic>();
    final kind = outcome?['kind']?.toString();
    final text = outcome?['text']?.toString();
    final legacyError = json['error'];
    final error = kind == 'error'
        ? text ?? 'DSH 命令执行失败'
        : legacyError is Map
        ? legacyError['message']?.toString() ?? legacyError.toString()
        : legacyError?.toString();
    return DshCommandExecution(
      commandId: json['commandId']?.toString(),
      ok: kind == 'success' || (kind == null && json['ok'] == true),
      result: kind == 'success'
          ? text
          : json['output']?.toString() ??
                (json['result'] is String ? json['result']?.toString() : null),
      error: error,
      sourceEventSeq: (outcome?['sourceEventSeq'] as num?)?.toInt(),
    );
  }
}

class DshSessionSummary {
  final String sessionId;
  final String? title;
  final int updatedAt;
  final bool running;
  final bool blank;
  final String? cwd;
  final String? agentPreset;
  final int turnCount;
  final int stepCount;
  final int llmMs;
  final int toolMs;
  final int ttftMs;
  final int ttftSteps;
  final int decodeMs;
  final int decodeTokens;
  final int uncachedInputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;
  final int outputTokens;

  /// 是否为子代理会话（origin=subagent，由 agent 派生，不显示在会话列表）。
  final bool isSubagent;

  /// `session/search` 命中片段。
  ///
  /// rc.2 的 `session/search` 只回 `{items:[{sessionId, snippet}]}`（**没有**
  /// 标题 / 时间），必须与 `session/list` 做 join 才能显示完整结果；片段本身
  /// 也要留着给搜索列表用（见 docs/fix-log.md #396）。
  final String? searchSnippet;

  /// 子代理会话的父会话 id（官方 `session/list` 的 `parentSessionId`）。
  final String? parentSessionId;

  /// 官方 `agentAvailable`：父会话的 agent 是否仍在（子代理详情页可发消息的依据）。
  final bool agentAvailable;

  /// `projections.values.subagentCatalog`：官方子代理目录
  /// （`{id, createdAt, mode:'one-shot'|'continuable'|'unknown', label?}`）。
  /// rc.2 没有 `subagents/list`，列表要从这里派生。
  final List<Map<String, dynamic>> subagentCatalog;

  /// 会话统计栏的 billed 输入口径（官方 tokenUsage 三桶之和）。
  int get billedInputTokens =>
      uncachedInputTokens + cacheReadTokens + cacheWriteTokens;

  bool get hasBilling => billedInputTokens > 0 || outputTokens > 0;

  DshSessionSummary({
    required this.sessionId,
    this.title,
    required this.updatedAt,
    required this.running,
    required this.blank,
    this.cwd,
    this.agentPreset,
    this.turnCount = 0,
    this.stepCount = 0,
    this.isSubagent = false,
    this.searchSnippet,
    this.parentSessionId,
    this.agentAvailable = false,
    this.subagentCatalog = const [],
    this.llmMs = 0,
    this.toolMs = 0,
    this.ttftMs = 0,
    this.ttftSteps = 0,
    this.decodeMs = 0,
    this.decodeTokens = 0,
    this.uncachedInputTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
    this.outputTokens = 0,
  });

  factory DshSessionSummary.fromJson(Map<String, dynamic> j) {
    final projections = (j['projections'] as Map?)?.cast<String, dynamic>();
    final values =
        (projections?['values'] as Map?)?.cast<String, dynamic>() ?? const {};
    final stats = (values['sessionStats'] as Map?)?.cast<String, dynamic>();
    final usage =
        (values['tokenUsage'] as Map?)?.cast<String, dynamic>() ?? const {};
    return DshSessionSummary(
      sessionId: (j['sessionId'] ?? '').toString(),
      title: values['title']?.toString(),
      updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
      running: j['running'] == true,
      blank: j['blank'] == true,
      cwd: j['cwd']?.toString(),
      // 官方 schema 里 agentPreset 在 projections.values 下（顶层没有）。
      agentPreset:
          (values['agentPreset'] ?? j['agentPreset'])?.toString(),
      turnCount: (stats?['turns'] as num?)?.toInt() ?? 0,
      stepCount: (stats?['steps'] as num?)?.toInt() ?? 0,
      isSubagent: j['origin']?.toString() == 'subagent',
      parentSessionId: j['parentSessionId']?.toString(),
      agentAvailable: j['agentAvailable'] == true,
      subagentCatalog: ((values['subagentCatalog'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList(),
      llmMs: (stats?['llmMs'] as num?)?.toInt() ?? 0,
      toolMs: (stats?['toolMs'] as num?)?.toInt() ?? 0,
      ttftMs: (stats?['ttftMs'] as num?)?.toInt() ?? 0,
      ttftSteps: (stats?['ttftSteps'] as num?)?.toInt() ?? 0,
      decodeMs: (stats?['decodeMs'] as num?)?.toInt() ?? 0,
      decodeTokens: (stats?['decodeTokens'] as num?)?.toInt() ?? 0,
      uncachedInputTokens: (usage['uncachedInputTokens'] as num?)?.toInt() ?? 0,
      cacheReadTokens: (usage['cacheReadTokens'] as num?)?.toInt() ?? 0,
      cacheWriteTokens: (usage['cacheWriteTokens'] as num?)?.toInt() ?? 0,
      outputTokens: (usage['outputTokens'] as num?)?.toInt() ?? 0,
    );
  }

  DshSessionSummary withCwd(String? cwd) => DshSessionSummary(
    sessionId: sessionId,
    title: title,
    updatedAt: updatedAt,
    running: running,
    blank: blank,
    cwd: cwd,
    agentPreset: agentPreset,
    turnCount: turnCount,
    stepCount: stepCount,
    isSubagent: isSubagent,
    searchSnippet: searchSnippet,
    parentSessionId: parentSessionId,
    agentAvailable: agentAvailable,
    subagentCatalog: subagentCatalog,
    llmMs: llmMs,
    toolMs: toolMs,
    ttftMs: ttftMs,
    ttftSteps: ttftSteps,
    decodeMs: decodeMs,
    decodeTokens: decodeTokens,
    uncachedInputTokens: uncachedInputTokens,
    cacheReadTokens: cacheReadTokens,
    cacheWriteTokens: cacheWriteTokens,
    outputTokens: outputTokens,
  );

  /// 附上 `session/search` 的命中片段（其余字段照搬）。
  DshSessionSummary withSearchSnippet(String? snippet) => DshSessionSummary(
    sessionId: sessionId,
    title: title,
    updatedAt: updatedAt,
    running: running,
    blank: blank,
    cwd: cwd,
    agentPreset: agentPreset,
    turnCount: turnCount,
    stepCount: stepCount,
    isSubagent: isSubagent,
    searchSnippet: snippet,
    parentSessionId: parentSessionId,
    agentAvailable: agentAvailable,
    subagentCatalog: subagentCatalog,
    llmMs: llmMs,
    toolMs: toolMs,
    ttftMs: ttftMs,
    ttftSteps: ttftSteps,
    decodeMs: decodeMs,
    decodeTokens: decodeTokens,
    uncachedInputTokens: uncachedInputTokens,
    cacheReadTokens: cacheReadTokens,
    cacheWriteTokens: cacheWriteTokens,
    outputTokens: outputTokens,
  );

  /// 还原成 [fromJson] 可读的原始结构，供主页本地缓存使用。
  Map<String, dynamic> toJson() => {
    'sessionId': sessionId,
    'updatedAt': updatedAt,
    'running': running,
    'blank': blank,
    'cwd': cwd,
    'agentPreset': agentPreset,
    'origin': isSubagent ? 'subagent' : null,
    'parentSessionId': parentSessionId,
    'agentAvailable': agentAvailable,
    'projections': {
      'values': {
        'title': title,
        if (subagentCatalog.isNotEmpty) 'subagentCatalog': subagentCatalog,
        'sessionStats': {
          'turns': turnCount,
          'steps': stepCount,
          'llmMs': llmMs,
          'toolMs': toolMs,
          'ttftMs': ttftMs,
          'ttftSteps': ttftSteps,
          'decodeMs': decodeMs,
          'decodeTokens': decodeTokens,
        },
        'tokenUsage': {
          'uncachedInputTokens': uncachedInputTokens,
          'cacheReadTokens': cacheReadTokens,
          'cacheWriteTokens': cacheWriteTokens,
          'outputTokens': outputTokens,
        },
      },
    },
  };
}

/// DSH 模型目录条目（modelProviderGroup.models 行）。
class DshModelInfo {
  final String id;
  final String name;
  final String providerId;
  final String providerName;
  final int? contextWindow;
  final int? maxTokens;
  DshModelInfo({
    required this.id,
    required this.name,
    required this.providerId,
    required this.providerName,
    this.contextWindow,
    this.maxTokens,
  });
}

/// DSH 模型分组（llm.models / session.models 的 groups 行）。
class DshModelGroup {
  final String id;
  final String name;
  final List<DshModelInfo> models;
  DshModelGroup({required this.id, required this.name, required this.models});
}

/// 当前会话模型选择（session.models 的 current）。
class DshModelSelection {
  final String provider;
  final String model;
  final String? reasoningEffort;
  DshModelSelection({
    required this.provider,
    required this.model,
    this.reasoningEffort,
  });

  factory DshModelSelection.fromJson(Map<String, dynamic> j) =>
      DshModelSelection(
        provider: (j['provider'] ?? '').toString(),
        model: (j['model'] ?? '').toString(),
        reasoningEffort: j['reasoningEffort']?.toString(),
      );
}

/// Agent 预设条目（agentPreset.list 行）。
class DshPresetInfo {
  final String id;
  final String trust; // system | user
  final bool isDefault;
  final String? name;
  final String? description;

  /// 为什么无法装载（YAML 损坏 / 缺少 agent.cordis.yml 等），正常为空。
  final String? broken;
  DshPresetInfo({
    required this.id,
    required this.trust,
    required this.isDefault,
    this.name,
    this.description,
    this.broken,
  });

  factory DshPresetInfo.fromJson(Map<String, dynamic> j) => DshPresetInfo(
    id: (j['id'] ?? '').toString(),
    trust: (j['trust'] ?? 'user').toString(),
    isDefault: j['isDefault'] == true,
    name: j['name']?.toString(),
    description: j['description']?.toString(),
    broken: j['broken']?.toString(),
  );
}

/// 工作区条目（workspace.list 行）。
class DshWorkspace {
  final String workspaceId;
  final String path;
  final String title;
  final List<String> sessionIds;
  final String createdAt;
  final String updatedAt;
  DshWorkspace({
    required this.workspaceId,
    required this.path,
    required this.title,
    required this.sessionIds,
    required this.createdAt,
    required this.updatedAt,
  });

  factory DshWorkspace.fromJson(Map<String, dynamic> j) => DshWorkspace(
    workspaceId: (j['workspaceId'] ?? '').toString(),
    path: (j['path'] ?? '').toString(),
    title: (j['title'] ?? '').toString(),
    sessionIds: ((j['sessionIds'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList(),
    createdAt: (j['createdAt'] ?? '').toString(),
    updatedAt: (j['updatedAt'] ?? '').toString(),
  );

  Map<String, dynamic> toJson() => {
    'workspaceId': workspaceId,
    'path': path,
    'title': title,
    'sessionIds': sessionIds,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
  };

  DshWorkspace copyWith({List<String>? sessionIds}) => DshWorkspace(
    workspaceId: workspaceId,
    path: path,
    title: title,
    sessionIds: sessionIds ?? this.sessionIds,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}

/// 子代理条目（subagent.list 行）。
class DshSubagentEntry {
  final String sessionId;
  final String? title;
  final bool running;
  final int updatedAt;
  final int turnCount;
  final String kind;
  final String mode;
  final bool hasChildren;
  final String? reason;
  DshSubagentEntry({
    required this.sessionId,
    this.title,
    required this.running,
    required this.updatedAt,
    this.turnCount = 0,
    this.kind = 'child',
    this.mode = 'one-shot',
    this.hasChildren = false,
    this.reason,
  });

  factory DshSubagentEntry.fromJson(Map<String, dynamic> j) {
    final projections = (j['projections'] as Map?)?.cast<String, dynamic>();
    final values =
        (projections?['values'] as Map?)?.cast<String, dynamic>() ?? const {};
    return DshSubagentEntry(
      sessionId: (j['id'] ?? j['sessionId'] ?? '').toString(),
      title: j['label']?.toString() ?? values['title']?.toString(),
      running: j['activity'] == 'running' || j['running'] == true,
      updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
      turnCount:
          ((values['sessionStats'] as Map?)?['turns'] as num?)?.toInt() ?? 0,
      kind: (j['kind'] ?? 'child').toString(),
      mode: (j['mode'] ?? '').toString(),
      hasChildren: j['hasChildren'] == true,
      reason: j['reason']?.toString(),
    );
  }
}

/// 子代理历史包：消息 + 末尾未收口 live + 可选投影统计。
class DshSubagentHistoryBundle {
  final List<ChatMessage> messages;
  final DshLiveTurn live;
  final DshSessionSummary? summary;
  const DshSubagentHistoryBundle({
    required this.messages,
    required this.live,
    this.summary,
  });
}

/// 技能条目（skill.list 行）。
class DshSkillInfo {
  final String name;
  final String description;
  final String? whenToUse;
  final bool modelInvocable;
  DshSkillInfo({
    required this.name,
    required this.description,
    this.whenToUse,
    required this.modelInvocable,
  });

  factory DshSkillInfo.fromJson(Map<String, dynamic> j) => DshSkillInfo(
    name: (j['name'] ?? j['id'] ?? '').toString().trim(),
    description: (j['description'] ?? '').toString().trim(),
    whenToUse: j['whenToUse']?.toString().trim(),
    modelInvocable: j['modelInvocable'] != false,
  );
}

/// 凭据槽位（credentials.describe 行）。
class DshCredentialSlot {
  final List<String> path;
  final bool set;
  final bool writable;
  DshCredentialSlot({
    required this.path,
    required this.set,
    this.writable = true,
  });

  String get ref => path.isEmpty ? '' : path.last;
  String get label {
    switch (ref) {
      case 'SHIYI_API_KEY':
        return '拾忆模型 API Key';
      case 'SHIYI_DSH_SEARCH_KEY':
        return 'DSH 搜索 API Key';
      case 'DEEPSEEK_API_KEY':
        return 'DeepSeek API Key';
      default:
        return path.join(' › ');
    }
  }

  factory DshCredentialSlot.fromJson(Map<String, dynamic> j) =>
      DshCredentialSlot(
        path: _pathFromJson(j),
        set: j['set'] == true || j['configured'] == true,
        writable: j['writable'] != false,
      );

  static List<String> _pathFromJson(Map<String, dynamic> j) {
    final path = ((j['path'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();
    if (path.isNotEmpty) return path;
    final ref = (j['ref'] ?? '').toString();
    return ref.isEmpty ? const [] : [ref];
  }

  /// credentials.describe 返回 credentials 映射，而不是 slots 列表。
  static List<DshCredentialSlot> fromDescribeValue(Map<String, dynamic> v) {
    // rc.2 的 `credentials/describe` 返回**按 ref 键控的 record**：
    // `{ref: {configured, source?, writable}}`（schema 见 dsh-api-settings-controller）。
    // 旧版才包一层 `credentials` / `slots`；只认包装形状会让凭据列表永远为空
    // （见 docs/fix-log.md #396）。
    final raw = v['credentials'] ?? (v.containsKey('slots') ? null : v);
    if (raw is Map) {
      return raw.entries.map((e) {
        final info = (e.value is Map)
            ? Map<String, dynamic>.from(e.value as Map)
            : const <String, dynamic>{};
        return DshCredentialSlot(
          path: [e.key.toString()],
          set: info['configured'] == true,
          writable: info['writable'] != false,
        );
      }).toList();
    }
    final slots = (v['slots'] ?? const []) as List;
    return slots
        .map(
          (e) => DshCredentialSlot.fromJson((e as Map).cast<String, dynamic>()),
        )
        .toList();
  }
}

/// 工作区文件条目（`workspaceFiles/list`）。
class DshWorkspaceFileEntry {
  final String name;
  final String type; // file · directory · other
  final int? size;
  const DshWorkspaceFileEntry({
    required this.name,
    this.type = 'file',
    this.size,
  });

  bool get isDir => type == 'directory';

  factory DshWorkspaceFileEntry.fromJson(Map<String, dynamic> j) =>
      DshWorkspaceFileEntry(
        name: (j['name'] ?? '').toString(),
        type: (j['type'] ?? 'file').toString(),
        size: (j['size'] as num?)?.toInt(),
      );
}

/// 后台任务（`job/list` 一行）。
class DshJobInfo {
  final String id;
  final String kind;
  final String label;

  /// running · stopping · completed · failed · killed
  final String status;
  final String? progress;
  final String? detail;
  final int startedAt;
  final int? finishedAt;
  const DshJobInfo({
    required this.id,
    this.kind = '',
    this.label = '',
    this.status = '',
    this.progress,
    this.detail,
    this.startedAt = 0,
    this.finishedAt,
  });

  bool get running => status == 'running' || status == 'stopping';

  factory DshJobInfo.fromJson(Map<String, dynamic> j) => DshJobInfo(
    id: (j['id'] ?? '').toString(),
    kind: (j['kind'] ?? '').toString(),
    label: (j['label'] ?? '').toString(),
    status: (j['status'] ?? '').toString(),
    progress: j['progress']?.toString(),
    detail: j['detail']?.toString(),
    startedAt: (j['startedAt'] as num?)?.toInt() ?? 0,
    finishedAt: (j['finishedAt'] as num?)?.toInt(),
  );
}

/// 官方斜杠命令（`commands/list` 一行）。
class DshCommandInfo {
  final String name;
  final String description;

  /// 参数提示；非空表示要参数（选中后只填 `/name `，让用户补完再发）。
  final String hint;
  final bool acceptsAttachments;
  const DshCommandInfo({
    required this.name,
    this.description = '',
    this.hint = '',
    this.acceptsAttachments = false,
  });

  factory DshCommandInfo.fromJson(Map<String, dynamic> j) {
    final input = (j['input'] as Map?)?.cast<String, dynamic>();
    return DshCommandInfo(
      name: (j['name'] ?? '').toString(),
      description: (j['description'] ?? '').toString(),
      hint: (input?['hint'] ?? '').toString(),
      acceptsAttachments: input?['attachments'] == true,
    );
  }

  bool get needsArgs => hint.trim().isNotEmpty;
}

/// 出站图片附件（rc.2 `session/prompt` 的 image 块：直接内联 base64）。
class DshImageAttachment {
  /// image/png · image/jpeg · image/webp · image/gif（服务端只认这四种）。
  final String mediaType;
  final String base64;
  final String? name;
  const DshImageAttachment({
    required this.mediaType,
    required this.base64,
    this.name,
  });

  /// 按扩展名推断 mediaType；不认识的按 jpeg（服务端会拒就只能回退文本提示）。
  static String mediaTypeForPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/jpeg';
  }
}

/// 文件上传回执（`session/prompt` 的 file 块用 receiptId）。
class DshFileReceipt {
  final String receiptId;
  final String attachmentId;
  final String name;
  final int bytes;
  const DshFileReceipt({
    required this.receiptId,
    this.attachmentId = '',
    this.name = '',
    this.bytes = 0,
  });

  factory DshFileReceipt.fromJson(Map<String, dynamic> j) {
    final file = (j['file'] as Map?)?.cast<String, dynamic>() ?? const {};
    return DshFileReceipt(
      receiptId: (j['receiptId'] ?? '').toString(),
      attachmentId: (file['attachmentId'] ?? '').toString(),
      name: (file['name'] ?? '').toString(),
      bytes: (file['bytes'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 主机描述（host.describe）。
class DshHostInfo {
  final String platform;
  final String arch;
  final String cwd;
  final String home;
  final String version;
  final bool canOpenPath;
  final String? name;
  DshHostInfo({
    required this.platform,
    required this.arch,
    required this.cwd,
    this.home = '',
    this.version = '',
    this.canOpenPath = false,
    this.name,
  });

  factory DshHostInfo.fromJson(Map<String, dynamic> j) => DshHostInfo(
    platform: (j['platform'] ?? '').toString(),
    arch: (j['arch'] ?? '').toString(),
    cwd: (j['cwd'] ?? '').toString(),
    home: (j['home'] ?? '').toString(),
    version: (j['version'] ?? '').toString(),
    canOpenPath: j['canOpenPath'] == true,
    name: j['name']?.toString(),
  );
}

/// 目录条目（host.listDirectory 行）。
class DshDirEntry {
  final String name;
  final String path;
  final bool isDirectory;
  final bool hidden;
  final int? size;
  DshDirEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.hidden = false,
    this.size,
  });

  factory DshDirEntry.fromJson(Map<String, dynamic> j) => DshDirEntry(
    name: (j['name'] ?? j['basename'] ?? '').toString(),
    path: (j['path'] ?? j['fullPath'] ?? '').toString(),
    isDirectory:
        j['isDirectory'] == true ||
        j['kind'] == 'directory' ||
        (!j.containsKey('isDirectory') && !j.containsKey('kind')),
    hidden: j['hidden'] == true,
    size: (j['size'] as num?)?.toInt(),
  );
}

/// `host.listDirectory` 的完整目录快照。
class DshDirectoryListing {
  final String path;
  final String home;
  final List<DshDirEntry> crumbs;
  final List<DshDirEntry> entries;
  final bool truncated;

  const DshDirectoryListing({
    required this.path,
    required this.home,
    required this.crumbs,
    required this.entries,
    required this.truncated,
  });

  factory DshDirectoryListing.fromJson(Map<String, dynamic> j) {
    List<DshDirEntry> parse(dynamic raw) => raw is List
        ? raw
              .whereType<Map>()
              .map((e) => DshDirEntry.fromJson(e.cast<String, dynamic>()))
              .toList()
        : const <DshDirEntry>[];

    return DshDirectoryListing(
      path: (j['path'] ?? '').toString(),
      home: (j['home'] ?? '').toString(),
      crumbs: parse(j['crumbs']),
      entries: parse(j['items'] ?? j['entries']),
      truncated: j['truncated'] == true,
    );
  }
}

/// 探测当前 DSH 主机可访问的文件系统根目录。
///
/// DSH 目前没有独立的 host.listDrives RPC，因此 Windows 使用官方
/// host.listDirectory 逐个探测盘符；Unix-like 主机使用 `/` 作为根目录。
extension DshApiRootDirectoryScan on DshApiClient {
  Future<List<DshDirEntry>> scanRootDirectories({
    String platform = '',
    String pathHint = '',
  }) async {
    final isWindows = _looksLikeWindowsHost(platform, pathHint);
    final candidates = isWindows
        ? List<String>.generate(26, (i) => '${String.fromCharCode(65 + i)}:\\')
        : const ['/'];

    final results = await Future.wait(
      candidates.map((root) async {
        try {
          final listing = await directoryListing(
            root,
          ).timeout(const Duration(seconds: 3));
          return DshDirEntry(
            name: root,
            path: listing.path.isEmpty ? root : listing.path,
            isDirectory: true,
          );
        } catch (_) {
          return null;
        }
      }),
    );
    return results.whereType<DshDirEntry>().toList();
  }

  static bool _looksLikeWindowsHost(String platform, String pathHint) {
    final value = platform.trim().toLowerCase();
    if (value.contains('win')) return true;
    return RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(pathHint.trim());
  }
}

/// 设置命名空间（settings.describe 行）。
class DshSettingsNamespace {
  final String ns;
  final Map<String, dynamic> value;
  final Map<String, dynamic> base;
  final Map<String, dynamic> user;
  final List<DshCredentialSlot> secrets;
  final int revision;

  /// 命名空间的 schemastery 序列化 schema（{uid, refs} 引用图）。
  /// 旧版 DSH 可能不下发；只读展示用。
  final Map<String, dynamic> schema;
  DshSettingsNamespace({
    required this.ns,
    required this.value,
    this.base = const {},
    this.user = const {},
    required this.secrets,
    required this.revision,
    this.schema = const {},
  });
}

/// 权限预设可选项（permission 命名空间 schema 里 advertised 的表项）。
class DshPermissionPresetOption {
  final String key;
  final String label;
  const DshPermissionPresetOption({required this.key, required this.label});
}

/// 目标 DSH 的权限预设表（permissionPresets 服务）。
class DshPermissionPresets {
  final String defaultPreset;
  final int revision;
  final List<DshPermissionPresetOption> options;
  const DshPermissionPresets({
    required this.defaultPreset,
    required this.revision,
    required this.options,
  });
}

/// 目标 DSH 实时插件清单条目（pluginInventory/list）。
class DshPluginInventoryEntry {
  final String entryId;
  final String moduleName;
  final bool enabled;

  /// null / failed / pending / active / loading / unloading。
  final String fiberPhase;
  const DshPluginInventoryEntry({
    required this.entryId,
    required this.moduleName,
    required this.enabled,
    required this.fiberPhase,
  });

  factory DshPluginInventoryEntry.fromJson(Map<String, dynamic> j) =>
      DshPluginInventoryEntry(
        entryId: (j['entryId'] ?? '').toString(),
        moduleName: (j['moduleName'] ?? '').toString(),
        enabled: j['enabled'] == true,
        fiberPhase: j['fiberPhase']?.toString() ?? '',
      );
}

/// 目标引用（goal.* 的 ref）。
class DshGoalRef {
  final String goalId;
  final String objective;
  final String status; // active | paused | completed | cleared
  final int round;
  final int maxRounds;
  DshGoalRef({
    required this.goalId,
    required this.objective,
    required this.status,
    required this.round,
    required this.maxRounds,
  });

  factory DshGoalRef.fromJson(Map<String, dynamic> j) => DshGoalRef(
    goalId: (j['goalId'] ?? j['id'] ?? '').toString(),
    objective: (j['objective'] ?? '').toString(),
    status: (j['status'] ?? 'active').toString(),
    round: (j['round'] as num?)?.toInt() ?? 0,
    maxRounds: (j['maxRounds'] as num?)?.toInt() ?? 0,
  );
}

/// DSH 工具调用记录（会话消息重建时的附属数据）。
class DshToolCallInfo {
  final String callId;
  final String name;
  final String arguments;
  DshToolCallInfo({
    required this.callId,
    required this.name,
    this.arguments = '',
  });
}

class _DshRpcCall {
  final String endpoint;
  final String method;
  final Map<String, dynamic> payload;
  const _DshRpcCall(this.endpoint, this.method, this.payload);
}

/// DSH 会话客户端：会话列表 / 历史 / 发消息 / 新建。
/// 默认地址本机 http://127.0.0.1:3080；局域网 / 公网由 [configure] 切换。
class DshApiClient {
  DshApiClient({
    String baseUrl = DshEndpoint.localUrl,
    String token = '',
    String scopeKey = '',
    String hostOverride = '',
    List<String> customCompatibilityHosts = const [],
    List<String> compatibilityHosts = const [],
    http.Client? client,
  }) : _scopeKey = scopeKey.trim(),
       _baseUrl = DshEndpoint.stripSlash(baseUrl),
       _token = token.trim(),
       _configuredHostOverride = hostOverride.trim(),
       _customHostCandidates = _normalizeCompatibilityHosts(
         customCompatibilityHosts,
       ),
       _compatHostCandidates = _normalizeCompatibilityHosts(compatibilityHosts),
       _client = client ?? http.Client();

  /// 全局单例：会话列表与聊天页共享同一连接（避免重复探测/缓存丢失）。
  static final DshApiClient instance = DshApiClient();

  /// 打开会话与轮询时只读这么多条消息（官方 `session/page` 的 `maxMessages`）。
  ///
  /// 官方默认一页 50 条（`DEFAULT_MAX_MESSAGES`）。上千轮的长会话若一次性
  /// 把所有页拼成时间线，会在首帧和每一拍轮询里重复拉取/解析整段事件流，
  /// 这正是长会话卡顿的来源；改成只读尾部一页后，更早的消息交给
  /// [historyOlder] 按需翻页。
  static const int historyWindowMessages = 20;

  /// 窗口至少覆盖这么多轮（官方 `turnWindow.minTurns`），避免上翻停在半轮上。
  static const int historyWindowTurns = 12;

  /// `turnWindow.minMessages`：与 [historyWindowMessages] 一起交给官方分页器，
  /// 必须 ≤ [historyWindowMessages]。
  static const int historyWindowMinMessages = 6;

  /// 上翻补更早历史时每页取多少条消息。
  static const int historyOlderMessages = 40;

  String _baseUrl;
  final String _scopeKey;
  String _token;
  String _authCookie = '';
  String _remoteEventClientId = '';
  final Map<String, String> _remoteEventClientIds = {};
  String _preferredCwd = '';
  String _configuredHostOverride;
  List<String> _customHostCandidates;
  List<String> _compatHostCandidates;
  String? _compatHostOverride;
  final http.Client _client;
  static const Duration _timeout = Duration(seconds: 30);

  String get baseUrl => _baseUrl;
  String get token => _token;
  String get authCookie => _authCookie;
  String get scopeKey => _scopeKey;

  /// 切换当前连接。空地址表示尚未填好，RPC 会直接失败。
  void configure({
    String? baseUrl,
    String? token,
    String? hostOverride,
    List<String> customCompatibilityHosts = const [],
    List<String> compatibilityHosts = const [],
  }) {
    final nextHostOverride = hostOverride?.trim() ?? _configuredHostOverride;
    final nextCustomHosts = _normalizeCompatibilityHosts(
      customCompatibilityHosts,
    );
    final nextCompatibilityHosts = _normalizeCompatibilityHosts(
      compatibilityHosts,
    );
    if (baseUrl != null) {
      final next = DshEndpoint.stripSlash(baseUrl);
      if (next != _baseUrl ||
          nextHostOverride != _configuredHostOverride ||
          !_sameStrings(nextCustomHosts, _customHostCandidates) ||
          !_sameStrings(nextCompatibilityHosts, _compatHostCandidates)) {
        _compatHostOverride = null;
      }
      if (next != _baseUrl || nextHostOverride != _configuredHostOverride) {
        _authCookie = '';
        _remoteEventClientId = '';
        _remoteEventClientIds.clear();
      }
      _baseUrl = next;
    }
    _configuredHostOverride = nextHostOverride;
    _customHostCandidates = nextCustomHosts;
    _compatHostCandidates = nextCompatibilityHosts;
    if (token != null) {
      final nextToken = token.trim();
      if (nextToken != _token) _authCookie = '';
      _token = nextToken;
    }
  }

  static List<String> _normalizeCompatibilityHosts(Iterable<String> values) {
    final out = <String>[];
    for (final value in values) {
      final normalized = value.trim();
      if (normalized.isNotEmpty && !out.contains(normalized)) {
        out.add(normalized);
      }
    }
    return out;
  }

  static bool _sameStrings(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Map<String, String> _headers({String? hostOverride}) {
    final headers = <String, String>{'content-type': 'application/json'};
    final host = _effectiveHostOverride(hostOverride);
    if (host != null) {
      headers['host'] = host;
      headers['origin'] = _originForHost(host);
    }
    if (_authCookie.isNotEmpty) headers['cookie'] = _authCookie;
    final raw = _token.trim();
    if (raw.isNotEmpty) {
      headers['authorization'] = raw.toLowerCase().startsWith('bearer ')
          ? raw
          : 'Bearer $raw';
    }
    return headers;
  }

  Map<String, dynamic> _wsHeaders() {
    final headers = <String, dynamic>{};
    final host = _effectiveHostOverride(null);
    if (host != null) {
      headers['Host'] = host;
      headers['Origin'] = _originForHost(host);
    }
    if (_authCookie.isNotEmpty) headers['Cookie'] = _authCookie;
    final raw = _token.trim();
    if (raw.isNotEmpty) {
      headers['Authorization'] = raw.toLowerCase().startsWith('bearer ')
          ? raw
          : 'Bearer $raw';
    }
    return headers;
  }

  String? _effectiveHostOverride(String? explicit) {
    final value = explicit?.trim();
    if (value != null && value.isNotEmpty) return value;
    if (_configuredHostOverride.isNotEmpty) return _configuredHostOverride;
    final compatible = _compatHostOverride?.trim();
    return compatible == null || compatible.isEmpty ? null : compatible;
  }

  String _originForHost(String host) {
    final scheme = Uri.tryParse(_baseUrl)?.scheme == 'https' ? 'https' : 'http';
    return '$scheme://$host';
  }

  /// 仅供协议回归测试确认 WS 与 HTTP 使用同一身份头。
  Map<String, dynamic> debugWebSocketHeaders() => _wsHeaders();

  /// rc.2 起 Web 端发布进程级随机 Token，客户端先用根路径换取
  /// 签名 Cookie；HTTP RPC 与 WebSocket 共用该 Cookie。
  Future<bool> authenticateWithLaunchToken(String launchToken) async {
    final token = launchToken.trim();
    if (_baseUrl.isEmpty || token.isEmpty) return false;
    final base = Uri.parse(_baseUrl);
    var path = base.path;
    if (path.isEmpty) {
      path = '/';
    } else if (!path.endsWith('/')) {
      path = '$path/';
    }
    final exchange = base.replace(
      path: path,
      queryParameters: {'token': token},
    );
    final request = http.Request('GET', exchange)
      ..followRedirects = false
      ..headers.addAll(_headers());
    final response = await _client.send(request).timeout(_timeout);
    final rawCookie = response.headers['set-cookie'] ?? '';
    final cookie = parseDshAuthCookie(rawCookie);
    await response.stream.drain<void>();
    if (response.statusCode != 303 || cookie == null) return false;
    _authCookie = cookie;
    await _persistAuthCookie();
    return true;
  }

  /// 会话 Cookie 的落盘键。按连接 scope 隔离：地址 / 模式一换就是另一个 key，
  /// 不会把 A 主机的 Cookie 用到 B 主机上。
  static String authCookieStorageKey(String scopeKey) =>
      'shiyi_dsh_cookie|$scopeKey';

  static const FlutterSecureStorage _cookieStorage = FlutterSecureStorage();

  /// 复用上一次换到的会话 Cookie（应用重启后不必重新换）。
  ///
  /// 真机实测（docs/fix-log.md #395）：Cookie 只在内存里，应用一重启就丢；
  /// 而 DSH 的启动 Token 会随 activation 轮换，重换直接失败
  /// （`响应不是 303/Set-Cookie`）→ 局域网 401 再也连不上，只能重新粘链接。
  Future<bool> restoreAuthCookie() async {
    if (_scopeKey.isEmpty) return false;
    try {
      final stored = await _cookieStorage.read(
        key: authCookieStorageKey(_scopeKey),
      );
      if (stored == null || stored.isEmpty) return false;
      _authCookie = stored;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _persistAuthCookie() async {
    if (_scopeKey.isEmpty || _authCookie.isEmpty) return;
    try {
      await _cookieStorage.write(
        key: authCookieStorageKey(_scopeKey),
        value: _authCookie,
      );
    } catch (_) {}
  }

  /// 服务端拒绝了这个 Cookie（过期 / 宿主重启换了 secret）：内存和落盘都丢掉，
  /// 让下一次 `ensureRemoteSession` 重新用 Token 换。
  Future<void> _dropAuthCookie() async {
    _authCookie = '';
    if (_scopeKey.isEmpty) return;
    try {
      await _cookieStorage.delete(key: authCookieStorageKey(_scopeKey));
    } catch (_) {}
  }

  /// 从 Set-Cookie 头中只取 dsh-auth-* 的 name=value 对。
  static String? parseDshAuthCookie(String raw) {
    final match = RegExp(
      r'(?:^|,\s*)(dsh-auth-[A-Za-z0-9_-]+=[^;,\s]+)',
    ).firstMatch(raw);
    return match?.group(1);
  }

  /// 连接切换或主动停止时丢弃旧进程的浏览器会话。
  void clearAuthentication() {
    _authCookie = '';
  }

  static String _newRpcId() {
    final r = Random.secure();
    final hex = List.generate(
      16,
      (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Future<bool>? _rpcPingInFlight;

  /// RPC 就绪探测：比 GET / 严格，dsh 进程已监听但 API 未初始化完成时
  /// 仍算未就绪（否则页面会误判 running 去调接口挂 30 秒）。
  /// 并发合并：启动期多个页面同时轮询只发一个请求。
  Future<bool> rpcPing() {
    final existing = _rpcPingInFlight;
    if (existing != null) return existing;
    final done = _doRpcPing();
    _rpcPingInFlight = done;
    done.whenComplete(() => _rpcPingInFlight = null);
    return done;
  }

  Future<bool> _doRpcPing() async {
    if (_baseUrl.isEmpty) return false;
    try {
      await _rpc('session.list', {}).timeout(const Duration(seconds: 5));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Local DSH is launched with the app workspace as cwd; rc.2's directory
  /// picker lists home, so retain the launch cwd for file/default-path UI.
  void setPreferredCwd(String path) {
    _preferredCwd = path.trim();
  }

  /// 执行一次 RPC，返回 value（已断言 ok）。
  ///
  /// rc.2 的 Typert Remote 路由改成 `namespace/method`，参数走
  /// `payload.args`；这里集中做新协议优先、404 回退旧协议，业务层不需要
  /// 感知 DSH 版本。
  Future<Map<String, dynamic>> _rpc(
    String method,
    Map<String, dynamic> payload, {
    bool forceLegacy = false,
    Map<String, dynamic>? legacyPayload,
  }) async {
    final legacy = _legacyRpcCall(method, legacyPayload ?? payload);
    final modern = forceLegacy ? null : _modernRpcCall(method, payload);
    if (modern != null && !_sameRpcCall(modern, legacy)) {
      try {
        return await _rpcOnce(modern, method);
      } on DshApiException catch (error) {
        if (error.code != 'http-404') rethrow;
      }
    }
    return _rpcOnce(legacy, method);
  }

  Future<Map<String, dynamic>> _rpcOnce(_DshRpcCall call, String method) async {
    final started = DateTime.now();
    final requestId =
        'dshrpc_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    unawaited(
      RuntimeLogger.instance.info(
        'DSH',
        'rpc.started',
        requestId: requestId,
        data: {
          'method': method,
          'wireMethod': call.method,
          'endpoint': _safeEndpoint('$_baseUrl/api/${call.endpoint}'),
        },
      ),
    );
    final encoded = jsonEncode({
      'type': 'client-request',
      'rpcId': _newRpcId(),
      'method': call.method,
      'payload': call.payload,
    });
    http.Response res;
    try {
      res = await _client
          .post(
            Uri.parse('$_baseUrl/api/${call.endpoint}'),
            headers: _headers(),
            body: encoded,
          )
          .timeout(_timeout);
      if (res.statusCode == 401 && _authCookie.isNotEmpty) {
        // Cookie 过期 / 宿主重启换了 secret：丢掉（含落盘），
        // 让下一次 ensureRemoteSession 重新用 Token 换（#395）。
        unawaited(_dropAuthCookie());
      }
      if (res.statusCode == 403 &&
          _configuredHostOverride.isEmpty &&
          _compatHostOverride == null &&
          (method == 'session.list' ||
              method == 'workspace.list' ||
              method == 'settings.describe') &&
          (_customHostCandidates.isNotEmpty ||
              _compatHostCandidates.isNotEmpty)) {
        final custom = await _scanCompatibilityHosts(
          method: method,
          endpoint: call.endpoint,
          encoded: encoded,
          candidates: _customHostCandidates,
          allowEmpty: true,
        );
        final preset =
            custom ??
            await _scanCompatibilityHosts(
              method: method,
              endpoint: call.endpoint,
              encoded: encoded,
              candidates: _compatHostCandidates,
              allowEmpty: false,
            );
        if (preset != null) res = preset;
      }
    } catch (e) {
      unawaited(
        RuntimeLogger.instance.error(
          'DSH',
          'rpc.failed',
          requestId: requestId,
          durationMs: DateTime.now().difference(started).inMilliseconds,
          result: 'unreachable',
          data: {'method': method, 'error': '$e'},
        ),
      );
      throw DshApiException('DeepSeek Harness 服务不可达：$e');
    }
    if (res.statusCode != 200) {
      String? errorCode;
      String? errorMessage;
      try {
        final decoded = jsonDecode(utf8.decode(res.bodyBytes));
        final result = (decoded is Map ? decoded['result'] : null) as Map?;
        final error =
            (result?['error'] ?? (decoded is Map ? decoded['error'] : null))
                as Map?;
        errorCode = error?['code']?.toString();
        errorMessage = error?['message']?.toString();
      } catch (_) {}
      unawaited(
        RuntimeLogger.instance.warn(
          'DSH',
          'rpc.status',
          requestId: requestId,
          durationMs: DateTime.now().difference(started).inMilliseconds,
          result: 'HTTP ${res.statusCode}',
          data: {'method': method, 'statusCode': res.statusCode},
        ),
      );
      final trimmedError = errorMessage?.trim() ?? '';
      final suffix = trimmedError.isEmpty ? '' : '：$trimmedError';
      throw DshApiException(
        'DeepSeek Harness HTTP ${res.statusCode}$suffix',
        code: errorCode ?? 'http-${res.statusCode}',
      );
    }
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      unawaited(
        RuntimeLogger.instance.error(
          'DSH',
          'rpc.failed',
          requestId: requestId,
          durationMs: DateTime.now().difference(started).inMilliseconds,
          result: 'invalid_response',
          data: {'method': method, 'statusCode': res.statusCode},
        ),
      );
      throw DshApiException('DeepSeek Harness 响应解析失败');
    }
    final result = (body['result'] as Map?)?.cast<String, dynamic>();
    if (result == null) throw DshApiException('DeepSeek Harness 响应缺少 result');
    if (result['ok'] != true) {
      final err = (result['error'] as Map?)?.cast<String, dynamic>();
      unawaited(
        RuntimeLogger.instance.warn(
          'DSH',
          'rpc.rejected',
          requestId: requestId,
          durationMs: DateTime.now().difference(started).inMilliseconds,
          result: 'rejected',
          data: {
            'method': method,
            'code': err?['code']?.toString() ?? '',
            'error': err?['message']?.toString() ?? 'unknown',
          },
        ),
      );
      throw DshApiException(
        err?['message']?.toString() ?? '未知错误',
        code: err?['code']?.toString(),
      );
    }
    unawaited(
      RuntimeLogger.instance.info(
        'DSH',
        'rpc.completed',
        requestId: requestId,
        durationMs: DateTime.now().difference(started).inMilliseconds,
        result: 'ok',
        data: {'method': method, 'statusCode': res.statusCode},
      ),
    );
    return _normalizeRpcValue(method, result['value']);
  }

  static bool _sameRpcCall(_DshRpcCall a, _DshRpcCall b) {
    return a.endpoint == b.endpoint &&
        a.method == b.method &&
        jsonEncode(a.payload) == jsonEncode(b.payload);
  }

  static _DshRpcCall _legacyRpcCall(
    String method,
    Map<String, dynamic> payload,
  ) {
    if (method.contains('/')) {
      return _DshRpcCall(method, method, {'args': payload});
    }
    return _DshRpcCall(method, method, payload);
  }

  static _DshRpcCall? _modernRpcCall(
    String method,
    Map<String, dynamic> payload,
  ) {
    if (method.contains('/')) return null;
    _DshRpcCall call(String endpoint, Map<String, dynamic> args) =>
        _DshRpcCall(endpoint, endpoint, {'args': args});
    switch (method) {
      case 'session.list':
        return call('session/list', {'_request': payload});
      case 'session.create':
      case 'session.prompt':
      case 'session.rename':
      case 'session.search':
      case 'session.selectModel':
      case 'session.cancel':
        return call('session/${method.substring('session.'.length)}', {
          'request': payload,
        });
      case 'session.history':
        return call('session/page', {
          'request': historyPageRequest(
            address: {
              'kind': 'session',
              'sessionId': (payload['sessionId'] ?? '').toString(),
            },
            beforeSeq: (payload['beforeSeq'] as num?)?.toInt(),
            throughSeq: (payload['throughSeq'] as num?)?.toInt(),
            maxMessages: (payload['maxMessages'] as num?)?.toInt(),
            minMessages: (payload['minMessages'] as num?)?.toInt(),
            minTurns: (payload['minTurns'] as num?)?.toInt(),
          ),
        });
      case 'session.models':
      case 'llm.models':
        return call('session/modelCatalog', const {});
      case 'llm.providers':
        return call('llm/listConfigurableProviders', const {});
      case 'agentPreset.list':
        return call('agentPresets/list', const {});
      case 'agentPreset.select':
        return call('agentPresets/select', {
          'agentId': (payload['sessionId'] ?? '').toString(),
          'agentPreset': (payload['agentPreset'] ?? '').toString(),
        });
      case 'agentPreset.read':
        return call('agentPresets/read', {
          'agentPreset': (payload['agentPreset'] ?? '').toString(),
        });
      case 'agentPreset.copy':
        return call('agentPresets/copy', {
          'from': (payload['from'] ?? '').toString(),
          'id': (payload['agentPreset'] ?? '').toString(),
          if (payload['name'] != null) 'name': payload['name'],
        });
      case 'agentPreset.remove':
        return call('agentPresets/deletePreset', {
          'id': (payload['agentPreset'] ?? '').toString(),
        });
      case 'workspace.create':
      case 'workspace.rename':
      case 'workspace.delete':
      case 'workspace.insertBefore':
      case 'workspace.archiveSession':
      case 'workspace.insertSessionBefore':
      case 'workspace.unarchiveSession':
      case 'workspace.pinSession':
      case 'workspace.unpinSession':
        return call('workspace/${method.substring('workspace.'.length)}', {
          'request': payload,
        });
      case 'workspace.initializeDefault':
        return call('workspace/initializeDefault', const {});
      case 'terminal.list':
      case 'terminal.shells':
      case 'terminal.create':
      case 'terminal.write':
      case 'terminal.resize':
      case 'terminal.close':
      case 'terminal.rename':
      case 'terminal.retain':
      case 'terminal.environment':
        return call('terminal/${method.substring('terminal.'.length)}', payload);
      case 'schedule.list':
      case 'schedule.catalog':
      case 'schedule.history':
      case 'schedule.update':
      case 'schedule.delete':
        return call('schedule/${method.substring('schedule.'.length)}', payload);
      case 'messageFeedback.list':
      case 'messageFeedback.put':
      case 'messageFeedback.delete':
        // 目标的描述符只有一个 `request` 参数（不包就会被网关拒：
        // gateway/arguments-invalid: args fields do not match the descriptor）。
        return call(
          'messageFeedback/${method.substring('messageFeedback.'.length)}',
          {'request': payload},
        );
      case 'pluginManager.listPlugins':
      case 'pluginManager.listBundles':
      case 'pluginManager.inspect':
      case 'pluginManager.installBundle':
      case 'pluginManager.removeBundle':
      case 'pluginManager.setPluginEnabled':
      case 'pluginManager.setBundleEnabled':
      case 'pluginManager.registries':
      case 'pluginManager.listVersionExemptions':
      case 'pluginManager.setVersionExemption':
      case 'pluginManager.cancelInstall':
      case 'pluginManager.waitForInstall':
        return call(
          'pluginManager/${method.substring('pluginManager.'.length)}',
          payload,
        );
      case 'session.updateQueue':
      case 'session.fork':
        return call('session/${method.substring('session.'.length)}', {
          'request': payload,
        });
      case 'session.fileReferences':
        return call('fileReferences/list', payload);
      case 'session.referenceCandidates':
        return call('sessionReferenceResolver/candidates', payload);
      case 'permissionPresets.catalog':
        return call('permissionPresets/catalog', const {});
      case 'llm.discoverModels':
        return call('llm/discoverModels', payload);
      case 'subagent.history':
        return call('session/page', {
          'request': _sessionPageRequest(
            address: {
              'kind': 'subagent',
              'parentSessionId': (payload['parentSessionId'] ?? '').toString(),
              'childSessionId': (payload['childSessionId'] ?? '').toString(),
              'mode': (payload['mode'] ?? 'one-shot').toString(),
            },
            beforeSeq: (payload['beforeSeq'] as num?)?.toInt(),
            throughSeq: (payload['throughSeq'] as num?)?.toInt(),
            maxMessages: (payload['maxMessages'] as num?)?.toInt(),
          ),
        });
      case 'subagent.prompt':
        return call('subagents/prompt', {'request': payload});
      case 'subagent.interrupt':
        return call('subagents/interruptByParent', {
          'childSessionId': (payload['childSessionId'] ?? '').toString(),
          'parentSessionId': (payload['parentSessionId'] ?? '').toString(),
          'mode': (payload['mode'] ?? 'continuable').toString(),
        });
      case 'settings.openSettingsDocument':
      case 'settings.replace':
        return call('settings/${method.substring('settings.'.length)}', payload);
      case 'llm.listProviders':
        return call('llm/listProviders', const {});
      case 'officeToPdf.generation':
        return call('officeToPdf/generation', payload);
      case 'pluginRegistryProbe.fastest':
        return call('pluginRegistryProbe/fastest', const {});
      case 'sessionFeedback.record':
        return call('sessionFeedback/record', {'request': payload});
      case 'account.getState':
      case 'account.getProfile':
      case 'account.getBalance':
        return call('account/${method.substring('account.'.length)}', payload);
      case 'speech.catalog':
      case 'speech.prepare':
      case 'speech.cancelPreparation':
      case 'speech.transcribe':
      case 'speech.configure':
        return call('speech/${method.substring('speech.'.length)}', payload);
      case 'cordis.inventory':
      case 'cordis.invoke':
        return call(
          'dynamicCordisRunner/${method.substring('cordis.'.length)}',
          payload,
        );
      case 'officeToPdf.render':
        return call('officeToPdf/render', payload);
      case 'workspaceFiles.list':
      case 'workspaceFiles.read':
      case 'workspaceFiles.readBytes':
      case 'workspaceFiles.stat':
      case 'workspaceFiles.changes':
        return call(
          'workspaceFiles/${method.substring('workspaceFiles.'.length)}',
          payload,
        );
      case 'job.list':
      case 'job.kill':
      case 'job.follow':
        return call('job/${method.substring('job.'.length)}', {
          'request': payload,
        });
      case 'commands.list':
      case 'commands.execute':
        return call('commands/${method.substring('commands.'.length)}', payload);
      case 'fileUploads.upload':
        return call('fileUploads/upload', payload);
      case 'session.attachment':
        return call('session/attachment', {'request': payload});
      case 'skill.list':
        return call('skills/list', {'request': payload});
      case 'userQuestions.answer':
      case 'userQuestions.attachWait':
        return call(
          'userQuestions/${method.substring('userQuestions.'.length)}',
          payload,
        );
      case 'credentials.describe':
      case 'credentials.set':
      case 'credentials.unset':
        return call(
          'credentials/${method.substring('credentials.'.length)}',
          payload,
        );
      case 'settings.describe':
        return call('settings/describe', const {});
      case 'settings.update':
        return call('settings/update', payload);
      case 'settings.mutate':
        return call('settings/mutate', payload);
      case 'host.listDirectory':
        final path = payload['path']?.toString().trim() ?? '';
        return call('directoryPicker/list', {
          if (path.isNotEmpty) 'path': path,
        });
      case 'host.pickDirectory':
        return call('directoryPicker/pick', const {});
      case 'host.createDirectory':
        return call('directoryPicker/createDirectory', {
          'path': (payload['path'] ?? '').toString(),
          'name': (payload['name'] ?? '').toString(),
        });
      case 'host.openPath':
        // 官方 `session/openWorkspacePath` 的 wire 参数名是 `request`。
        return call('session/openWorkspacePath', {
          'request': {'path': (payload['path'] ?? '').toString()},
        });
      case 'goal.create':
        return call('goals/create', {
          'agentId': (payload['sessionId'] ?? '').toString(),
          'request': {
            'objective': payload['objective'],
            if (payload['maxGoalRounds'] != null)
              'maxGoalRounds': payload['maxGoalRounds'],
          },
        });
      case 'goal.edit':
        return call('goals/edit', {
          'agentId': (payload['sessionId'] ?? '').toString(),
          'ref': (payload['ref'] ?? '').toString(),
          'request': {
            'objective': payload['objective'],
            if (payload['maxGoalRounds'] != null)
              'maxGoalRounds': payload['maxGoalRounds'],
          },
        });
      case 'goal.pause':
      case 'goal.resume':
      case 'goal.complete':
      case 'goal.clear':
        return call('goals/${method.substring('goal.'.length)}', {
          'agentId': (payload['sessionId'] ?? '').toString(),
          'ref': (payload['ref'] ?? '').toString(),
        });
      default:
        return null;
    }
  }

  static Map<String, dynamic> _sessionPageRequest({
    required Map<String, dynamic> address,
    int? beforeSeq,
    int? throughSeq,
    int? maxMessages,
    int? minMessages,
    int? minTurns,
  }) {
    final limit = (maxMessages != null && maxMessages > 0) ? maxMessages : null;
    final window = limit == null
        ? null
        : {
            'minMessages':
                (minMessages == null ? limit : min(limit, max(1, minMessages)))
                    .toInt(),
            'minTurns': (minTurns == null || minTurns < 1) ? 1 : minTurns,
          };
    return {
      'address': address,
      // throughSeq is the fixed tail cursor for the whole pagination walk.
      // beforeSeq alone moves the upper bound and must not move this cursor.
      'throughSeq': throughSeq ?? -1,
      'beforeSeq': ?beforeSeq,
      'maxMessages': ?limit,
      // 官方 turnWindow：向后翻到至少 minTurns 轮 / minMessages 条，避免
      // 上翻时停在半轮上（validateHistoryWindow 要求 minMessages ≤ maxMessages）。
      if (window != null && minTurns != null) 'turnWindow': window,
    };
  }

  /// 官方 `session/page` 请求体的构造（对外暴露，便于单测断言窗口字段）。
  static Map<String, dynamic> historyPageRequest({
    required Map<String, dynamic> address,
    int? beforeSeq,
    int? throughSeq,
    int? maxMessages,
    int? minMessages,
    int? minTurns,
  }) => _sessionPageRequest(
    address: address,
    beforeSeq: beforeSeq,
    throughSeq: throughSeq,
    maxMessages: maxMessages,
    minMessages: minMessages,
    minTurns: minTurns,
  );

  static Map<String, dynamic> _normalizeRpcValue(String method, dynamic value) {
    if (value is Map) return value.cast<String, dynamic>();
    if (value is List) {
      if (method == 'llm.providers') return {'providers': value};
      return {'items': value};
    }
    if (value == null) return const {};
    if (value is String) return {'value': value, 'path': value};
    return {'value': value};
  }

  static String _safeEndpoint(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) return '<endpoint>';
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port${uri.path}';
  }

  Future<http.Response?> _scanCompatibilityHosts({
    required String method,
    required String endpoint,
    required String encoded,
    required List<String> candidates,
    required bool allowEmpty,
  }) async {
    for (final host in candidates) {
      try {
        final retry = await _client
            .post(
              Uri.parse('$_baseUrl/api/$endpoint'),
              headers: _headers(hostOverride: host),
              body: encoded,
            )
            .timeout(const Duration(seconds: 3));
        if (_isCompatibleDshResponse(retry, allowEmpty: allowEmpty)) {
          _compatHostOverride = host;
          return retry;
        }
        if (!allowEmpty &&
            method == 'session.list' &&
            _isCompatibleDshResponse(retry, allowEmpty: true)) {
          final workspaceProbe = await _client
              .post(
                Uri.parse('$_baseUrl/api/workspace.list'),
                headers: _headers(hostOverride: host),
                body: jsonEncode({
                  'type': 'client-request',
                  'rpcId': _newRpcId(),
                  'method': 'workspace.list',
                  'payload': const <String, dynamic>{},
                }),
              )
              .timeout(const Duration(seconds: 3));
          if (_isCompatibleDshResponse(workspaceProbe, allowEmpty: false)) {
            _compatHostOverride = host;
            return retry;
          }
        }
      } catch (_) {
        // 单个 Host 失败时继续扫描剩余预设。
      }
    }
    return null;
  }

  static bool _isCompatibleDshResponse(
    http.Response response, {
    required bool allowEmpty,
  }) {
    if (response.statusCode != 200) return false;
    try {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (body is! Map) return false;
      final result = body['result'];
      if (result is! Map || result['ok'] != true) return false;
      if (allowEmpty) return true;
      final value = result['value'];
      final items = value is Map ? value['items'] : null;
      return items is List && items.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// 会话列表（按 updatedAt 倒序；过滤子代理会话——它们由 agent 派生，
  /// 不应出现在用户会话列表）。
  Future<List<DshSessionSummary>> listSessions() async {
    final all = await listAllSessions();
    return all.where((s) => !s.isSubagent).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  /// 原始会话条目，**包含** `origin=subagent` 的子代理会话。
  ///
  /// [listSessions] 是给界面用的（滤掉子代理），子代理列表的派生需要全量
  /// （见 [deriveSubagents]）。
  Future<List<DshSessionSummary>> listAllSessions() async {
    final value = await _rpc('session.list', {});
    final items = (value['items'] as List?) ?? const [];
    return items
        .map(
          (e) => DshSessionSummary.fromJson(
            (e as Map).cast<String, dynamic>(),
          ),
        )
        .toList();
  }

  /// 新建或唤醒会话。传入 [sessionId] 会复用 DSH 已有会话并完成挂载。
  ///
  /// [workspaceId] 与 [cwd] 不能同时传（DSH 协议：`session.create accepts
  /// workspaceId or cwd, not both`）。带 [workspaceId] 时 DSH 用工作区路径
  /// 作为 cwd，并 `attachSession` 入账；只带 [cwd] 不会写入 `sessionIds`，
  /// 之后 `insertSessionBefore` 会因未入账失败。
  Future<String> createSession({
    String? agentPreset,
    String? cwd,
    String? sessionId,
    String? workspaceId,
  }) async {
    final payload = <String, dynamic>{};
    final workspace = workspaceId?.trim() ?? '';
    if (workspace.isNotEmpty) {
      payload['workspaceId'] = workspace;
    } else if (cwd != null && cwd.isNotEmpty) {
      payload['cwd'] = cwd;
    }
    if (sessionId != null && sessionId.trim().isNotEmpty) {
      payload['sessionId'] = sessionId.trim();
    }
    final preset = agentPreset?.trim() ?? '';
    if (preset.isNotEmpty) payload['agentPreset'] = preset;
    final value = await _rpc('session.create', payload);
    return (value['sessionId'] ?? '').toString();
  }

  /// 重命名会话。
  Future<void> renameSession(String sessionId, String title) async {
    await _rpc('session.rename', {'sessionId': sessionId, 'title': title});
  }

  /// 更新会话工作目录。
  ///
  /// 官方 SessionHeader.cwd 创建后不可改，没有 `session.update` /
  /// `session.setCwd`。这里仍试这两条猜测 RPC，失败再退回
  /// `insertSessionBefore`；跨工作区搬家不要走这条。
  Future<void> updateSessionCwd(String sessionId, String cwd) async {
    final path = cwd.trim();
    if (path.isEmpty) return;
    try {
      await _rpc('session.update', {'sessionId': sessionId, 'cwd': path});
      return;
    } catch (_) {
      // 继续尝试旧版命名，最终再用 workspace 关联兜底。
    }
    try {
      await _rpc('session.setCwd', {'sessionId': sessionId, 'cwd': path});
      return;
    } catch (_) {
      // 旧版没有单独 cwd RPC 时，至少把会话挂到选中的工作区。
    }
    final workspace = await createWorkspace(path);
    await insertSessionBefore(workspace.workspaceId, sessionId);
  }

  /// 发送消息（非阻塞：立即返回，agent 后台运行，轮询 history 收结果）。
  /// 发送消息。
  ///
  /// rc.2 的 `content` 三态（见 `session/prompt` schema 与 docs/dsh-parity.md）：
  /// - `{type:'text', text}`；
  /// - `{type:'image', mediaType, data}` —— **图片直接内联 base64，不用先上传**；
  /// - `{type:'file', receiptId}` —— 文件先走 [uploadFile] 换 receiptId。
  Future<void> prompt(
    String sessionId,
    String text, {
    List<DshImageAttachment> images = const [],
    List<String> fileReceiptIds = const [],
    String mode = 'queue',
  }) async {
    final content = <Map<String, dynamic>>[
      if (text.trim().isNotEmpty) {'type': 'text', 'text': text},
      for (final image in images)
        if (image.base64.isNotEmpty)
          {
            'type': 'image',
            'mediaType': image.mediaType,
            'data': image.base64,
            if ((image.name ?? '').isNotEmpty) 'name': image.name,
          },
      for (final id in fileReceiptIds)
        if (id.trim().isNotEmpty) {'type': 'file', 'receiptId': id.trim()},
    ];
    if (content.isEmpty) return;
    await _rpc('session.prompt', {
      'requestId': _newRpcId(),
      'sessionId': sessionId,
      'mode': mode,
      'content': content,
      'clientTimeZone': 'Asia/Shanghai',
    });
  }

  /// 上传文件换 receiptId（`session/prompt` 的 file 块用它）。
  ///
  /// 官方 `fileUploads/upload(agentId, {data, name})` → `{receiptId, file:{…}}`。
  Future<DshFileReceipt> uploadFile(
    String sessionId, {
    required String base64,
    String? name,
  }) async {
    final v = await _rpc('fileUploads.upload', {
      'agentId': sessionId,
      'request': {
        'data': base64,
        if ((name ?? '').isNotEmpty) 'name': name,
      },
    });
    return DshFileReceipt.fromJson(v);
  }

  // ── 官方能力补齐（⑥⑦）：工作区置顶/默认、队列、分叉、模型发现、
  //    定时任务、消息反馈、插件远端管理、目标机终端 ─────────────────────

  /// 取消归档：`workspace/unarchiveSession({sessionId})`。
  Future<List<String>> unarchiveSession(String sessionId) async {
    final v = await _rpc('workspace.unarchiveSession', {
      'sessionId': sessionId,
    });
    return ((v['archivedSessionIds'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();
  }

  /// 置顶 / 取消置顶会话：`workspace/pinSession` · `workspace/unpinSession`。
  Future<List<String>> pinSession(String sessionId, {bool pinned = true}) async {
    final v = await _rpc(
      pinned ? 'workspace.pinSession' : 'workspace.unpinSession',
      {'sessionId': sessionId},
    );
    return ((v['pinnedSessionIds'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();
  }

  /// 采用宿主默认工作区（`workspace/initializeDefault`，无参数）。
  Future<String> initializeDefaultWorkspace() async {
    final v = await _rpc('workspace.initializeDefault', const {});
    final workspace = (v['workspace'] as Map?)?.cast<String, dynamic>();
    return (workspace?['workspaceId'] ?? '').toString();
  }

  /// 刷新某个 provider 的模型目录：`llm/discoverModels(settingsNs, request)`。
  Future<Map<String, dynamic>> discoverModels(
    String settingsNs, {
    Map<String, dynamic> request = const {},
  }) async {
    return _rpc('llm.discoverModels', {
      'settingsNs': settingsNs,
      'request': request,
    });
  }

  /// 队列编辑（引导插话）：`session/updateQueue`。
  Future<void> updateQueue(
    String sessionId,
    String itemId,
    Map<String, dynamic> action,
  ) async {
    await _rpc('session.updateQueue', {
      'sessionId': sessionId,
      'itemId': itemId,
      'action': action,
    });
  }

  /// 会话分叉：`session/fork`。
  Future<String> forkSession(
    String sessionId, {
    Map<String, dynamic> request = const {},
  }) async {
    final v = await _rpc('session.fork', {'sessionId': sessionId, ...request});
    return (v['sessionId'] ?? '').toString();
  }

  /// @-引用候选：`fileReferences/list(agentId, query)`。
  Future<List<String>> listFileReferences(
    String sessionId,
    String query,
  ) async {
    final v = await _rpc('session.fileReferences', {
      'agentId': sessionId,
      'query': query,
    });
    final raw = v['items'] ?? v['references'] ?? v['value'];
    if (raw is! List) return const [];
    return raw
        .map((e) => e is Map ? (e['path'] ?? e['name'] ?? '').toString() : '$e')
        .where((e) => e.isNotEmpty)
        .toList();
  }

  /// 会话引用候选：`sessionReferenceResolver/candidates`。
  Future<List<Map<String, dynamic>>> sessionReferenceCandidates(
    String sessionId,
    String query,
  ) async {
    final v = await _rpc('session.referenceCandidates', {
      'agentId': sessionId,
      'query': query,
    });
    final raw = v['items'] ?? v['candidates'] ?? v['value'];
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  /// 权限预设目录：`permissionPresets/catalog`（比从 settings.describe 猜更准）。
  Future<List<Map<String, dynamic>>> permissionPresetCatalog() async {
    final v = await _rpc('permissionPresets.catalog', const {});
    final raw = v['items'] ?? v['presets'] ?? v['value'];
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  /// 定时任务：`schedule/list|catalog|history|update|delete`。
  Future<List<Map<String, dynamic>>> listSchedules(
    String sessionId,
  ) async {
    final v = await _rpc('schedule.list', {'agentId': sessionId});
    final raw = v['items'] ?? v['schedules'] ?? v['value'];
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  Future<void> deleteSchedule(String sessionId, String id) async {
    await _rpc('schedule.delete', {'agentId': sessionId, 'id': id});
  }

  /// 消息反馈：`messageFeedback/list|put|delete`。
  Future<List<Map<String, dynamic>>> listMessageFeedback(
    String sessionId,
  ) async {
    final v = await _rpc('messageFeedback.list', {'sessionId': sessionId});
    final raw = v['items'] ?? v['feedback'] ?? v['value'];
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  /// 删除一条消息反馈：`messageFeedback/delete({sessionId,messageId})`。
  Future<void> deleteMessageFeedback(
    String sessionId,
    String messageId,
  ) async {
    await _rpc('messageFeedback.delete', {
      'sessionId': sessionId,
      'messageId': messageId,
    });
  }

  /// 消息反馈：`messageFeedback/put({sessionId,messageId,rating,note?,category?,ifVersion})`。
  ///
  /// `rating` 只有 `positive` / `negative`（官方 schema），不是自由文本。
  Future<void> putMessageFeedback(
    String sessionId,
    String messageId, {
    required String rating,
    String? note,
    String? category,
    String? ifVersion,
  }) async {
    await _rpc('messageFeedback.put', {
      'sessionId': sessionId,
      'messageId': messageId,
      'rating': rating,
      if ((note ?? '').isNotEmpty) 'note': note,
      if ((category ?? '').isNotEmpty) 'category': category,
      'ifVersion': ?ifVersion,
    });
  }

  /// 插件远端管理：`pluginManager/listPlugins`（无参数）与启停。
  Future<Map<String, dynamic>> pluginManagerList() async {
    return _rpc('pluginManager.listPlugins', const {});
  }

  /// 启用 / 停用插件：`pluginManager/setPluginEnabled(id, enabled)`
  /// —— **不需要会话 id**（wire 只有 id + enabled）。
  Future<void> setPluginEnabled(String id, bool enabled) async {
    await _rpc('pluginManager.setPluginEnabled', {
      'id': id,
      'enabled': enabled,
    });
  }

  /// 目标机终端：`terminal/list(sessionId)` / `terminal/create` / `write` / `resize` / `close`。
  Future<List<Map<String, dynamic>>> listTerminals(String sessionId) async {
    final v = await _rpc('terminal.list', {'sessionId': sessionId});
    final raw = v['items'] ?? v['terminals'] ?? v['value'];
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  Future<Map<String, dynamic>> createTerminal(
    String sessionId, {
    Map<String, dynamic> request = const {},
  }) async {
    return _rpc('terminal.create', {
      'agentId': sessionId,
      'request': request,
    });
  }

  Future<void> writeTerminal(
    String sessionId,
    String id,
    String data, {
    String? attachmentId,
  }) async {
    await _rpc('terminal.write', {
      'agentId': sessionId,
      'id': id,
      if ((attachmentId ?? '').isNotEmpty) 'attachmentId': attachmentId,
      'data': data,
    });
  }

  Future<void> resizeTerminal(
    String sessionId,
    String id, {
    required int cols,
    required int rows,
    String? attachmentId,
  }) async {
    await _rpc('terminal.resize', {
      'agentId': sessionId,
      'id': id,
      if ((attachmentId ?? '').isNotEmpty) 'attachmentId': attachmentId,
      'cols': cols,
      'rows': rows,
    });
  }

  Future<void> closeTerminal(String sessionId, String id) async {
    await _rpc('terminal.close', {'agentId': sessionId, 'id': id});
  }

  /// 目标机终端下行（`terminal/follow`，**stream**）。
  ///
  /// 帧：`snapshot{screen}` → `output{data}` → `state`/`retained`。
  /// 注意这是 WS 流：局域网 8080 转发层不做隧道（#392）→ 只有本机模式收得到。
  Stream<Map<String, dynamic>> watchTerminal(
    String sessionId,
    String id, {
    String? attachmentId,
  }) => DshWsDownlink.openRemoteStream(
    _baseUrl,
    'terminal/follow',
    {
      'agentId': sessionId,
      'id': id,
      if ((attachmentId ?? '').isNotEmpty) 'attachmentId': attachmentId,
    },
    headers: _wsHeaders(),
  ).where((e) => e is Map).map((e) => (e as Map).cast<String, dynamic>());

  // ── 语音转写（experimental）/ PDF / Cordis 动态插件 ────────────────────
  //
  // 说明（docs/dsh-parity.md ⑦）：
  // - `account/*` 的 getState/getBalance 需要服务端注入的 `client` 查找参数，
  //   原始 RPC 造不出来 → 暂不接。
  // - `speech/follow` 是 stream（WS），局域网收不到，只接 unary 的这几个。
  // - `officeToPdf/render` 返回二进制，交给调用方自行处理。

  /// 语音转写能力目录：`speech/catalog`（无参数）。
  Future<List<Map<String, dynamic>>> speechCatalog() async {
    final v = await _rpc('speech.catalog', const {});
    final raw = v['items'] ?? v['providers'] ?? v['value'];
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  /// 准备语音识别器：`speech/prepare(providerId)`。
  Future<Map<String, dynamic>> prepareSpeech(String providerId) async {
    return _rpc('speech.prepare', {'providerId': providerId});
  }

  /// 取消准备：`speech/cancelPreparation(providerId)`。
  Future<void> cancelSpeechPreparation(String providerId) async {
    await _rpc('speech.cancelPreparation', {'providerId': providerId});
  }

  /// 转写一段音频：`speech/transcribe(request)`。
  Future<Map<String, dynamic>> transcribeSpeech(
    Map<String, dynamic> request,
  ) async {
    return _rpc('speech.transcribe', {'request': request});
  }

  /// 动态 Cordis 插件清单（只读）：`dynamicCordisRunner/inventory`。
  Future<Map<String, dynamic>> cordisInventory() async {
    return _rpc('cordis.inventory', const {});
  }

  /// Office → PDF：`officeToPdf/render(request)`。
  Future<Map<String, dynamic>> renderOfficeToPdf(
    Map<String, dynamic> request,
  ) async {
    return _rpc('officeToPdf.render', {'request': request});
  }

  /// 所有已注册 provider：`llm/listProviders`（无参数）→ `[{id,name}]`。
  Future<List<Map<String, dynamic>>> listAllProviders() async {
    final v = await _rpc('llm.listProviders', const {});
    final raw = v['items'] ?? v['value'];
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  /// Office→PDF 生成状态：`officeToPdf/generation(workspaceFileScopeId, path, priority)`。
  Future<Map<String, dynamic>> officeToPdfGeneration(
    String sessionId,
    String path, {
    int? priority,
  }) async {
    return _rpc('officeToPdf.generation', {
      'workspaceFileScopeId': sessionId,
      'path': path,
      'priority': ?priority,
    });
  }

  /// 最快的插件镜像源：`pluginRegistryProbe/fastest`（无参数）→ url | null。
  Future<String?> fastestPluginRegistry() async {
    final v = await _rpc('pluginRegistryProbe.fastest', const {});
    final url = (v['value'] ?? v['url'] ?? '').toString();
    return url.isEmpty ? null : url;
  }

  /// 会话级反馈：`sessionFeedback/record({sessionId, text?, category?})`。
  Future<bool> recordSessionFeedback(
    String sessionId, {
    String? text,
    String? category,
  }) async {
    final v = await _rpc('sessionFeedback.record', {
      'sessionId': sessionId,
      if ((text ?? '').isNotEmpty) 'text': text,
      if ((category ?? '').isNotEmpty) 'category': category,
    });
    return v['recorded'] == true;
  }

  /// 读某命名空间的设置文档原文：`settings/openSettingsDocument(ns)`。
  Future<String> openSettingsDocument(String ns) async {
    final v = await _rpc('settings.openSettingsDocument', {'ns': ns});
    return (v['text'] ?? v['document'] ?? v['value'] ?? '').toString();
  }

  /// 覆盖写入某命名空间的一段：`settings/replace(ns, section)`。
  Future<void> replaceSettings(
    String ns,
    Map<String, dynamic> section,
  ) async {
    await _rpc('settings.replace', {'ns': ns, 'section': section});
  }

  /// DSH 自有账号状态：`account/getState(client)`。
  ///
  /// `client` 是**官方客户端标识对象**（wire 上是 json 参数，不是服务端查找）。
  /// 拾忆用自己的 API Key，没有这套 DeepSeek 账号登录 UI，所以只保证接口可达：
  /// 需要时由调用方传官方形状的 client。
  Future<Map<String, dynamic>> accountState(Map<String, dynamic> client) async {
    return _rpc('account.getState', {'client': client});
  }

  /// 账号资料 / 余额：`account/getProfile` · `account/getBalance`（同样要 client）。
  Future<Map<String, dynamic>> accountProfile(
    Map<String, dynamic> client,
  ) async {
    return _rpc('account.getProfile', {'client': client});
  }

  Future<Map<String, dynamic>> accountBalance(
    Map<String, dynamic> client,
  ) async {
    return _rpc('account.getBalance', {'client': client});
  }

  /// 读会话附件（`session/attachment(sessionId, attachmentId)`）：
  /// 返回附件元信息 + base64 数据（历史里的图片靠它取回）。
  Future<({Map<String, dynamic> attachment, String data})> readAttachment(
    String sessionId,
    String attachmentId,
  ) async {
    final v = await _rpc('session.attachment', {
      'sessionId': sessionId,
      'attachmentId': attachmentId,
    });
    return (
      attachment: (v['attachment'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{},
      data: (v['data'] ?? '').toString(),
    );
  }

  /// 会话工作区文件清单：`workspaceFiles/list(sessionId, path)`。
  ///
  /// 官方侧边栏就是这条（scopeId 就是会话 id）；和目录选择器
  /// (`directoryPicker/list`) 不同，它只在会话工作区内、带 truncated。
  Future<({String path, List<DshWorkspaceFileEntry> entries, bool truncated})>
  listWorkspaceFiles(String sessionId, [String path = '']) async {
    final v = await _rpc('workspaceFiles.list', {
      'workspaceFileScopeId': sessionId,
      'path': path,
    });
    return (
      path: (v['path'] ?? path).toString(),
      entries: ((v['entries'] as List?) ?? const [])
          .whereType<Map>()
          .map(
            (e) => DshWorkspaceFileEntry.fromJson(e.cast<String, dynamic>()),
          )
          .toList(),
      truncated: v['truncated'] == true,
    );
  }

  /// 读工作区文本文件：`workspaceFiles/read(scopeId, path, range?)`。
  Future<({String text, bool eof, String absolutePath, int lines})>
  readWorkspaceFile(
    String sessionId,
    String path, {
    int? offset,
    int? length,
  }) async {
    final v = await _rpc('workspaceFiles.read', {
      'workspaceFileScopeId': sessionId,
      'path': path,
      'range': {'offset': ?offset, 'length': ?length},
    });
    return (
      text: (v['text'] ?? '').toString(),
      eof: v['eof'] == true,
      absolutePath: (v['absolutePath'] ?? '').toString(),
      lines: (v['lines'] as num?)?.toInt() ?? 0,
    );
  }

  /// 读工作区二进制（图片预览等）：`workspaceFiles/readBytes`。
  ///
  /// 线上是 base64 字符串，这里直接解回字节。
  Future<Uint8List> readWorkspaceFileBytes(
    String sessionId,
    String path, {
    int? offset,
    int? length,
  }) async {
    final v = await _rpc('workspaceFiles.readBytes', {
      'workspaceFileScopeId': sessionId,
      'path': path,
      'options': {'offset': ?offset, 'length': ?length},
    });
    final raw = (v['data'] ?? '').toString();
    if (raw.isEmpty) return Uint8List(0);
    try {
      return base64Decode(raw);
    } catch (_) {
      return Uint8List(0);
    }
  }

  /// 工作区文件元信息：`workspaceFiles/stat`。
  Future<({String absolutePath, int bytes})> statWorkspaceFile(
    String sessionId,
    String path,
  ) async {
    final v = await _rpc('workspaceFiles.stat', {
      'workspaceFileScopeId': sessionId,
      'path': path,
    });
    return (
      absolutePath: (v['absolutePath'] ?? '').toString(),
      bytes: (v['bytes'] as num?)?.toInt() ?? 0,
    );
  }

  /// 后台任务清单：`job/list({sessionId})` → `{type:'rows', jobs:[…]}`。
  /// 后台任务清单。
  ///
  /// ⚠️ 目标 DSH 里 `job/list` 的 `mode` 是 **stream**：必须走 WS mux，
  /// 当 unary POST 打会被网关拒（`gateway/signature-invalid: stream Remote
  /// methods must be opened through…`）。所以这里只读第一帧；**mux 不可用
  /// （局域网 8080 不做 WS 隧道）时返回空**，调用方不该在这时来拉。
  /// 见 docs/fix-log.md #403。
  Future<List<DshJobInfo>> listJobs(String sessionId) async {
    final frame = await DshWsDownlink.openRemoteStream(
      _baseUrl,
      'job/list',
      {
        'request': {'sessionId': sessionId},
      },
      headers: _wsHeaders(),
    ).firstWhere((e) => e is Map).timeout(const Duration(seconds: 6));
    final v = (frame as Map).cast<String, dynamic>();
    return ((v['jobs'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => DshJobInfo.fromJson(e.cast<String, dynamic>()))
        .where((j) => j.id.isNotEmpty)
        .toList();
  }

  /// 结束一个后台任务：`job/kill({sessionId, jobId})`。
  Future<String> killJob(String sessionId, String jobId) async {
    final v = await _rpc('job.kill', {
      'sessionId': sessionId,
      'jobId': jobId,
    });
    return (v['outcome'] ?? '').toString();
  }

  /// 官方斜杠命令清单：`commands/list(agentId)`。
  ///
  /// 返回 `[{name, description, input?:{hint, attachments?}}]`；`input` 为空表示
  /// 这条命令不带参数（可直接执行），否则把 `/name ` 填进输入框让用户补参数。
  Future<List<DshCommandInfo>> listCommands(String sessionId) async {
    final v = await _rpc('commands.list', {'agentId': sessionId});
    final raw = v['value'] ?? v['items'] ?? v['commands'];
    final list = raw is List ? raw : const [];
    return list
        .whereType<Map>()
        .map((e) => DshCommandInfo.fromJson(e.cast<String, dynamic>()))
        .where((c) => c.name.isNotEmpty)
        .toList();
  }

  /// Execute an official DSH command without routing it through session.prompt.
  Future<DshCommandExecution> executeCommand({
    required String sessionId,
    required String line,
    List<Map<String, dynamic>> submittedAttachments = const [],
  }) async {
    final value = await _rpc('commands.execute', {
      'agentId': sessionId,
      'line': line,
      'submittedAttachments': submittedAttachments,
    });
    return DshCommandExecution.fromJson(value);
  }

  Future<DshCommandExecution> compactSession(String sessionId) =>
      executeCommand(sessionId: sessionId, line: '/compact');

  /// 停止当前正在运行的 agent 回合（session.cancel）。
  Future<void> cancel(String sessionId) async {
    await _rpc('session.cancel', {'sessionId': sessionId});
  }

  /// 应答 DSH 下行的 question/requested。
  ///
  /// 顺序：
  /// 1. waterfall `$events/result`（remote-events WS 给了 clientId 时，官方就是
  ///    在这条事件通道上应答的）；
  /// 2. **rc.2 官方 `userQuestions/answer`**（agent 作用域、纯 HTTP）—— 局域网
  ///    没有 WS（8080 转发层不做隧道）时这是唯一答得通的路径；
  /// 3. 旧版 `POST /api/respond`。
  Future<void> answerQuestion(
    String rpcId,
    String sessionId,
    List<Map<String, dynamic>> answers, {
    String? callId,
  }) async {
    final clientId = _remoteEventClientIds[rpcId];
    if (clientId != null && clientId.isNotEmpty) {
      await _rpc(r'$events/result', {
        'clientId': clientId,
        'eventId': rpcId,
        'outcome': {
          'kind': 'result',
          'value': {'answers': answers},
        },
      });
      _remoteEventClientIds.remove(rpcId);
      return;
    }
    final id = (callId ?? rpcId).trim();
    if (id.isNotEmpty && sessionId.trim().isNotEmpty) {
      try {
        await _rpc('userQuestions.answer', {
          'agentId': sessionId,
          'callId': id,
          'answer': {'answers': answers},
        });
        return;
      } catch (_) {
        // 旧版没有这个端点：落到 legacy respond。
      }
    }
    await _respond(rpcId, {
      'ok': true,
      'value': {
        'sessionId': sessionId,
        'answer': {'answers': answers},
      },
    });
  }

  /// 取消 DSH 提问（result.ok=false，error code=cancelled）。
  Future<void> cancelQuestion(String rpcId) async {
    final answered = await _respondRemoteEvent(rpcId, {
      'kind': 'rejected',
      'error': {
        'name': 'Error',
        'code': 'ASK_CANCELLED',
        'message': 'the user cancelled ask_user_question',
      },
    });
    if (answered) return;
    await _respond(rpcId, {
      'ok': false,
      'error': {
        'code': 'cancelled',
        'message': 'the user closed this question request',
        'details': <String, dynamic>{},
      },
    });
  }

  Future<bool> _respondRemoteEvent(
    String rpcId,
    Map<String, dynamic> outcome,
  ) async {
    final clientId = _remoteEventClientIds[rpcId];
    if (clientId == null || clientId.isEmpty) return false;
    await _rpc(r'$events/result', {
      'clientId': clientId,
      'eventId': rpcId,
      'outcome': outcome,
    });
    _remoteEventClientIds.remove(rpcId);
    return true;
  }

  Future<void> _respond(String rpcId, Map<String, dynamic> result) async {
    final http.Response res;
    try {
      res = await _client
          .post(
            Uri.parse('$_baseUrl/api/respond'),
            headers: _headers(),
            body: jsonEncode({
              'type': 'client-response',
              'rpcId': rpcId,
              'result': result,
            }),
          )
          .timeout(_timeout);
    } catch (e) {
      throw DshApiException('DeepSeek Harness 应答失败：$e');
    }
    if (res.statusCode != 200) {
      throw DshApiException('DeepSeek Harness HTTP ${res.statusCode}');
    }
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw DshApiException('DeepSeek Harness 应答响应解析失败');
    }
    if (body['accepted'] != true) {
      throw DshApiException(
        'DeepSeek Harness 未接受应答',
        code: body['reason']?.toString(),
      );
    }
  }

  // ── 模型域 ────────────────────────────────────────────────────────────

  /// 会话可用模型（分组目录 + 当前选择）。
  Future<({DshModelSelection current, List<DshModelGroup> groups})>
  sessionModels(String sessionId) async {
    final v = await _rpc('session.models', {'sessionId': sessionId});
    final selected = (v['current'] as Map?)?.cast<String, dynamic>();
    if (selected != null) {
      return (
        current: DshModelSelection.fromJson(selected),
        groups: _parseModelGroups(v['groups']),
      );
    }
    final fallback = (v['default'] as Map?)?.cast<String, dynamic>();
    var current = DshModelSelection.fromJson(fallback ?? const {});
    try {
      final list = await _rpc('session.list', const {});
      for (final raw in (list['items'] as List?) ?? const []) {
        final item = (raw as Map).cast<String, dynamic>();
        if (item['sessionId']?.toString() != sessionId) continue;
        final projections = (item['projections'] as Map?)
            ?.cast<String, dynamic>();
        final values = (projections?['values'] as Map?)
            ?.cast<String, dynamic>();
        final model = (values?['modelSelection'] as Map?)
            ?.cast<String, dynamic>();
        final next = (model?['next'] ?? model?['lastUsed']);
        if (next is Map) {
          current = DshModelSelection.fromJson(next.cast<String, dynamic>());
        }
        break;
      }
    } catch (_) {}
    return (current: current, groups: _parseModelGroups(v['groups']));
  }

  /// 切换会话模型。
  Future<DshModelSelection> selectModel(
    String sessionId,
    String provider,
    String model, {
    String? reasoningEffort,
  }) async {
    final v = await _rpc('session.selectModel', {
      'sessionId': sessionId,
      'provider': provider,
      'model': model,
      if (reasoningEffort != null && reasoningEffort.isNotEmpty)
        'reasoningEffort': reasoningEffort,
    });
    final selection = DshModelSelection.fromJson(
      (v['selected'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
    // 服务端回执进审计：排查「公网端模型没有立即变化」时，这里能看到
    // 远端到底承认了什么（200 不等于真的换过去了）。
    unawaited(
      RuntimeLogger.instance.info(
        'DSH',
        'session_model.selected',
        sessionId: sessionId,
        data: {
          'provider': selection.provider,
          'model': selection.model,
          'reasoningEffort': selection.reasoningEffort ?? '',
        },
      ),
    );
    return selection;
  }

  /// 目标 provider/model 不支持所请求思考档位的服务端拒绝
  /// （例如 `model "X" does not support reasoning effort "high"`）。
  /// 切模型时的降级重试判定：静态思考目录只是客户端猜测，服务端声明
  /// 才是权威——被这类拒绝时应去掉档位重试，而不是让整个切换失败。
  static bool isReasoningEffortRejection(String message) =>
      message.contains('does not support reasoning effort') ||
      message.contains('unsupported reasoning effort') ||
      message.contains('reasoning effort') && message.contains('not support');

  /// 全量模型目录（llm.models，跨提供方）。
  Future<List<DshModelGroup>> llmModels() async {
    final v = await _rpc('llm.models', {});
    return _parseModelGroups(v['groups']);
  }

  /// 可配置的模型提供方（llm.providers）。
  Future<List<Map<String, dynamic>>> llmProviders() async {
    final v = await _rpc('llm.providers', {});
    if (!v.containsKey('providers')) {
      throw DshApiException('目标 DSH 未返回 provider 目录', code: 'unsupported');
    }
    final raw = v['providers'];
    if (raw is List) {
      return raw.whereType<Map>().map((e) {
        final item = e.cast<String, dynamic>();
        final provider = item['provider']?.toString() ?? '';
        return {
          ...item,
          if (!item.containsKey('id') && provider.isNotEmpty) 'id': provider,
          if (!item.containsKey('name') && item['displayName'] != null)
            'name': item['displayName'],
        };
      }).toList();
    }
    if (raw is Map) {
      return [
        for (final entry in raw.entries)
          if (entry.value is Map)
            {
              'id': entry.key.toString(),
              ...(entry.value as Map).cast<String, dynamic>(),
            },
      ];
    }
    return const [];
  }

  static List<DshModelGroup> _parseModelGroups(dynamic raw) {
    final entries = raw is List
        ? raw
        : raw is Map
        ? raw.entries
              .where((e) => e.value is Map)
              .map((e) => {'id': e.key.toString(), ...e.value as Map})
              .toList()
        : const <dynamic>[];
    return entries.map((e) {
      final g = (e as Map).cast<String, dynamic>();
      final models = ((g['models'] as List?) ?? const []).map((m) {
        final mm = (m as Map).cast<String, dynamic>();
        return DshModelInfo(
          id: (mm['id'] ?? '').toString(),
          name: (mm['name'] ?? mm['id'] ?? '').toString(),
          providerId: (mm['providerId'] ?? g['id'] ?? '').toString(),
          providerName: (mm['providerName'] ?? g['name'] ?? '').toString(),
          contextWindow: (mm['contextWindow'] as num?)?.toInt(),
          maxTokens: (mm['maxTokens'] as num?)?.toInt(),
        );
      }).toList();
      return DshModelGroup(
        id: (g['id'] ?? '').toString(),
        name: (g['name'] ?? '').toString(),
        models: models,
      );
    }).toList();
  }

  // ── Agent 预设域 ──────────────────────────────────────────────────────

  /// 预设列表（agentPreset.list）。
  Future<({List<DshPresetInfo> presets, bool authorable})> listPresets() async {
    final v = await _rpc('agentPreset.list', {});
    return (
      presets: ((v['presets'] as List?) ?? const [])
          .map(
            (e) => DshPresetInfo.fromJson((e as Map).cast<String, dynamic>()),
          )
          .toList(),
      authorable: v['authorable'] == true,
    );
  }

  /// 切换会话的 agent 预设。
  Future<String> selectPreset(String sessionId, String agentPreset) async {
    final v = await _rpc('agentPreset.select', {
      'sessionId': sessionId,
      'agentPreset': agentPreset,
    });
    return (v['agentPreset'] ?? '').toString();
  }

  /// 把预设设为后续新建会话的默认。
  ///
  /// rc.2 的 settings 命名空间由插件名派生（registry 只写 `settings.configure`），
  /// 写死 `agent-presets` 在换版本时会静默失败；这里**从 `settings.describe`
  /// 的命名空间里挑含 preset 的那个**，取不到才退回老名字。
  /// 见 docs/fix-log.md #396。
  Future<void> setDefaultPreset(String agentPreset) async {
    await _rpc('settings.update', {
      'ns': await _agentPresetNamespace(),
      'patch': {'default': agentPreset},
    });
  }

  String? _agentPresetNs;

  Future<String> _agentPresetNamespace() async {
    final cached = _agentPresetNs;
    if (cached != null && cached.isNotEmpty) return cached;
    try {
      final v = await _rpc('settings.describe', const {});
      final picked = pickAgentPresetNamespace(v['namespaces']);
      if (picked != null) {
        _agentPresetNs = picked;
        return picked;
      }
    } catch (_) {
      // describe 失败就退回老名字，真写不进去由 UI 报错。
    }
    _agentPresetNs = 'agent-presets';
    return 'agent-presets';
  }

  /// 从 `settings.describe` 的命名空间里挑默认预设该写哪个（纯函数便于单测）：
  /// 取名字里含 preset 的那个；没有返回 null（调用方退回老名字）。
  static String? pickAgentPresetNamespace(dynamic namespaces) {
    if (namespaces is! List) return null;
    for (final e in namespaces) {
      if (e is! Map) continue;
      final ns = (e['ns'] ?? '').toString();
      if (ns.isNotEmpty && ns.toLowerCase().contains('preset')) return ns;
    }
    return null;
  }

  /// 读取预设内容（agentPreset.read）。
  Future<({String content, String trust, String? name, String? description})>
  readPreset(String agentPreset) async {
    final v = await _rpc('agentPreset.read', {'agentPreset': agentPreset});
    return (
      content: (v['content'] ?? '').toString(),
      trust: (v['trust'] ?? 'user').toString(),
      name: v['name']?.toString(),
      description: v['description']?.toString(),
    );
  }

  /// 当前 DSH 是否支持增删自建预设。
  ///
  /// rc.2 的 `dsh-agent-preset-registry` 只暴露 `agentPresets/list|read|select`
  /// （见 docs/fix-log.md #396），`agentPresets/copy` / `agentPresets/deletePreset`
  /// **不存在**；一旦撞到 404 就置 false，界面据此收起「复制 / 删除」入口，
  /// 不再反复打必失败的请求。
  bool agentPresetMutable = true;

  /// 复制预设为新的用户预设（agentPreset.copy）。
  Future<String> copyPreset(
    String from,
    String agentPreset, {
    String? name,
  }) async {
    if (!agentPresetMutable) {
      throw DshApiException('当前 DSH 版本不支持复制预设（没有 agentPresets/copy）');
    }
    try {
      final v = await _rpc('agentPreset.copy', {
        'from': from,
        'agentPreset': agentPreset,
        if (name != null && name.isNotEmpty) 'name': name,
      });
      return (v['agentPreset'] ?? '').toString();
    } catch (e) {
      _markPresetMutableFromError(e);
      rethrow;
    }
  }

  /// 删除用户预设（agentPreset.remove）。
  Future<void> removePreset(String agentPreset) async {
    if (!agentPresetMutable) {
      throw DshApiException('当前 DSH 版本不支持删除预设（没有 agentPresets/deletePreset）');
    }
    try {
      await _rpc('agentPreset.remove', {'agentPreset': agentPreset});
    } catch (e) {
      _markPresetMutableFromError(e);
      rethrow;
    }
  }

  /// 「端点不存在」才判死（超时 / 连不上属临时故障，下次还要试）。
  void _markPresetMutableFromError(Object error) {
    final text = '$error';
    if (text.contains('404') || text.contains('unknown endpoint')) {
      agentPresetMutable = false;
    }
  }

  // ── 工作区域 ──────────────────────────────────────────────────────────

  /// 工作区列表。
  ///
  /// rc.2 **没有** `workspace/list`（官方接口面只有 `workspace/follow` 这条
  /// 下行流：baseline 帧里带 `items` + `archivedSessionIds`），旧协议
  /// `workspace.list` 只在更老的 DSH 上存在。所以顺序是：
  /// 旧协议 RPC（老版本兼容）→ `workspace/follow` baseline →
  /// 抛错交上层按会话 cwd 分组（局域网 8080 转发层不做 WS 隧道，见
  /// docs/fix-log.md #392）。第一次 404 之后不再重试，避免每 5 秒白打请求。
  bool _workspaceListUnsupported = false;

  Future<({List<DshWorkspace> items, List<String> archivedSessionIds})>
  listWorkspaces() async {
    if (_workspaceListUnsupported) {
      throw DshApiException('工作区接口在当前 DSH 上不可用（已降级为按会话目录分组）');
    }
    var endpointMissing = false;
    try {
      final v = await _rpc('workspace.list', {});
      _workspaceListUnsupported = false;
      return (
        items: ((v['items'] as List?) ?? const [])
            .map(
              (e) => DshWorkspace.fromJson((e as Map).cast<String, dynamic>()),
            )
            .toList(),
        archivedSessionIds: ((v['archivedSessionIds'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
      );
    } catch (e) {
      // 只有「接口不存在」（404）才判死；超时 / 连不上属临时故障，下次还要试。
      endpointMissing = '$e'.contains('404');
      await _logWsFallback('workspace/list RPC 失败：$e');
    }
    try {
      final baseline =
          await DshWsDownlink.openRemoteStream(
                _baseUrl,
                'workspace/follow',
                const {},
                headers: _wsHeaders(),
              )
              .firstWhere((value) {
                return value is Map && value['type'] == 'baseline';
              })
              .timeout(const Duration(seconds: 4));
      final raw = (baseline as Map)['value'];
      final v = raw is Map
          ? raw.cast<String, dynamic>()
          : const <String, dynamic>{};
      return (
        items: ((v['items'] as List?) ?? const [])
            .map(
              (e) => DshWorkspace.fromJson((e as Map).cast<String, dynamic>()),
            )
            .toList(),
        archivedSessionIds: ((v['archivedSessionIds'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
      );
    } catch (e) {
      await _logWsFallback('workspace/follow 下行流没给 baseline：$e');
    }
    _workspaceListUnsupported = endpointMissing;
    throw DshApiException('拿不到工作区列表（workspace/list 与 workspace/follow 都不通）');
  }

  /// 落一条诊断日志（工作区接口降级路径），排查「一直转圈」时能直接看到原因。
  Future<void> _logWsFallback(String message) async {
    await RuntimeLogger.instance.warn(
      'DSH',
      'workspace.fallback',
      data: {'reason': message, 'baseUrl': _baseUrl},
    );
  }

  /// 创建/采用工作区目录（workspace.create）。
  Future<DshWorkspace> createWorkspace(String path) async {
    final v = await _rpc('workspace.create', {'path': path});
    return DshWorkspace.fromJson(
      (v['workspace'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }

  /// 重命名工作区（workspace.rename）。
  Future<DshWorkspace> renameWorkspace(String workspaceId, String title) async {
    final v = await _rpc('workspace.rename', {
      'workspaceId': workspaceId,
      'title': title,
    });
    return DshWorkspace.fromJson(
      (v['workspace'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }

  /// 删除工作区（workspace.delete）。
  Future<void> deleteWorkspace(String workspaceId) async {
    await _rpc('workspace.delete', {'workspaceId': workspaceId});
  }

  /// 调整工作区显示顺序（workspace.insertBefore）。
  /// [beforeWorkspaceId] 为 null 表示挪到末尾。
  Future<List<String>> insertWorkspaceBefore(
    String workspaceId, {
    String? beforeWorkspaceId,
  }) async {
    final v = await _rpc('workspace.insertBefore', {
      'workspaceId': workspaceId,
      'beforeWorkspaceId': ?beforeWorkspaceId,
    });
    return ((v['workspaceIds'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();
  }

  /// 归档会话（workspace.archiveSession）。
  Future<List<String>> archiveSession(String sessionId) async {
    final v = await _rpc('workspace.archiveSession', {'sessionId': sessionId});
    return ((v['archivedSessionIds'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();
  }

  /// 把会话搬到另一个工作区目录。
  ///
  /// 官方 `insertSessionBefore` 不能改 header.cwd；跨目录必须走拾忆内置
  /// 插件 `POST /__shiyi/move-session`。插件未加载时抛 `plugin-missing`。
  Future<Map<String, dynamic>> moveSessionToWorkspace({
    required String sessionId,
    required String workspaceId,
    String? workspacePath,
  }) async {
    final http.Response res;
    final payload = <String, String>{
      "sessionId": sessionId,
      "workspaceId": workspaceId,
    };
    final path = workspacePath?.trim() ?? "";
    if (path.isNotEmpty) payload["workspacePath"] = path;
    try {
      res = await _client
          .post(
            Uri.parse("$_baseUrl/__shiyi/move-session"),
            headers: _headers(),
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 8));
    } on TimeoutException {
      throw DshApiException("跨工作区移动插件未响应", code: "plugin-missing");
    } catch (e) {
      throw DshApiException("DeepSeek Harness 服务不可达：$e");
    }
    if (res.statusCode == 404) {
      throw DshApiException("跨工作区移动插件未加载", code: "plugin-missing");
    }
    Map<String, dynamic> body = const {};
    try {
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is Map<String, dynamic>) body = decoded;
    } catch (_) {}
    if (res.statusCode != 200 || body["ok"] != true) {
      throw DshApiException(
        body["error"]?.toString() ?? "移动失败（HTTP ${res.statusCode}）",
        code: body["code"]?.toString() ?? "session-move-failed",
      );
    }
    return body;
  }

  /// 把会话插入工作区（workspace.insertSessionBefore）。
  Future<void> insertSessionBefore(
    String workspaceId,
    String sessionId, {
    String? beforeSessionId,
  }) async {
    await _rpc('workspace.insertSessionBefore', {
      'workspaceId': workspaceId,
      'sessionId': sessionId,
      'beforeSessionId': ?beforeSessionId,
    });
  }

  // ── 子代理域 ──────────────────────────────────────────────────────────

  /// 子代理列表。
  ///
  /// rc.2 **没有 `subagents/list`**（只有 `subagents/prompt` /
  /// `subagents/interruptByParent`），列表要从官方 `session/list` 派生：
  /// 父会话条目里的 `projections.values.subagentCatalog`
  /// （`{id, createdAt, mode, label?}`）就是官方子代理目录，子会话本身则带
  /// `origin:'subagent'` + `parentSessionId`。原来打 `subagents/list` 会 404，
  /// 子代理状态条 / mini 会话因此全空（见 docs/fix-log.md #396）。
  Future<({List<DshSubagentEntry> entries, bool parentAvailable})>
  listSubagents(String parentSessionId) async {
    return deriveSubagents(
      parentSessionId: parentSessionId,
      sessions: await listAllSessions(),
    );
  }

  /// 由一份 `session/list` 结果派生子代理列表（纯函数，便于单测）。
  static ({List<DshSubagentEntry> entries, bool parentAvailable})
  deriveSubagents({
    required String parentSessionId,
    required List<DshSessionSummary> sessions,
  }) {
    final parent = sessions
        .where((s) => s.sessionId == parentSessionId)
        .firstOrNull;
    final children = <String, DshSessionSummary>{
      for (final s in sessions)
        if (s.isSubagent && s.parentSessionId == parentSessionId)
          s.sessionId: s,
    };
    final childIdsOf = <String, int>{};
    for (final s in sessions) {
      final p = s.parentSessionId;
      if (s.isSubagent && p != null && p.isNotEmpty) {
        childIdsOf[p] = (childIdsOf[p] ?? 0) + 1;
      }
    }
    final entries = <DshSubagentEntry>[];
    for (final item
        in parent?.subagentCatalog ?? const <Map<String, dynamic>>[]) {
      final id = (item['id'] ?? '').toString();
      if (id.isEmpty) continue;
      final child = children[id];
      entries.add(
        DshSubagentEntry(
          sessionId: id,
          title: item['label']?.toString() ?? child?.title,
          running: child?.running ?? false,
          updatedAt:
              child?.updatedAt ?? (item['createdAt'] as num?)?.toInt() ?? 0,
          turnCount: child?.turnCount ?? 0,
          mode: (item['mode'] ?? 'one-shot').toString(),
          hasChildren: (childIdsOf[id] ?? 0) > 0,
        ),
      );
    }
    // 目录缺失（旧版 DSH / 未物化）时退回「按 parentSessionId 找子会话」。
    if (entries.isEmpty) {
      for (final child in children.values) {
        entries.add(
          DshSubagentEntry(
            sessionId: child.sessionId,
            title: child.title,
            running: child.running,
            updatedAt: child.updatedAt,
            turnCount: child.turnCount,
            mode: 'one-shot',
            hasChildren: (childIdsOf[child.sessionId] ?? 0) > 0,
          ),
        );
      }
    }
    entries.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return (
      entries: entries,
      parentAvailable: parent?.agentAvailable ?? false,
    );
  }

  /// 子代理历史 + live token + 投影统计（打开详情页一次拉齐）。
  Future<DshSubagentHistoryBundle> subagentHistoryBundle(
    String parentSessionId,
    String childSessionId, {
    String mode = 'one-shot',
    int? beforeSeq,
    int? maxMessages,
  }) async {
    final value = _normalizeHistoryValue(
      await _rpc('subagent.history', {
        'parentSessionId': parentSessionId,
        'childSessionId': childSessionId,
        'mode': mode,
        'beforeSeq': ?beforeSeq,
        'maxMessages': ?maxMessages,
      }),
    );
    final projections = (value['projections'] as Map?)?.cast<String, dynamic>();
    DshSessionSummary? summary;
    if (projections != null) {
      summary = DshSessionSummary.fromJson({
        'sessionId': childSessionId,
        'updatedAt': 0,
        'running': false,
        'blank': false,
        'projections': projections,
      });
    }
    return DshSubagentHistoryBundle(
      messages: _historyFromValue(value, isSubagentHistory: true),
      live: DshLiveTurn.fromHistoryValue(value),
      summary: summary,
    );
  }

  /// 子代理历史（subagent.history，仅消息）。
  Future<List<ChatMessage>> subagentHistory(
    String parentSessionId,
    String childSessionId, {
    String mode = 'one-shot',
    int? beforeSeq,
    int? maxMessages,
  }) async {
    return (await subagentHistoryBundle(
      parentSessionId,
      childSessionId,
      mode: mode,
      beforeSeq: beforeSeq,
      maxMessages: maxMessages,
    )).messages;
  }

  /// 继续子代理（subagent.prompt，continuable 模式）。
  Future<void> subagentPrompt(
    String parentSessionId,
    String childSessionId,
    String text,
  ) async {
    await _rpc('subagent.prompt', {
      'requestId': _newRpcId(),
      'parentSessionId': parentSessionId,
      'childSessionId': childSessionId,
      'mode': 'continuable',
      'delivery': 'queue',
      'content': [
        {'type': 'text', 'text': text},
      ],
      'clientTimeZone': 'Asia/Shanghai',
    });
  }

  /// 中断子代理（subagent.interrupt）。
  Future<void> subagentInterrupt(
    String parentSessionId,
    String childSessionId,
  ) async {
    await _rpc('subagent.interrupt', {
      'parentSessionId': parentSessionId,
      'childSessionId': childSessionId,
      'mode': 'continuable',
    });
  }

  // ── 技能域 ────────────────────────────────────────────────────────────

  /// 技能列表（skill.list）。
  ///
  /// DSH 0.1.0-rc.6 起 payload 固定要求已挂载的会话 id，冷会话会返回
  /// session-not-found；调用方应先通过 [createSession] 唤醒/挂载会话。
  /// 不再回退到空 payload，避免把协议错误伪装成“网络/启动失败”。
  Future<List<DshSkillInfo>> listSkills({required String sessionId}) async {
    final sid = sessionId.trim();
    if (sid.isEmpty) throw DshApiException('技能列表需要有效的 DSH 会话');
    final v = await _rpc('skill.list', {'sessionId': sid});
    final rawItems =
        v['items'] ?? v['skills'] ?? v['availableSkills'] ?? const [];
    final items = rawItems is List
        ? rawItems
        : rawItems is Map
        ? rawItems.values.toList()
        : const <dynamic>[];
    final result = items
        .whereType<Map>()
        .map((e) => DshSkillInfo.fromJson(e.cast<String, dynamic>()))
        .where((e) => e.name.isNotEmpty)
        .toList();
    result.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return result;
  }

  // ── 凭据域 ────────────────────────────────────────────────────────────

  /// 凭据描述。官方要 refs 数组；空数组不会枚举已知槽位。
  Future<List<DshCredentialSlot>> describeCredentials({
    List<String> refs = const [
      'SHIYI_API_KEY',
      'SHIYI_DSH_SEARCH_KEY',
      'DEEPSEEK_API_KEY',
    ],
  }) async {
    final v = await _rpc('credentials.describe', {'refs': refs});
    return DshCredentialSlot.fromDescribeValue(v);
  }

  /// 设置凭据（credentials.set，字段是 ref 字符串）。
  Future<void> setCredential(String ref, String value) async {
    await _rpc('credentials.set', {'ref': ref, 'value': value});
  }

  /// 删除凭据（credentials.unset，字段是 ref 字符串）。
  Future<void> unsetCredential(String ref) async {
    await _rpc('credentials.unset', {'ref': ref});
  }

  // ── 主机域 ────────────────────────────────────────────────────────────

  /// 主机信息。
  ///
  /// 目标 DSH（桌面版）组合的可能是**原生**目录选择器（只实现 `pick`），
  /// 这时 `directoryPicker/list` 会返回 `directory-picker/unavailable`
  /// —— 浏览拿不到目录很正常，用已知 cwd 兜底即可。
  /// **不要再回退到 `host.describe`**（目标没有这个端点，只会 404），
  /// 见 docs/fix-log.md #403。
  Future<DshHostInfo> hostDescribe() async {
    var cwd = _preferredCwd.trim();
    var home = '';
    try {
      final listing = await directoryListing();
      if (listing.path.isNotEmpty && cwd.isEmpty) cwd = listing.path;
      home = listing.home;
    } catch (_) {
      // 目标只提供原生选择器 / 旧版没有浏览能力：用已知 cwd 兜底。
    }
    var canOpenPath = false;
    try {
      canOpenPath =
          (await _rpc('session/canOpenWorkspacePath', const {}))['value'] ==
          true;
    } catch (_) {}
    final hint = cwd.isNotEmpty ? cwd : home;
    final windows = hint.contains('\\') || RegExp(r'^[A-Za-z]:').hasMatch(hint);
    return DshHostInfo(
      platform: windows ? 'win32' : 'linux',
      arch: '',
      cwd: cwd,
      home: home,
      canOpenPath: canOpenPath,
    );
  }

  /// 完整目录快照（host.listDirectory）；省略 path 时由远端列出其 home。
  Future<DshDirectoryListing> directoryListing([String? path]) async {
    final normalized = path?.trim() ?? '';
    final v = await _rpc(
      'host.listDirectory',
      normalized.isEmpty ? const {} : {'path': normalized},
    );
    return DshDirectoryListing.fromJson(v);
  }

  /// 目录条目兼容入口。
  Future<List<DshDirEntry>> listDirectory(String path) async {
    return (await directoryListing(path)).entries;
  }

  /// DSH 宿主账户的 home。host.listDirectory 省略 path 时会返回该字段。
  Future<String> hostHome() async {
    return (await directoryListing()).home;
  }

  /// 选择目录（host.pickDirectory）。
  Future<String?> pickDirectory() async {
    final v = await _rpc('host.pickDirectory', {});
    return (v['path'] ?? v['value'] ?? v['directory'] ?? v['selected'] ?? '')
        .toString();
  }

  /// 打开路径（host.openPath）。
  Future<void> openPath(String path) async {
    await _rpc('host.openPath', {'path': path});
  }

  /// 创建目录（host.createDirectory）。name 必须是单个路径段。
  Future<String> createDirectory(String path, String name) async {
    final v = await _rpc('host.createDirectory', {'path': path, 'name': name});
    return (v['path'] ?? '').toString();
  }

  // ── 设置域 ────────────────────────────────────────────────────────────

  /// 设置命名空间（settings.describe）。
  Future<
    ({bool writable, bool hasDocument, List<DshSettingsNamespace> namespaces})
  >
  describeSettings() async {
    final v = await _rpc('settings.describe', {});
    final namespaces = ((v['namespaces'] as List?) ?? const []).map((e) {
      final n = (e as Map).cast<String, dynamic>();
      return DshSettingsNamespace(
        ns: (n['ns'] ?? '').toString(),
        value: (n['value'] as Map?)?.cast<String, dynamic>() ?? const {},
        base: (n['base'] as Map?)?.cast<String, dynamic>() ?? const {},
        user: (n['user'] as Map?)?.cast<String, dynamic>() ?? const {},
        schema: (n['schema'] as Map?)?.cast<String, dynamic>() ?? const {},
        secrets: ((n['secrets'] as List?) ?? const [])
            .map(
              (s) => DshCredentialSlot.fromJson(
                (s as Map).cast<String, dynamic>(),
              ),
            )
            .toList(),
        revision: (n['revision'] as num?)?.toInt() ?? 0,
      );
    }).toList();
    return (
      writable: v['writable'] == true,
      hasDocument: v['hasDocument'] == true,
      namespaces: namespaces,
    );
  }

  /// 更新设置命名空间（settings.update）。
  Future<void> updateSettings(
    String ns,
    Map<String, dynamic> patch, {
    int? expectedRevision,
  }) async {
    await _rpc('settings.update', {
      'ns': ns,
      'patch': patch,
      'expectedRevision': ?expectedRevision,
    });
  }

  /// 按路径改设置（settings.mutate）。手写自定义路由必须整段 set，
  /// 避免用 update 盖掉同命名空间里其他提供商。
  Future<void> mutateSettings(
    String ns,
    List<Map<String, dynamic>> ops, {
    int? expectedRevision,
  }) async {
    await _rpc('settings.mutate', {
      'ns': ns,
      'ops': ops,
      'expectedRevision': ?expectedRevision,
    });
  }

  // ── 权限预设（permissionPresets 服务） ──────────────────────────────

  /// 读权限预设表。未挂 permissionPresets 服务的 DSH 返回 null（按钮隐藏）。
  Future<DshPermissionPresets?> describePermissionPresets() async {
    final describe = await describeSettings();
    for (final namespace in describe.namespaces) {
      if (namespace.ns != 'permission') continue;
      final current = (namespace.value['defaultPreset'] ?? '').toString();
      final options = permissionOptionsFromSchema(namespace.schema);
      if (current.isEmpty && options.isEmpty) return null;
      return DshPermissionPresets(
        defaultPreset: current,
        revision: namespace.revision,
        options: options,
      );
    }
    return null;
  }

  /// 实时切换当前会话的权限预设（typert `commands/execute`，即官方输入框
  /// 弹层走的 `/permission <preset>` 命令）。对当前会话立即生效并写入
  /// `permission/preset` 事件；agent 未物化（会话冷）时服务端拒绝。
  /// 返回命令回执文本；kind=error 或 RPC 失败抛 [DshApiException]。
  /// 注意：typert assertExactArguments 要求可选参数的键也必须存在，
  /// `images` 缺键会被网关以 "missing images" 拒绝，必须显式传空数组。
  Future<String> executeSessionCommand(String sessionId, String line) async {
    final value = await _rpc('commands.execute', {
      'agentId': sessionId,
      'line': line,
      'submittedAttachments': const <dynamic>[],
    });
    final outcome = (value['result'] as Map?)?.cast<String, dynamic>();
    final kind = (outcome?['kind'] ?? '').toString();
    final text = (outcome?['text'] ?? '').toString();
    if (value.isEmpty || kind != 'success') {
      throw DshApiException(text.isEmpty ? '命令未被 DSH 接受' : text);
    }
    return text;
  }

  /// 从 schemastery 序列化 schema（{uid, refs} 引用图）解析预设表：
  /// 根对象 → dict.defaultPreset → union.list → const{value, meta.description}。
  /// 形状对不上时返回空列表（按钮隐藏，不硬编码预设名）。
  static List<DshPermissionPresetOption> permissionOptionsFromSchema(
    Map<String, dynamic> schema,
  ) {
    try {
      final refs = (schema['refs'] as Map?)?.cast<String, dynamic>();
      if (refs == null) return const [];
      final root = refs['${schema['uid']}'];
      final dict = root is Map ? (root['dict'] as Map?) : null;
      final unionId = dict?['defaultPreset'];
      final union = unionId == null ? null : refs['$unionId'];
      if (union is! Map || union['type'] != 'union') return const [];
      final list = (union['list'] as List?) ?? const [];
      final options = <DshPermissionPresetOption>[];
      for (final id in list) {
        final ref = refs['$id'];
        if (ref is! Map || ref['type'] != 'const') continue;
        final key = '${ref['value']}';
        if (key.isEmpty) continue;
        final meta = ref['meta'];
        final label = meta is Map && meta['description'] != null
            ? '${meta['description']}'
            : key;
        options.add(DshPermissionPresetOption(key: key, label: label));
      }
      return options;
    } catch (_) {
      return const [];
    }
  }

  /// 折叠 history 事件流里最后一次 `permission/preset`（data.preset）。
  static String? permissionPresetFromValue(Map<String, dynamic> value) {
    String? preset;
    for (final entry in (value['events'] as List?) ?? const []) {
      final ev = ((entry as Map)['event'] as Map?)?.cast<String, dynamic>();
      if (ev?['type']?.toString() != 'permission/preset') continue;
      final data = (ev?['data'] as Map?)?.cast<String, dynamic>();
      preset = (data?['preset'] ?? '').toString();
    }
    return preset;
  }

  // ── 插件清单（typert pluginInventory/list，实时只读） ───────────────

  /// 目标 DSH 当前装载的插件实时清单（含 fiber 装载相位）。
  /// 远端连接的插件页用这条 RPC，不读本机补丁文件。
  Future<List<DshPluginInventoryEntry>> pluginInventoryList() async {
    final value = await _rpc('pluginInventory/list', const {});
    final entries = (value['entries'] as List?) ?? const [];
    return entries
        .map(
          (e) => DshPluginInventoryEntry.fromJson(
            (e as Map).cast<String, dynamic>(),
          ),
        )
        .toList();
  }

  // ── 目标域 ────────────────────────────────────────────────────────────

  /// 创建目标（goal.create）。
  Future<DshGoalRef> createGoal(
    String sessionId,
    String objective, {
    int? maxGoalRounds,
  }) async {
    final v = await _rpc('goal.create', {
      'sessionId': sessionId,
      'objective': objective,
      'maxGoalRounds': ?maxGoalRounds,
    });
    return DshGoalRef.fromJson(v);
  }

  /// 编辑目标（goal.edit）。
  Future<DshGoalRef> editGoal(
    String sessionId,
    String ref,
    String objective, {
    int? maxGoalRounds,
  }) async {
    final v = await _rpc('goal.edit', {
      'sessionId': sessionId,
      'ref': ref,
      'objective': objective,
      'maxGoalRounds': ?maxGoalRounds,
    });
    return DshGoalRef.fromJson(v);
  }

  /// 暂停目标（goal.pause）。
  Future<void> pauseGoal(String sessionId, String ref) async {
    await _rpc('goal.pause', {'sessionId': sessionId, 'ref': ref});
  }

  /// 恢复目标（goal.resume）。
  Future<void> resumeGoal(String sessionId, String ref) async {
    await _rpc('goal.resume', {'sessionId': sessionId, 'ref': ref});
  }

  /// 完成目标（goal.complete）。
  Future<void> completeGoal(String sessionId, String ref) async {
    await _rpc('goal.complete', {'sessionId': sessionId, 'ref': ref});
  }

  /// 清除目标（goal.clear）。
  Future<void> clearGoal(String sessionId, String ref) async {
    await _rpc('goal.clear', {'sessionId': sessionId, 'ref': ref});
  }

  // ── 搜索域 ────────────────────────────────────────────────────────────

  /// 搜索会话（session.search）。部署未启用全文索引时抛 DshApiException。
  /// 搜索会话。
  ///
  /// rc.2 的 `session/search` 结果只有 `{items:[{sessionId, snippet}], hasMore}`：
  /// **没有标题 / 时间 / origin**。直接按 [DshSessionSummary.fromJson] 解析会得到
  /// 一堆空标题的会话，所以这里必须与 `session/list` 做 join；调用方已经握着
  /// 会话列表时用 [knownSessions] 传进来，省一次请求。见 docs/fix-log.md #396。
  Future<List<DshSessionSummary>> searchSessions(
    String query, {
    List<DshSessionSummary>? knownSessions,
  }) async {
    final v = await _rpc('session.search', {'query': query});
    final items = (v['items'] ?? const []) as List;
    final known = <String, DshSessionSummary>{
      for (final s in knownSessions ?? await listAllSessions()) s.sessionId: s,
    };
    final out = <DshSessionSummary>[];
    for (final e in items) {
      if (e is! Map) continue;
      final map = e.cast<String, dynamic>();
      final id = (map['sessionId'] ?? '').toString();
      final session = known[id];
      if (session == null || session.isSubagent) continue;
      out.add(session.withSearchSnippet(map['snippet']?.toString()));
    }
    return out;
  }

  /// 拉取会话历史并重建为消息列表。
  /// 事件流是 delta 模型：正式气泡来自 user/message、assistant/message、
  /// tool/call；若一轮在 turn/end 时仍只有 assistant/chunk、没有正式
  /// assistant/message，则把未收口缓冲冻成最后一条助手消息（与官方
  /// 客户端的 interrupted 节点一致）。
  Future<List<ChatMessage>> history(String sessionId) async {
    return (await historyBundle(sessionId)).messages;
  }

  /// 历史消息 + 末尾未收口的 live token（打开会话时补种流式气泡）。
  ///
  /// 只读官方尾页窗口（默认 [DshApiClient.historyWindowMessages] 条、至少
  /// [DshApiClient.historyWindowTurns] 轮）；更早的消息交给 [historyOlder] 上翻。
  /// 上千轮的长会话必须走这条窗口路径，否则首帧与每一拍轮询都会重拉全量历史。
  Future<DshHistoryBundle> historyBundle(
    String sessionId, {
    int maxMessages = DshApiClient.historyWindowMessages,
    int minMessages = DshApiClient.historyWindowMinMessages,
    int minTurns = DshApiClient.historyWindowTurns,
  }) {
    return historyWindow(
      sessionId,
      maxMessages: maxMessages,
      minMessages: minMessages,
      minTurns: minTurns,
    );
  }

  /// 只读官方尾页窗口（进入会话 / 每一拍轮询都用这个）。
  ///
  /// 官方 `session/page` 的窗口语义：向后取到「至少 [historyWindowMinMessages]
  /// 条 / 至少 [minTurns] 轮」，上限 [maxMessages] 条。返回的
  /// [DshHistoryBundle.hasMoreOlder] 表示还能继续向旧翻页，配合 [historyOlder]。
  Future<DshHistoryBundle> historyWindow(
    String sessionId, {
    int maxMessages = DshApiClient.historyWindowMessages,
    int minMessages = DshApiClient.historyWindowMinMessages,
    int minTurns = DshApiClient.historyWindowTurns,
  }) {
    return _readHistoryPage(
      'session.history',
      {'sessionId': sessionId},
      maxMessages: maxMessages,
      minMessages: minMessages,
      minTurns: minTurns,
      bootstrapCursor: true,
    );
  }

  /// 取比 [beforeSeq] 更早的一页（上翻加载更早的消息）。
  ///
  /// [throughSeq] 必须与首帧读到的是同一个尾部游标，否则官方会用新游标
  /// 重新定位窗口（见 `_sessionPageRequest` 的注释）。
  Future<DshHistoryBundle> historyOlder(
    String sessionId, {
    required int beforeSeq,
    int? throughSeq,
    int maxMessages = DshApiClient.historyOlderMessages,
  }) {
    return _readHistoryPage(
      'session.history',
      {'sessionId': sessionId},
      maxMessages: maxMessages,
      beforeSeq: beforeSeq,
      throughSeq: throughSeq,
    );
  }

  /// 读一页历史（不做向上翻页合并）。
  ///
  /// `maxMessages` / `minMessages` / `minTurns` 只发给 rc.2 的 `session/page`；
  /// 旧协议回退时用不含这些字段的裸游标请求，避免旧 DSH 拒绝未知参数。
  Future<DshHistoryBundle> _readHistoryPage(
    String method,
    Map<String, dynamic> payload, {
    required int maxMessages,
    int? minMessages,
    int? minTurns,
    int? beforeSeq,
    int? throughSeq,
    bool bootstrapCursor = false,
  }) async {
    Map<String, dynamic> windowArgs(int? through) => {
      ...payload,
      'maxMessages': maxMessages,
      'minMessages': ?minMessages,
      'minTurns': ?minTurns,
      'beforeSeq': ?beforeSeq,
      'throughSeq': ?through,
    };

    final legacyPayload = <String, dynamic>{
      ...payload,
      'beforeSeq': ?beforeSeq,
      'throughSeq': ?throughSeq,
    };

    // throughSeq 是**包含式上界**：rc.2 里 -1 的语义是「空游标」，
    // 服务端据此返回空页（`{"records":[],"hasMore":false}`），页面于是
    // 显示成空会话。官方客户端的游标来自 `session/follow` 首帧 snapshot；
    // 这里优先用最近读到过的尾部 seq，没有就先按读取参数、再靠
    // snapshot / 越界探测学一次（见下），之后由 [_tailCursors] 自维护。
    final key = _historyKey(payload);
    final through = throughSeq ?? _tailCursors[key];
    var value = _normalizeHistoryValue(
      await _rpc(
        method,
        windowArgs(through),
        legacyPayload: {...legacyPayload, 'throughSeq': ?through},
      ),
    );
    if (bootstrapCursor && (value['events'] as List?)?.isEmpty == true) {
      final snapshot = await _followSnapshot(payload);
      final records = (snapshot?['records'] as List?) ?? const <dynamic>[];
      if (records.isNotEmpty) {
        // 官方首帧就带着首页记录，直接用。
        value = _normalizeHistoryValue({
          'events': records,
          if (snapshot?['hasMore'] != null) 'hasMore': snapshot!['hasMore'],
          if (snapshot?['projections'] != null)
            'projections': snapshot!['projections'],
        });
      } else {
        var cursor = (snapshot?['cursor'] as num?)?.toInt();
        if (cursor == null || cursor < 0) {
          cursor = await _probeTailCursor(method, windowArgs, legacyPayload);
        }
        if (cursor != null && cursor >= 0) {
          // 先记住，避免每次读都重走一遍 snapshot / 越界探测。
          _tailCursors[key] = cursor;
          value = _normalizeHistoryValue(
            await _rpc(
              method,
              windowArgs(cursor),
              legacyPayload: {...legacyPayload, 'throughSeq': cursor},
            ),
          );
        }
      }
    }
    final events = (value['events'] as List?) ?? const <dynamic>[];
    final newest = _lastHistorySeq(events);
    if (newest != null) _tailCursors[key] = newest;
    return DshHistoryBundle(
      messages: _historyFromValue(value),
      live: DshLiveTurn.fromHistoryValue(value),
      responseModels: _responseModelsFromValue(value),
      turnEnded: _historyTurnEnded(value),
      permissionPreset: permissionPresetFromValue(value),
      hasMoreOlder: value['hasMore'] == true,
      oldestSeq: _firstHistorySeq(events),
      newestSeq: newest,
    );
  }

  /// 每个会话最近读到的尾部 seq，作为下一次读取的 `throughSeq`。
  /// 官方客户端从 `session/follow` 的 snapshot 拿 cursor，那条下行流在
  /// 部分链路（局域网 + 桌面宿主）拿不到帧，所以这里学一次后缓存复用。
  final Map<String, int> _tailCursors = {};

  static String _historyKey(Map<String, dynamic> payload) =>
      (payload['sessionId'] ?? payload['childSessionId'] ?? '').toString();

  /// 越界探测：用一个必然超过当前游标的 throughSeq 问一次，服务端会回
  /// `session page through seq N is past cursor M`，M 就是当前尾部游标
  /// （实测 rc.2：-1 是「空游标」，只有真实游标才拿得到记录）。
  Future<int?> _probeTailCursor(
    String method,
    Map<String, dynamic> Function(int?) windowArgs,
    Map<String, dynamic> legacyPayload,
  ) async {
    const probeSeq = 1 << 40;
    try {
      await _rpc(
        method,
        windowArgs(probeSeq),
        legacyPayload: {...legacyPayload, 'throughSeq': probeSeq},
      );
    } catch (e) {
      final cursor = parsePastCursor('$e');
      if (cursor != null) {
        unawaited(_diagHistory('cursor.learned', {'cursor': cursor}));
        return cursor;
      }
    }
    return null;
  }

  /// 从服务端的越界报错里取当前尾部游标：
  /// `session page through seq N is past cursor M` → M。
  static int? parsePastCursor(String message) {
    final match = RegExp(r'past cursor (\d+)').firstMatch(message);
    final value = int.tryParse(match?.group(1) ?? '');
    return (value != null && value >= 0) ? value : null;
  }

  /// 历史读取分步诊断（定位「会话页一直转圈」卡在哪一步）。
  Future<void> _diagHistory(String step, Map<String, dynamic> extra) =>
      RuntimeLogger.instance.info(
        'DSH',
        'history.diag',
        data: {'step': step, ...extra},
      );

  /// `session/follow` 连续失败次数。局域网 + 桌面宿主实测升级后拿不到任何
  /// 帧（HTTP 通、WS 静默），失败两次后就不再白等 4 秒超时，直接走
  /// 越界探测学游标；换连接会新建 client，自然重新尝试官方路径。
  int _followFailures = 0;

  /// `session/follow` 的首帧 snapshot（官方 `follow()` 的开启参数：
  /// `{request: {address, assistantStream: true}}`——少一层 `request` 或漏了
  /// `assistantStream` 服务端都不给开局 baseline）。
  Future<Map<String, dynamic>?> _followSnapshot(
    Map<String, dynamic> payload,
  ) async {
    if (_followFailures >= 2) return null;
    final sessionId = (payload['sessionId'] ?? '').toString().trim();
    final parentSessionId = (payload['parentSessionId'] ?? '')
        .toString()
        .trim();
    final childSessionId = (payload['childSessionId'] ?? '').toString().trim();
    final address = sessionId.isNotEmpty
        ? <String, dynamic>{'kind': 'session', 'sessionId': sessionId}
        : <String, dynamic>{
            'kind': 'subagent',
            'parentSessionId': parentSessionId,
            'childSessionId': childSessionId,
            'mode': (payload['mode'] ?? 'one-shot').toString(),
          };
    try {
      // 官方 `follow()` 的开启参数：{address, assistantStream:true}。
      // 参数按官方 `session/follow` 的 schema：单个 `request` 参数，
      // 里面是 `{address, assistantStream: true}`（漏了 assistantStream
      // 拿不到开局 baseline）。Host/Origin 仍走 [_wsHeaders] 的兼容身份。
      final snapshot =
          await DshWsDownlink.openRemoteStream(
                _baseUrl,
                'session/follow',
                {
                  'request': {'address': address, 'assistantStream': true},
                },
                headers: _wsHeaders(),
              )
              .firstWhere(
                (value) =>
                    value is Map && value['type']?.toString() == 'snapshot',
              )
              .timeout(const Duration(seconds: 4));
      _followFailures = 0;
      return (snapshot as Map).cast<String, dynamic>();
    } catch (e) {
      // 旧版 DSH 没有 session/follow / 下行流拿不到帧：保留原有 page 路径，
      // 由 [_probeTailCursor] 兜底学游标。
      _followFailures++;
      unawaited(_diagHistory('follow.fallback', {'reason': '$e'}));
    }
    return null;
  }

  static int? _firstHistorySeq(List<dynamic> entries) {
    var first = 1 << 62;
    for (final entry in entries) {
      final event = entry is Map ? entry['event'] : null;
      final seq = event is Map ? (event['seq'] as num?)?.toInt() : null;
      if (seq != null && seq < first) first = seq;
    }
    return first == 1 << 62 ? null : first;
  }

  static int? _lastHistorySeq(List<dynamic> entries) {
    var last = -1;
    for (final entry in entries) {
      final event = entry is Map ? entry['event'] : null;
      final seq = event is Map ? (event['seq'] as num?)?.toInt() : null;
      if (seq != null && seq > last) last = seq;
    }
    return last < 0 ? null : last;
  }

  static bool _historyTurnEnded(Map<String, dynamic> value) {
    final entries = (value['events'] as List?) ?? const [];
    var sawUser = false;
    var ended = false;
    for (final entry in entries) {
      final ev = ((entry as Map)['event'] as Map?)?.cast<String, dynamic>();
      final type = ev?['type']?.toString() ?? '';
      final surfaceOp = ev?['surfaceOp'];
      final isReplacementCheckpoint =
          surfaceOp is Map && surfaceOp['op']?.toString() == 'replace';
      if ((type == 'user/message' && !isReplacementCheckpoint) ||
          type == 'agent/inbox/spliced') {
        sawUser = true;
        ended = false;
      } else if (type == 'turn/end' && sawUser) {
        ended = true;
      }
    }
    return ended;
  }

  /// 当前会话 mux 下行。rc.2 用 `$events` + `session/follow`，旧版回退 events.mux。
  Stream<Map<String, dynamic>> watchMux({String sessionId = ''}) async* {
    final sid = sessionId.trim();
    if (sid.isNotEmpty) {
      try {
        await for (final frame in _mergeStreams([
          _watchRemoteEvents(),
          _watchSessionFollow(sid),
        ])) {
          yield frame;
        }
        return;
      } catch (_) {
        // 旧版没有 Gateway Remote stream 时回退到 events.mux。
      }
    }
    yield* DshWsDownlink.connect(_baseUrl, 'events.mux', headers: _wsHeaders());
  }

  /// 主机级下行：rc.2 用 `$events`，旧版回退 events.host。
  Stream<Map<String, dynamic>> watchHost() async* {
    try {
      await for (final frame in _watchRemoteEvents()) {
        yield frame;
      }
      return;
    } catch (_) {}
    yield* DshWsDownlink.connect(
      _baseUrl,
      'events.host',
      headers: _wsHeaders(),
    );
  }

  /// rc.2 官方会话控制流。它是全局流，提供 baseline、queue、jobs、
  /// projection 三类状态，不要把它当成旧版 host 事件流。
  Stream<Map<String, dynamic>> watchSessionControl({
    String sessionId = '',
  }) async* {
    final sid = sessionId.trim();
    await for (final value in DshWsDownlink.openRemoteStream(
      _baseUrl,
      'session/control',
      const {},
      headers: _wsHeaders(),
    )) {
      if (value is! Map) continue;
      final frame = value.cast<String, dynamic>();
      if (sid.isEmpty || _controlFrameContainsSession(frame, sid)) {
        yield frame;
      }
    }
  }

  static bool _controlFrameContainsSession(
    Map<String, dynamic> frame,
    String sessionId,
  ) {
    final direct = frame['sessionId']?.toString();
    if (direct == sessionId) return true;
    if (frame['type']?.toString() != 'baseline') return false;
    final value = (frame['value'] as Map?)?.cast<String, dynamic>();
    if (value == null) return false;
    for (final key in const ['queues', 'jobs', 'projections']) {
      final entries = value[key];
      if (entries is Map && entries.containsKey(sessionId)) return true;
    }
    return false;
  }

  Stream<Map<String, dynamic>> _watchRemoteEvents() async* {
    await for (final value in DshWsDownlink.openRemoteStream(
      _baseUrl,
      r'$events',
      const {},
      headers: _wsHeaders(),
    )) {
      if (value is! Map) continue;
      final mapped = _mapRemoteEventFrame(value.cast<String, dynamic>());
      if (mapped != null) yield mapped;
    }
  }

  Stream<Map<String, dynamic>> _watchSessionFollow(String sessionId) async* {
    await for (final value in DshWsDownlink.openRemoteStream(
      _baseUrl,
      'session/follow',
      {
        'request': {
          'address': {'kind': 'session', 'sessionId': sessionId},
          'assistantStream': true,
        },
      },
      headers: _wsHeaders(),
    )) {
      if (value is! Map) continue;
      final frame = value.cast<String, dynamic>();
      switch (frame['type']?.toString() ?? '') {
        case 'snapshot':
          final assistant = (frame['assistantStream'] as Map?)
              ?.cast<String, dynamic>();
          final activeAttempt = (assistant?['activeAttempt'] as Map?)
              ?.cast<String, dynamic>();
          for (final entry in (activeAttempt?['stream'] as List?) ?? const []) {
            if (entry is Map) {
              for (final chunk in _assistantStreamFrames(
                sessionId,
                entry.cast<String, dynamic>(),
              )) {
                yield chunk;
              }
            }
          }
          yield {
            'type': 'session/subscribed',
            'sessionId': sessionId,
            'lastSeq': (frame['cursor'] as num?)?.toInt() ?? -1,
          };
        case 'event':
          final event = frame['event'];
          if (event is Map) {
            yield {
              'type': 'session/event',
              'sessionId': sessionId,
              'event': event.cast<String, dynamic>(),
            };
          }
        case 'assistant-stream':
          final assistantFrame = (frame['frame'] as Map?)
              ?.cast<String, dynamic>();
          if (assistantFrame != null) {
            final type = assistantFrame['type']?.toString() ?? '';
            if (type == 'chunk') {
              final chunk = _assistantChunkFrame(sessionId, assistantFrame);
              if (chunk != null) yield chunk;
            } else if (type == 'end' &&
                (assistantFrame['outcome'] as Map?)?['kind'] == 'abandoned') {
              yield {
                'type': 'session/assistant-stream-end',
                'sessionId': sessionId,
                'outcome': 'abandoned',
              };
            }
          }
      }
    }
  }

  Map<String, dynamic>? _mapRemoteEventFrame(Map<String, dynamic> frame) {
    final type = frame['type']?.toString() ?? '';
    if (type == 'ready') {
      final clientId = frame['clientId']?.toString() ?? '';
      if (clientId.isNotEmpty) _remoteEventClientId = clientId;
      final host = (frame['host'] as Map?)?.cast<String, dynamic>();
      return {
        'type': 'host/ready',
        if (host?['home'] != null) 'home': host!['home'],
      };
    }
    if (type == 'emit') {
      final event = frame['event']?.toString() ?? '';
      final args = (frame['args'] as List?) ?? const [];
      if (event == 'api-session/status' && args.length >= 2) {
        return {
          'type': 'host/session-status',
          'sessionId': args[0].toString(),
          'running': args[1] == true,
        };
      }
      return {'type': 'host/remote-event', 'event': event, 'args': args};
    }
    if (type == 'waterfall') {
      final event = frame['event']?.toString() ?? '';
      final eventId = frame['eventId']?.toString() ?? '';
      if (event != 'user-questions/request') return null;
      if (eventId.isNotEmpty && _remoteEventClientId.isNotEmpty) {
        _remoteEventClientIds[eventId] = _remoteEventClientId;
      }
      final request = (frame['request'] as Map?)?.cast<String, dynamic>();
      return {
        'type': 'question/requested',
        'rpcId': eventId,
        'sessionId': frame['agentId']?.toString() ?? '',
        'questions': (request?['questions'] as List?) ?? const [],
      };
    }
    if (type == 'cancel') {
      final eventId = frame['eventId']?.toString() ?? '';
      _remoteEventClientIds.remove(eventId);
      return {'type': 'question/resolved', 'questionRpcId': eventId};
    }
    return null;
  }

  static Map<String, dynamic>? _assistantChunkFrame(
    String sessionId,
    Map<String, dynamic> frame,
  ) {
    final chunk = frame['chunk'];
    if (chunk is! Map) return null;
    return {
      'type': 'session/event',
      'sessionId': sessionId,
      'event': {
        'type': 'assistant/chunk',
        if (frame['time'] != null) 'time': frame['time'],
        'data': {'chunk': chunk.cast<String, dynamic>()},
      },
    };
  }

  static Iterable<Map<String, dynamic>> _assistantStreamFrames(
    String sessionId,
    Map<String, dynamic> record,
  ) sync* {
    final type = record['type']?.toString() ?? '';
    if (type == 'chunk' || record['chunk'] is Map) {
      final frame = _assistantChunkFrame(sessionId, record);
      if (frame != null) yield frame;
      return;
    }
    final texts = (record['texts'] as List?)?.whereType<String>() ?? const [];
    if (type == 'text-chunks') {
      for (final text in texts) {
        if (text.isEmpty) continue;
        yield {
          'type': 'session/event',
          'sessionId': sessionId,
          'event': {
            'type': 'assistant/chunk',
            'time': record['time0'],
            'data': {
              'chunk': {'type': 'text-delta', 'text': text},
            },
          },
        };
      }
    } else if (type == 'reasoning-chunks') {
      for (final text in texts) {
        if (text.isEmpty) continue;
        yield {
          'type': 'session/event',
          'sessionId': sessionId,
          'event': {
            'type': 'assistant/chunk',
            'time': record['time0'],
            'data': {
              'chunk': {'type': 'reasoning-delta', 'text': text},
            },
          },
        };
      }
    }
  }

  static Stream<T> _mergeStreams<T>(Iterable<Stream<T>> streams) {
    final inputs = streams.toList(growable: false);
    late final StreamController<T> controller;
    final subscriptions = <StreamSubscription<T>>[];
    var done = 0;
    void completeOne() {
      done++;
      if (done == inputs.length && !controller.isClosed) {
        controller.close();
      }
    }

    controller = StreamController<T>(
      onListen: () {
        for (final input in inputs) {
          subscriptions.add(
            input.listen(
              controller.add,
              onError: controller.addError,
              onDone: completeOne,
            ),
          );
        }
      },
      onCancel: () async {
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
      },
    );
    return controller.stream;
  }

  /// DSH 把运行时沙箱快照写成 sourced user/message。这是官方注入，不改 DSH；
  /// 拾忆把它挂到相邻真实气泡上，做成可展开组件，默认收起。
  static bool isInjectedRuntimeContext(String text) {
    final t = text.trimLeft();
    if (t.isEmpty) return false;
    return t.startsWith('Current runtime context') ||
        t.contains(
          'This snapshot supersedes earlier runtime-context snapshots',
        ) ||
        t.contains('Current DSH file policy:');
  }

  /// DSH 把 skill 目录（`<system-reminder>` 包裹的可用技能列表）写成
  /// sourced user/message，每次 agent 步骤前注入。这是写给模型看的目录，
  /// 对用户零价值，聊天界面直接丢弃、不单独成气泡也不挂折叠。
  static bool isInjectedSkillCatalog(String text) {
    final t = text.trimLeft();
    return t.contains(
          'A skill is a reusable set of task-specific instructions',
        ) ||
        t.contains('<available_skills>') ||
        t.contains('The available skill catalog changed');
  }

  /// Normalize rc.2 `session/page` into the legacy `events` shape consumed
  /// by the message/live reconstruction below.
  static Map<String, dynamic> _normalizeHistoryValue(
    Map<String, dynamic> value,
  ) {
    Map<String, dynamic>? eventOf(dynamic entry) {
      if (entry is! Map) return null;
      final direct = entry['event'];
      if (direct is Map) return direct.cast<String, dynamic>();
      final wrapped = entry['value'];
      if (wrapped is Map) {
        final nested = wrapped['event'];
        if (nested is Map) return nested.cast<String, dynamic>();
        if (wrapped['type'] != null) {
          return wrapped.cast<String, dynamic>();
        }
      }
      if (entry['type'] != null) return entry.cast<String, dynamic>();
      return null;
    }

    List<dynamic> order(List<dynamic> entries) {
      final normalized = <Map<String, dynamic>>[];
      for (final entry in entries) {
        final event = eventOf(entry);
        if (event != null) normalized.add({'event': event});
      }
      final ordered = normalized.asMap().entries.toList()
        ..sort((a, b) {
          final aEvent = a.value['event'];
          final bEvent = b.value['event'];
          final aSeq = aEvent is Map ? (aEvent['seq'] as num?)?.toInt() : null;
          final bSeq = bEvent is Map ? (bEvent['seq'] as num?)?.toInt() : null;
          if (aSeq == null || bSeq == null) return a.key.compareTo(b.key);
          return aSeq.compareTo(bSeq);
        });
      return ordered.map((entry) => entry.value).toList();
    }

    if (value['events'] is List) {
      return {...value, 'events': order(value['events'] as List)};
    }
    final records = value['records'];
    if (records is! List) return value;
    return {
      'events': order(records),
      if (value['hasMore'] != null) 'hasMore': value['hasMore'],
      if (value['projections'] != null) 'projections': value['projections'],
    };
  }

  /// 从 history 响应 value 重建消息列表（session.history / subagent.history 共用）。
  static List<ChatMessage> _historyFromValue(
    Map<String, dynamic> value, {
    bool isSubagentHistory = false,
  }) {
    final entries = (value['events'] as List?) ?? const [];
    final messages = <ChatMessage>[];
    final rolledBack = <ChatMessage>[];
    final seenMessageIds = <String>{};
    final surfaceSeqs = <int>[];
    final messageEventSeqs = <ChatMessage, int>{};
    final pendingLive = DshLiveTurn();
    var pendingStepFinalized = false;
    var pendingContext = '';
    var pendingSubagentSummary = false;
    var suppressDuplicateSubagentReply = false;

    void rememberContext(String text) {
      final t = text.trim();
      if (t.isNotEmpty) pendingContext = t;
    }

    void attachContext(ChatMessage msg) {
      if (pendingContext.isEmpty) return;
      msg.runtimeContext = pendingContext;
      pendingContext = '';
    }

    bool pendingLiveVisible() =>
        pendingLive.text.trim().isNotEmpty ||
        pendingLive.reasoning.trim().isNotEmpty ||
        pendingLive.toolCalls.isNotEmpty;

    void resetPendingLive({required bool keepReasoning}) {
      if (keepReasoning) {
        pendingLive.continueTurn();
      } else {
        pendingLive.reset();
      }
      pendingStepFinalized = false;
    }

    String markedText(String text, String marker) {
      return text.trimLeft().startsWith(marker) ? text : '$marker\n$text';
    }

    ({String role, String content, bool isSubagentResult}) presentUserMessage(
      String text,
      Iterable<dynamic> sources,
    ) {
      if (_isSubagentResult(sources)) {
        return (
          role: 'assistant',
          content: markedText(text, '<子代理返回信息>'),
          isSubagentResult: true,
        );
      }
      final promptMarked = text.trimLeft().startsWith('<子代理提示词注入>');
      if (promptMarked ||
          (isSubagentHistory && _isSubagentPromptSource(sources))) {
        return (
          role: 'assistant',
          content: markedText(text, '<子代理提示词注入>'),
          isSubagentResult: false,
        );
      }
      return (role: 'user', content: text, isSubagentResult: false);
    }

    bool isPresentedUserMessage(ChatMessage message) {
      final text = message.content.trimLeft();
      return message.role == 'user' ||
          text.startsWith('<子代理返回信息>') ||
          text.startsWith('<子代理提示词注入>');
    }

    String messageId(Map<String, dynamic> value, int seq) {
      final raw = value['id']?.toString().trim() ?? '';
      return 'dsh-${raw.isEmpty ? seq : raw}';
    }

    void trackSubagentSummary(
      ({String role, String content, bool isSubagentResult}) presentation,
    ) {
      pendingSubagentSummary = presentation.isSubagentResult;
    }

    bool takeIfContext(String text) {
      // skill 目录注入（写给模型的 <system-reminder>）与运行时沙箱快照
      // 一样：不单独成气泡，挂到相邻真实气泡的注入上下文折叠，默认收起。
      if (!isInjectedRuntimeContext(text) && !isInjectedSkillCatalog(text)) {
        return false;
      }
      rememberContext(text);
      return true;
    }

    /// 官方客户端在 turn/end 时若本步没有 assistant/message，会把
    /// 已发出的 chunk 冻成 interrupted 节点。这里同样冻成一条助手消息，
    /// 避免拉取历史时最后输出被截断。
    void freezePendingLive({required int seq, required int time}) {
      if (pendingStepFinalized || !pendingLiveVisible()) {
        resetPendingLive(keepReasoning: false);
        return;
      }
      if (suppressDuplicateSubagentReply) {
        suppressDuplicateSubagentReply = false;
        pendingSubagentSummary = false;
        resetPendingLive(keepReasoning: false);
        return;
      }
      final text = pendingLive.text.trim();
      final reasoning = pendingLive.reasoning.trim();
      if (takeIfContext(text)) {
        resetPendingLive(keepReasoning: false);
        return;
      }
      final isSubagentSummary = pendingSubagentSummary && reasoning.isNotEmpty;
      final item = ChatMessage(
        id: 'dsh-asst-$seq',
        sessionId: '',
        role: 'assistant',
        content: text,
        reasoning: isSubagentSummary ? '' : reasoning,
        subagentSummary: isSubagentSummary ? reasoning : '',
        toolCalls: List<ToolCall>.of(pendingLive.toolCalls),
        createdAt: time,
      );
      attachContext(item);
      messages.add(item);
      messageEventSeqs[item] = seq;
      if (pendingSubagentSummary) pendingSubagentSummary = false;
      resetPendingLive(keepReasoning: false);
    }

    void applySurfaceOp(Map<String, dynamic> event, String type, int seq) {
      if (type != 'user/message' &&
          type != 'assistant/message' &&
          type != 'tool/result') {
        return;
      }
      final rawOp = event['surfaceOp'];
      if (rawOp is! Map || rawOp['op']?.toString() != 'replace') {
        // 旧版 history 与测试夹具没有 surfaceOp；按 append 兼容。
        surfaceSeqs.add(seq);
        return;
      }
      final start = (rawOp['start'] as num?)?.toInt();
      final end = (rawOp['end'] as num?)?.toInt();
      if (start == null || end == null) {
        surfaceSeqs.add(seq);
        return;
      }
      final startIndex = surfaceSeqs.indexOf(start);
      final endIndex = surfaceSeqs.indexOf(end);
      if (startIndex < 0 || endIndex < startIndex) {
        // 畸形或截断历史不能破坏整页加载；至少展示新的 checkpoint。
        surfaceSeqs.add(seq);
        return;
      }

      final removed = messages.where((message) {
        final eventSeq = messageEventSeqs[message];
        return eventSeq != null && eventSeq >= start && eventSeq <= end;
      }).toList();
      for (final message in removed) {
        seenMessageIds.remove(message.id);
        messageEventSeqs.remove(message);
      }
      messages.removeWhere(removed.contains);
      rolledBack.removeWhere((message) {
        final eventSeq = messageEventSeqs[message];
        final shadowed =
            eventSeq != null && eventSeq >= start && eventSeq <= end;
        if (shadowed) messageEventSeqs.remove(message);
        return shadowed;
      });
      surfaceSeqs.replaceRange(startIndex, endIndex + 1, [seq]);
      pendingContext = '';
      pendingSubagentSummary = false;
      suppressDuplicateSubagentReply = false;
      resetPendingLive(keepReasoning: false);
    }

    for (final entry in entries) {
      final ev = ((entry as Map)['event'] as Map?)?.cast<String, dynamic>();
      if (ev == null) continue;
      final type = ev['type']?.toString() ?? '';
      final data = (ev['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      final seq = (ev['seq'] as num?)?.toInt() ?? 0;
      final time = (ev['time'] as num?)?.toInt() ?? 0;
      applySurfaceOp(ev, type, seq);
      if (type == 'agent/inbox/spliced') {
        final removed = (data['removedCount'] as num?)?.toInt() ?? 0;
        var left = removed;
        var removedSubagentResult = false;
        while (left > 0 &&
            messages.isNotEmpty &&
            isPresentedUserMessage(messages.last)) {
          final removed = messages.removeLast();
          removedSubagentResult =
              removedSubagentResult ||
              removed.content.trimLeft().startsWith('<子代理返回信息>');
          seenMessageIds.remove(removed.id);
          rolledBack.add(removed);
          left--;
        }
        if (removedSubagentResult) pendingSubagentSummary = false;
        final inserted = (data['inserted'] as List?) ?? const [];
        for (final item in inserted) {
          final m = (item as Map).cast<String, dynamic>();
          if (m['role']?.toString() != 'user') continue;
          final text = _joinTextParts((m['content'] as List?) ?? const []);
          if (text.trim().isEmpty) continue;
          if (takeIfContext(text)) continue;
          final presentation = presentUserMessage(text, [
            m['source'],
            m['metadata'],
            data,
            data['source'],
            data['metadata'],
            ev['source'],
          ]);
          final id = messageId(m, seq);
          if (seenMessageIds.contains(id)) {
            if (presentation.isSubagentResult) {
              suppressDuplicateSubagentReply = true;
              pendingSubagentSummary = false;
            }
            continue;
          }
          final msg = ChatMessage(
            id: id,
            sessionId: '',
            role: presentation.role,
            content: presentation.content,
            createdAt: time,
          );
          attachContext(msg);
          messages.add(msg);
          messageEventSeqs[msg] = seq;
          seenMessageIds.add(id);
          trackSubagentSummary(presentation);
        }
      } else if (type == 'turn/end') {
        freezePendingLive(seq: seq, time: time);
        final reason = (data['reason'] as Map?)?.cast<String, dynamic>();
        if (reason != null && reason['kind']?.toString() == 'error') {
          pendingSubagentSummary = false;
          messages.addAll(rolledBack.reversed);
          seenMessageIds.addAll(rolledBack.map((message) => message.id));
          rolledBack.clear();
          final err =
              (reason['error'] as Map?)?.cast<String, dynamic>() ?? const {};
          final msg = err['message']?.toString() ?? '未知错误';
          final errorMessage = ChatMessage(
            id: 'dsh-err-$seq',
            sessionId: '',
            role: 'assistant',
            content: '本轮失败：$msg',
            createdAt: time,
          );
          messages.add(errorMessage);
          messageEventSeqs[errorMessage] = seq;
        } else {
          rolledBack.clear();
        }
      } else if (type == 'assistant/chunk') {
        if (pendingLive.ingest(ev)) pendingStepFinalized = false;
      } else if (type == 'user/message') {
        final content = (data['content'] as List?) ?? const [];
        final text = _joinTextParts(content);
        if (text.trim().isEmpty) continue;
        if (takeIfContext(text)) continue;
        resetPendingLive(keepReasoning: false);
        final presentation = presentUserMessage(text, [
          data['source'],
          data['metadata'],
          data['message'],
          data,
          ev['source'],
        ]);
        final id = messageId(data, seq);
        if (seenMessageIds.contains(id)) {
          if (presentation.isSubagentResult) {
            // DSH can replay the same report after it has already been
            // consumed through agent/inbox/spliced. Its following assistant
            // acknowledgement is a duplicate turn, not a new user request.
            suppressDuplicateSubagentReply = true;
            pendingSubagentSummary = false;
          }
          continue;
        }
        final msg = ChatMessage(
          id: id,
          sessionId: '',
          role: presentation.role,
          content: presentation.content,
          createdAt: time,
        );
        attachContext(msg);
        messages.add(msg);
        messageEventSeqs[msg] = seq;
        seenMessageIds.add(id);
        trackSubagentSummary(presentation);
      } else if (type == 'assistant/message') {
        resetPendingLive(keepReasoning: true);
        pendingStepFinalized = true;
        if (suppressDuplicateSubagentReply) {
          suppressDuplicateSubagentReply = false;
          pendingSubagentSummary = false;
          continue;
        }
        final msg =
            (data['message'] as Map?)?.cast<String, dynamic>() ?? const {};
        final content = (msg['content'] as List?) ?? const [];
        var text = _joinTextParts(content);
        if (takeIfContext(text)) continue;
        final split = splitThinkTags(text);
        text = split.text.trim();
        final reasoning = mergeReasoning(
          _joinReasoningParts(content),
          split.reasoning,
        ).trim();
        final isSubagentSummary =
            pendingSubagentSummary && reasoning.trim().isNotEmpty;
        final item = ChatMessage(
          id: 'dsh-asst-$seq',
          sessionId: '',
          role: 'assistant',
          content: text,
          reasoning: isSubagentSummary ? '' : reasoning,
          subagentSummary: isSubagentSummary ? reasoning : '',
          createdAt: time,
        );
        attachContext(item);
        messages.add(item);
        messageEventSeqs[item] = seq;
        if (pendingSubagentSummary) pendingSubagentSummary = false;
      } else if (type == 'tool/call') {
        pendingLive.ingest(ev);
        // 本步已有正式 assistant/message 时挂到该气泡；否则留给
        // turn/end 的 freeze，避免工具误挂到上一轮助手消息。
        if (!pendingStepFinalized) continue;
        final last = messages.isEmpty ? null : messages.last;
        if (last != null && last.role == 'assistant') {
          last.toolCalls.add(
            ToolCall(
              id: data['callId']?.toString() ?? '',
              name: data['name']?.toString() ?? '',
              arguments: data['arguments']?.toString() ?? '',
            ),
          );
        }
      }
    }
    if (pendingContext.isNotEmpty && messages.isNotEmpty) {
      messages.last.runtimeContext = pendingContext;
    }
    return messages;
  }

  /// DSH 版本之间曾把子代理回传的来源放在不同层级：有的在插入消息
  /// 的 source，有的在 user/message 的 data.source。兼容这些形态，避免
  /// 回传被当成右侧用户气泡。
  static bool _isSubagentResult(Iterable<dynamic> values) {
    bool visit(dynamic value, int depth) {
      if (depth > 3 || value == null) return false;
      if (value is String) {
        final t = value.toLowerCase();
        return t.contains('subagent') &&
            (t.contains('settled') ||
                t.contains('report') ||
                t.contains('result') ||
                t.contains('return') ||
                t == 'subagent');
      }
      if (value is Map) {
        for (final entry in value.entries) {
          final key = entry.key.toString().toLowerCase();
          final raw = entry.value;
          if (key == 'kind' ||
              key == 'type' ||
              key == 'status' ||
              key == 'source' ||
              key == 'origin' ||
              key == 'metadata' ||
              key == 'sender' ||
              key == 'senderkind') {
            if (visit(raw, depth + 1)) return true;
          }
        }
        // 某些网关只留下 senderSessionId；它只会出现在子代理注入里。
        if (value.keys.any(
          (k) => k.toString().toLowerCase() == 'sendersessionid',
        )) {
          return true;
        }
      }
      if (value is Iterable) {
        for (final item in value) {
          if (visit(item, depth + 1)) return true;
        }
      }
      return false;
    }

    return values.any((value) => visit(value, 0));
  }

  /// 子代理会话里的直接 user 来源是主代理派发或追加给子代理的提示词。
  /// 只在 subagent.history 解析路径启用，普通主会话的用户消息不受影响。
  static bool _isSubagentPromptSource(Iterable<dynamic> values) {
    bool visit(dynamic value, int depth) {
      if (depth > 3 || value == null) return false;
      if (value is String) {
        final t = value.toLowerCase();
        return t == 'user' ||
            t == 'prompt' ||
            t.contains('subagent-prompt') ||
            t.contains('subagent_prompt');
      }
      if (value is Map) {
        for (final entry in value.entries) {
          final key = entry.key.toString().toLowerCase();
          if (key == 'kind' ||
              key == 'type' ||
              key == 'source' ||
              key == 'origin' ||
              key == 'metadata') {
            if (visit(entry.value, depth + 1)) return true;
          }
        }
      }
      if (value is Iterable) {
        for (final item in value) {
          if (visit(item, depth + 1)) return true;
        }
      }
      return false;
    }

    return values.any((value) => visit(value, 0));
  }

  /// 上游网关可能把请求模型别名解析成真实模型名。DSH 派生子代理时会
  /// 复用 responseModel，因此拾忆需要把历史里见过的真实名字补进 provider。
  static Set<String> _responseModelsFromValue(Map<String, dynamic> value) {
    final models = <String>{};
    final entries = (value['events'] as List?) ?? const [];
    for (final entry in entries) {
      final ev = ((entry as Map)['event'] as Map?)?.cast<String, dynamic>();
      if (ev?['type']?.toString() != 'assistant/message') continue;
      final data = (ev?['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      final message =
          (data['message'] as Map?)?.cast<String, dynamic>() ?? const {};
      final source =
          (message['source'] as Map?)?.cast<String, dynamic>() ?? const {};
      final replay =
          (source['replayState'] as Map?)?.cast<String, dynamic>() ?? const {};
      for (final raw in [
        replay['responseModel'],
        message['responseModel'],
        data['responseModel'],
      ]) {
        final model = raw?.toString().trim() ?? '';
        if (model.isNotEmpty &&
            model.length <= 200 &&
            !model.contains(RegExp(r'[\x00-\x1F\x7F]'))) {
          models.add(model);
        }
      }
    }
    return models;
  }

  static String _joinTextParts(List<dynamic> content) {
    final buf = StringBuffer();
    for (final part in content) {
      final p = (part as Map?)?.cast<String, dynamic>();
      if (p == null) continue;
      final type = p['type']?.toString() ?? '';
      if (type == 'text') {
        buf.write(p['text']?.toString() ?? '');
        continue;
      }
      // rc.2 的图片/文件块：正文里给个占位（附件本体要另取，
      // 见 DshApiClient.readAttachment），否则历史里这两类内容整条消失。
      if (type == 'image') {
        final name = p['name']?.toString() ?? '';
        buf.write(name.isEmpty ? '【图片】' : '【图片：$name】');
        continue;
      }
      if (type == 'file') {
        final name = p['name']?.toString() ?? '';
        buf.write(name.isEmpty ? '【附件】' : '【附件：$name】');
      }
    }
    return buf.toString().trim();
  }

  static String _joinReasoningParts(List<dynamic> content) {
    final buf = StringBuffer();
    for (final part in content) {
      final p = (part as Map?)?.cast<String, dynamic>();
      if (p == null) continue;
      if (p['type'] == 'reasoning' ||
          p['type'] == 'thinking' ||
          p['type'] == 'thought') {
        buf.write(p['text']?.toString() ?? p['content']?.toString() ?? '');
      }
    }
    return buf.toString().trim();
  }

  void dispose() {
    _client.close();
  }
}
