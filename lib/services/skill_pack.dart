import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../core/models.dart';

/// 解析出的技能包：SKILL.md 正文 + 描述 + 文本辅助文件 + 大文件清单。
class SkillPack {
  final String name;
  final String description;
  final String content;

  /// 文本辅助文件：相对路径 -> 内容。
  final Map<String, String> files;

  /// 大文件：相对路径 -> 大小（字节），内容在 dirPath 下。
  final Map<String, int> largeFiles;

  /// 解压目录（技能文件实际存放位置）。
  final String dirPath;

  SkillPack({
    required this.name,
    required this.description,
    required this.content,
    this.files = const {},
    this.largeFiles = const {},
    required this.dirPath,
  });
}

/// skill 包（zip）导入 / 导出。
/// 全程流式：zip 由 Android 原生 ZipInputStream 流式解压到磁盘，
/// 小文本文件入内存，大文件留在磁盘，避免超大包 OOM。
class SkillPackIO {
  static const MethodChannel _channel = MethodChannel('shiyi/skillpack');

  /// 文本小文件大小上限。
  static const int _maxTextFile = 256 * 1024;

  /// SKILL.md 正文入库上限（超过截断，防止单行撑爆 CursorWindow）。
  static const int _maxContent = 600 * 1024;

  /// 文本辅助文件总字符数上限（超出部分降级为磁盘大文件）。
  /// 防止 files 列 JSON 过大触发 _pruneOversizedSkills 的静默删除，
  /// 也避免单行撑爆 SQLite CursorWindow。
  static const int _maxFilesChars = 500 * 1024;

  static const Set<String> _textExts = {
    '.md', '.markdown', '.txt', '.json', '.jsonl', '.yaml', '.yml',
    '.sh', '.py', '.js', '.ts', '.jsx', '.tsx', '.dart', '.xml', '.html',
    '.htm', '.css', '.toml', '.ini', '.conf', '.cfg', '.sql', '.c', '.cpp',
    '.h', '.hpp', '.java', '.kt', '.ps1', '.bat', '.csv', '.log', '.r',
    '.rb', '.go', '.rs', '.php', '.vue', '.svg', '.properties', '.list',
    '.gitignore', '.env', '.template', '.prompt', '.text',
  };

  /// 从 zip 文件路径流式导入技能包。
  /// [zipPath] 压缩包路径，[destDir] 解压目标目录（会被清空重建）。
  static Future<SkillPack> importZip({
    required String zipPath,
    required String destDir,
  }) async {
    final dest = Directory(destDir);
    if (dest.existsSync()) dest.deleteSync(recursive: true);
    dest.createSync(recursive: true);

    final rawEntries = await _channel.invokeListMethod<Map<dynamic, dynamic>>(
      'extractZip',
      {'zipPath': zipPath, 'destDir': destDir},
    );
    if (rawEntries == null) throw const FormatException('解压失败：无返回数据');
    final fileMap = <String, int>{};
    for (final e in rawEntries) {
      final path = e['path']?.toString() ?? '';
      final size = int.tryParse('${e['size']}') ?? 0;
      if (path.isNotEmpty) fileMap[path] = size;
    }
    if (fileMap.isEmpty) throw const FormatException('压缩包里没有文件');

    // 若所有条目共享同一顶层目录（技能名/...）且根目录下没有散文件，剥离它作为基名。
    // 否则按原样保留路径（根目录 SKILL.md + 子目录文件是很常见的包结构）。
    final keys = fileMap.keys.toList();
    final topDirs = keys
        .map((k) => k.contains('/') ? k.split('/').first : '')
        .where((d) => d.isNotEmpty)
        .toSet();
    var base = '';
    if (topDirs.length == 1 &&
        topDirs.first.isNotEmpty &&
        keys.every((k) => k.startsWith('${topDirs.first}/'))) {
      base = '${topDirs.first}/';
    }
    String rel(String k) => base.isEmpty ? k : k.substring(base.length);

    // 找 SKILL.md；没有就取最大的 .md 文件。
    String? mdKey;
    for (final k in fileMap.keys) {
      if (rel(k).toLowerCase() == 'skill.md') {
        mdKey = k;
        break;
      }
    }
    if (mdKey == null) {
      String? best;
      var bestSize = -1;
      for (final k in fileMap.keys) {
        final r = rel(k);
        if (r.toLowerCase().endsWith('.md') && fileMap[k]! > bestSize) {
          best = k;
          bestSize = fileMap[k]!;
        }
      }
      if (best != null) mdKey = best;
    }
    if (mdKey == null) throw const FormatException('压缩包里没有 SKILL.md');

    // 若存在共享顶层目录（技能名/...），把文件物理移动到 destDir 根，
    // 保证磁盘结构与剥离后的相对路径一致（否则导出/读取会找不到大文件）。
    if (base.isNotEmpty) {
      final baseDir = Directory('$destDir/$base');
      if (baseDir.existsSync()) {
        final tmpBase =
            '${destDir}_strip_${DateTime.now().millisecondsSinceEpoch}';
        baseDir.renameSync(tmpBase);
        final tmp = Directory(tmpBase);
        for (final f in tmp.listSync(recursive: true)) {
          if (f is File) {
            final relPath = f.path.substring(tmp.path.length + 1);
            final target = File('$destDir/$relPath');
            target.parent.createSync(recursive: true);
            f.renameSync(target.path);
          }
        }
        tmp.deleteSync(recursive: true);
      }
    }

    var content = _readText(File('$destDir/${rel(mdKey)}'));
    if (content.length > _maxContent) {
      content = content.substring(0, _maxContent);
    }
    var description = '';
    final descAbs = '$destDir/description.md';
    if (File(descAbs).existsSync()) {
      description = _readText(File(descAbs)).trim();
    }

    final files = <String, String>{};
    final largeFiles = <String, int>{};
    var filesChars = 0;
    for (final k in fileMap.keys) {
      if (k == mdKey || rel(k).toLowerCase() == 'description.md') continue;
      final r = rel(k);
      if (r.isEmpty) continue;
      final size = fileMap[k]!;
      if (size <= _maxTextFile && _isTextPath(r)) {
        final text = _readText(File('$destDir/$r'));
        if (text.isEmpty) continue;
        if (filesChars + text.length <= _maxFilesChars) {
          files[r] = text;
          filesChars += text.length;
        } else {
          // 总量超预算的文本文件降级为磁盘大文件（文件已在 destDir，可读可导出）。
          largeFiles[r] = size;
        }
      } else {
        largeFiles[r] = size;
      }
    }

    // 技能名：SKILL.md frontmatter > 顶层目录名 > 文件名。
    var name = _frontmatterName(content) ?? '';
    if (name.isEmpty && topDirs.length == 1 && topDirs.first.isNotEmpty) {
      name = topDirs.first;
    }
    if (name.isEmpty) {
      name = rel(mdKey).replaceAll(RegExp(r'\.md$', caseSensitive: false), '');
    }
    final fmDesc = _frontmatterDescription(content);
    if (description.isEmpty && fmDesc != null) description = fmDesc;

    return SkillPack(
      name: name,
      description: description,
      content: _stripFrontmatter(content),
      files: files,
      largeFiles: largeFiles,
      dirPath: destDir,
    );
  }

