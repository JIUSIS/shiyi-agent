import 'dart:io';

import 'tool_result_pruner.dart';

/// 大工具输出落地（Codex spill 的可移植子集）。
///
/// 超阈值时全文写到工作目录 `.shiyi/tool-outputs/`，模型只看到头尾预览
/// 和路径；不改 tools JSON，所以冻头后的前缀缓存不会因为加工具而 miss。
/// `file_read` 的文件已经在磁盘上，只裁预览、不再复制一份。
class ToolOutputSpill {
  static const relativeDir = '.shiyi/tool-outputs';

  /// 终端 / 搜索 / 子代理报告等一次性输出的预览预算。
  static const ToolResultPruner previewPruner = ToolResultPruner(
    thresholdChars: 4000,
    headChars: 2400,
    tailChars: 1200,
  );

  /// file_read 模型可见预算（约 10k token 的保守字符上限）。
  static const ToolResultPruner fileReadPruner = ToolResultPruner(
    thresholdChars: 10000,
    headChars: 6000,
    tailChars: 3000,
  );

  /// 仍整文件读入内存的上限；更大的文件改读头尾字节。
  static const int fileReadFullBytes = 200 * 1024;
  static const int fileReadHeadBytes = 80 * 1024;
  static const int fileReadTailBytes = 40 * 1024;

  static const String spilledMarker = '完整输出已写入';
  static const String fileOnDiskMarker = '全文已在磁盘';

  static bool alreadySpilled(String text) =>
      text.contains(spilledMarker) || text.contains(fileOnDiskMarker);

  static bool shouldSpill(String text, {int? thresholdChars}) =>
      ToolResultPruner.codePointLength(text) >
      (thresholdChars ?? previewPruner.thresholdChars);

  static String takeHead(String text, int chars) {
    if (chars <= 0) return '';
    if (ToolResultPruner.codePointLength(text) <= chars) return text;
    return String.fromCharCodes(text.runes.take(chars));
  }

  static String takeTail(String text, int chars) {
    if (chars <= 0) return '';
    final n = ToolResultPruner.codePointLength(text);
    if (n <= chars) return text;
    return String.fromCharCodes(text.runes.skip(n - chars));
  }

  static String spillFileName({
    required String toolName,
    required DateTime at,
    String disambiguator = '',
  }) {
    final safe = toolName.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final extra = disambiguator.isEmpty ? '' : '_$disambiguator';
    return '${at.microsecondsSinceEpoch}_$safe$extra.txt';
  }

  static String envelope({
    required String preview,
    required String path,
    required int originalChars,
  }) {
    return '$preview\n\n[... $spilledMarker $path，共 $originalChars 字符。'
        '以上为头尾预览，请用 file_read 查看全文 ...]';
  }

  static String fileReadEnvelope({
    required String head,
    required String tail,
    required String path,
    required int byteLength,
    int? charLength,
  }) {
    final extra = charLength == null ? '' : ' / $charLength 字符';
    return '$head\n\n[... 文件 $path 共 $byteLength 字节$extra，'
        '以上为头尾预览。$fileOnDiskMarker，请用 run_terminal 分段读取'
        "（如 sed -n '1,200p'）...]\n\n$tail";
  }

  /// 已整文件读入内存的 file_read：超预算只裁预览，不复制文件。
  static String boundLoadedFile({
    required String text,
    required String path,
    required int byteLength,
  }) {
    final chars = ToolResultPruner.codePointLength(text);
    if (chars <= fileReadPruner.thresholdChars) return text;
    return fileReadEnvelope(
      head: takeHead(text, fileReadPruner.headChars),
      tail: takeTail(text, fileReadPruner.tailChars),
      path: path,
      byteLength: byteLength,
      charLength: chars,
    );
  }

  /// 超大文件只解码头尾字节后再套预览信封。
  static String boundPartialFile({
    required String headText,
    required String tailText,
    required String path,
    required int byteLength,
  }) {
    return fileReadEnvelope(
      head: takeHead(headText, fileReadPruner.headChars),
      tail: takeTail(tailText, fileReadPruner.tailChars),
      path: path,
      byteLength: byteLength,
    );
  }

  /// 把全文落到 [workspaceDir]/.shiyi/tool-outputs/；写盘失败则只返回头尾预览。
  static Future<String> maybeSpill({
    required String text,
    required String toolName,
    required String workspaceDir,
    DateTime? at,
    String disambiguator = '',
  }) async {
    if (!shouldSpill(text) || alreadySpilled(text)) return text;
    final preview = previewPruner.prune(text);
    final chars = ToolResultPruner.codePointLength(text);
    try {
      final dir = Directory('$workspaceDir/$relativeDir');
      await dir.create(recursive: true);
      final file = File(
        '${dir.path}/${spillFileName(toolName: toolName, at: at ?? DateTime.now(), disambiguator: disambiguator)}',
      );
      await file.writeAsString(text, flush: true);
      return envelope(preview: preview, path: file.path, originalChars: chars);
    } catch (_) {
      return preview;
    }
  }

  /// 超预算时原地截断较早 tool 输出，成对保留 assistant/tool，不抽轮。
  /// 与主会话 oldToolHistoryPruner 同一套 1200/700/300 口径。
  static List<Map<String, dynamic>> compactOldToolOutputs(
    List<Map<String, dynamic>> msgs, {
    ToolResultPruner pruner = const ToolResultPruner(
      thresholdChars: 1200,
      headChars: 700,
      tailChars: 300,
    ),
    int keepRecentGroups = 3,
  }) {
    final groups = <List<int>>[];
    var i = 0;
    while (i < msgs.length) {
      final m = msgs[i];
      final tcs = m['tool_calls'];
      if (m['role'] == 'assistant' && tcs is List && tcs.isNotEmpty) {
        final tools = <int>[];
        var j = i + 1;
        while (j < msgs.length && msgs[j]['role'] == 'tool') {
          tools.add(j);
          j++;
        }
        if (tools.isNotEmpty) groups.add(tools);
        i = j;
      } else {
        i++;
      }
    }
    if (groups.length <= keepRecentGroups) return msgs;
    final prune = <int>{};
    for (var g = 0; g < groups.length - keepRecentGroups; g++) {
      prune.addAll(groups[g]);
    }
    return [
      for (var k = 0; k < msgs.length; k++)
        if (prune.contains(k))
          Map<String, dynamic>.from(msgs[k])
            ..['content'] = pruner.prune('${msgs[k]['content'] ?? ''}')
        else
          msgs[k],
    ];
  }
}

/// 同一轮多个 tool_calls 是否可以并行。
/// 只读工具互不依赖，和 Codex 主循环并行执行对齐；写入/终端/提问保持串行。
class ToolCallScheduler {
  /// 必须与 AgentTool.readOnly 一致，有测试钉死。
  static const Set<String> readOnlyToolNames = {
    'search_sessions',
    'read_session',
    'inspect_runtime',
    'search_memory',
    'run_skill',
    'web_search',
    'web_extract',
    'file_read',
  };

  static bool isReadOnly(String name) => readOnlyToolNames.contains(name);

  static bool runInParallel(
    Iterable<String> names, {
    bool Function(String name)? isReadOnly,
  }) {
    final list = names.toList();
    if (list.length <= 1) return false;
    final check = isReadOnly ?? ToolCallScheduler.isReadOnly;
    return list.every(check);
  }
}
