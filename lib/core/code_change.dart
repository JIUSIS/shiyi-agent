import 'dart:convert';

import 'text_safe.dart';

/// 写入类的工具名（这些工具会产生「代码改动」）。
const codeChangeToolNames = {
  'file_write',
  'write_file',
  'create_file',
  'file_edit',
  'edit_file',
  'replace_in_file',
  'apply_patch',
  'str_replace',
};

bool isCodeChangeTool(String name) => codeChangeToolNames.contains(name);

/// 工具入参摘要：写入类先给文件路径，其余给第一个有意义的字段。
String toolArgsSummary(String name, String argsJson, {int maxRunes = 40}) {
  if (argsJson.trim().isEmpty) return '';
  Object? decoded;
  try {
    decoded = jsonDecode(argsJson);
  } catch (_) {
    return cutRunes(argsJson.trim(), maxRunes);
  }
  if (decoded is! Map) return '';
  final args = decoded.cast<Object?, Object?>();
  final keys = isCodeChangeTool(name)
      ? const ['path', 'file_path', 'filename', 'file']
      : const ['query', 'url', 'command', 'name', 'content', 'path'];
  for (final key in keys) {
    final value = args[key];
    if (value is String && value.trim().isNotEmpty) {
      return cutRunes(value.trim(), maxRunes);
    }
  }
  return '';
}

/// 从工具原始参数里抽一段可读的「改动预览」；不是写入类工具就返回 null。
///
/// 支持两类入参：
/// - `{path, content}`（file_write / create_file）→ 路径 + 行数 + 内容前若干行
/// - `{path, old_string, new_string}` / `{patch}`（file_edit / apply_patch）→ -/+ 行
String? codeChangePreview(
  String toolName,
  String rawArgs, {
  int maxLines = 16,
}) {
  if (!isCodeChangeTool(toolName)) return null;
  if (rawArgs.trim().isEmpty) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(rawArgs);
  } catch (_) {
    // 不是 JSON（可能是摘要串）：只能原样展示一行。
    return cutRunes(rawArgs.trim(), 200);
  }
  if (decoded is! Map) return null;
  final args = decoded.cast<Object?, Object?>();
  String str(List<String> keys) {
    for (final key in keys) {
      final value = args[key];
      if (value is String && value.trim().isNotEmpty) return value;
    }
    return '';
  }

  final path = str(['path', 'file_path', 'filename', 'file']);
  final content = str(['content', 'text', 'new_content']);
  final oldText = str(['old_string', 'old_text', 'old_str', 'search']);
  final newText = str(['new_string', 'new_text', 'new_str', 'replace']);
  final patch = str(['patch', 'diff', 'input']);

  final out = <String>[];
  if (path.isNotEmpty) out.add('📄 $path');

  void addLines(String prefix, String text, int budget) {
    final lines = text.split('\n');
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    for (final line in lines.take(budget)) {
      out.add('$prefix$line');
    }
    if (lines.length > budget) {
      out.add('$prefix…（共 ${lines.length} 行）');
    }
  }

  if (patch.isNotEmpty) {
    final lines = patch.split('\n');
    final kept = [
      for (final line in lines)
        if (line.startsWith('+') ||
            line.startsWith('-') ||
            line.startsWith('@@') ||
            line.startsWith('***'))
          line,
    ];
    if (kept.isEmpty) {
      addLines('  ', patch, maxLines);
    } else {
      out.addAll(kept.take(maxLines));
      if (kept.length > maxLines) out.add('…（共 ${kept.length} 行改动）');
    }
  } else if (oldText.isNotEmpty || newText.isNotEmpty) {
    if (oldText.isNotEmpty) addLines('- ', oldText, maxLines ~/ 2);
    if (newText.isNotEmpty) addLines('+ ', newText, maxLines ~/ 2);
  } else if (content.isNotEmpty) {
    final lines = content.split('\n');
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    out.add('✚ 写入 ${lines.length} 行');
    addLines('+ ', content, maxLines);
  } else {
    return null;
  }
  return out.join('\n');
}