  /// 把技能打包为 zip 文件：SKILL.md + description.md + 文本文件 + 磁盘大文件。
  static Future<void> exportZip({
    required Skill skill,
    required String zipPath,
  }) async {
    final tmp = Directory(
      '${Directory.systemTemp.path}/skill_export_${skill.id}_${DateTime.now().millisecondsSinceEpoch}',
    );
    tmp.createSync(recursive: true);
    try {
      File('${tmp.path}/SKILL.md').writeAsStringSync(skill.content);
      if (skill.description.isNotEmpty) {
        File('${tmp.path}/description.md').writeAsStringSync(skill.description);
      }
      for (final e in skill.files.entries) {
        final f = File('${tmp.path}/${e.key}');
        f.parent.createSync(recursive: true);
        f.writeAsStringSync(e.value);
      }
      // 复制磁盘大文件（若目录仍存在）。
      final srcDir = Directory(skill.dirPath);
      for (final path in skill.largeFiles.keys) {
        final srcFile = File('${srcDir.path}/$path');
        if (!srcFile.existsSync()) {
          throw Exception('磁盘文件缺失: ${srcFile.path} (dir=${skill.dirPath})');
        }
        final f = File('${tmp.path}/$path');
        f.parent.createSync(recursive: true);
        final inS = srcFile.openRead();
        final outS = f.openWrite();
        await inS.pipe(outS);
      }
      await _channel.invokeMethod<void>(
        'createZip',
        {'srcDir': tmp.path, 'zipPath': zipPath},
      );
    } finally {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    }
  }

  static bool _isTextPath(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0) return false;
    return _textExts.contains(path.substring(dot).toLowerCase());
  }

  static String _readText(File f) {
    try {
      return utf8.decode(f.readAsBytesSync(), allowMalformed: true).trim();
    } catch (_) {
      return '';
    }
  }

  static String? _frontmatterName(String text) {
    final m = RegExp(
      r'^---\s*\n(.*?)\n---',
      dotAll: true,
    ).firstMatch(text.trimLeft());
    if (m == null) return null;
    final n = RegExp(r'^name:\s*(.+)$', multiLine: true).firstMatch(m.group(1)!);
    return n?.group(1)?.trim();
  }

  static String? _frontmatterDescription(String text) {
    final m = RegExp(
      r'^---\s*\n(.*?)\n---',
      dotAll: true,
    ).firstMatch(text.trimLeft());
    if (m == null) return null;
    return _frontmatterValue(m.group(1)!, 'description');
  }

  /// 读取 frontmatter 字段值，支持单行与 YAML 块标量（`|` / `>` 后跟缩进行）。
  static String? _frontmatterValue(String fm, String key) {
    final lines = fm.split('\n');
    final keyPrefix = '$key:';
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (!line.trimLeft().startsWith(keyPrefix)) continue;
      final rest = line.substring(line.indexOf(':') + 1).trim();
      // 块标量：值为空或以 | / > 开头（含 - + 变体），后续缩进行都是内容。
      if (rest.isEmpty ||
          rest == '|' ||
          rest == '>' ||
          rest == '|-' ||
          rest == '|+' ||
          rest == '>-' ||
          rest == '>+') {
        final buf = StringBuffer();
        for (var j = i + 1; j < lines.length; j++) {
          final l = lines[j];
          if (l.trim().isEmpty) {
            buf.writeln('');
          } else if (RegExp(r'^\s').hasMatch(l)) {
            buf.writeln(l.trim());
          } else {
            break;
          }
        }
        return buf.toString().trim();
      }
      return rest;
    }
    return null;
  }

  static String _stripFrontmatter(String text) {
    final t = text.trimLeft();
    final m = RegExp(
      r'^---\s*\n(.*?)\n---\s*\n?',
      dotAll: true,
    ).firstMatch(t);
    return m == null ? t : t.substring(m.end);
  }
}




