import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:yaml/yaml.dart' as y;

import 'dsh_service.dart';

/// DSH 插件清单中的一行条目。
///
/// [name] 是该插件的模块/包名（如 `@deepseek-ai/dsh-web-search-bing`，
/// 或 `./plugins/xxx/lib/index.js` 的相对路径）。
class DshPluginEntry {
  final String id;

  /// 模块名 / 包名。可能为空（纯 config 覆盖行没有 name）。
  final String? name;

  /// 该条目的 config（可能为空）。
  final Map<String, dynamic> config;

  /// 是否被禁用（Cordis `disabled: true`）。
  final bool disabled;

  /// 是否来自 `insert:` 新装列表（用户/LLM 新增的插件，允许删除）。
  final bool inserted;

  /// 是否为 package.json 的内置 bundle（只读展示，不是可单独编辑的插件行）。
  final bool builtin;

  /// 清单来源：bundle / profile / home / patch。
  final String source;

  DshPluginEntry({
    required this.id,
    this.name,
    this.config = const {},
    this.disabled = false,
    this.inserted = false,
    this.builtin = false,
    this.source = 'patch',
  });
}

class DshPluginStoreException implements Exception {
  final String message;
  DshPluginStoreException(this.message);
  @override
  String toString() => message;
}

/// DSH Cordis 插件清单读写。
///
/// 数据与读写位置：
/// - 全局补丁：`$DSH_HOME/cordis.patch.yml`（App 与用户共享的高优先级层）。
/// - profile 补丁：`$DSH_HOME/profiles/web/cordis.patch.yml`。
/// - 内置 bundle：`$DSH_HOME/profiles/web/package.json` 的 `dsh.profile.bundles`。
///
/// 结构操作（启用/停用/删除/改配置）都在**文本行块**层做，保留补丁里的
/// 用户注释与其他条目；配置值用 Dart 序列化的 YAML 行重写单个条目的
/// `config:` 子块。纯函数（输入 yaml 文本 → 输出 yaml 文本）均可单测。
class DshPluginStore {
  final String homeDir;

  DshPluginStore(this.homeDir);

  static Future<DshPluginStore> fromHome() async {
    final home = await DshService.instance.homeDir();
    return DshPluginStore(home);
  }

  String get profileDir =>
      '$homeDir${Platform.pathSeparator}profiles'
      '${Platform.pathSeparator}web';
  String get homePatchPath =>
      '$homeDir${Platform.pathSeparator}cordis.patch.yml';
  String get profilePatchPath =>
      '$profileDir${Platform.pathSeparator}cordis.patch.yml';

  /// 兼容原 UI 展示；写操作会自动定位条目真实所在的补丁层。
  String get patchPath => homePatchPath;
  String get packageJsonPath =>
      '$profileDir${Platform.pathSeparator}package.json';

  Future<String> _readPatch(String path) async {
    final file = File(path);
    if (!await file.exists()) return '';
    return file.readAsString();
  }

  Future<List<String>> _builtinBundleNames() async {
    final pkg = File(packageJsonPath);
    if (!await pkg.exists()) return const [];
    try {
      final root = jsonDecode(await pkg.readAsString());
      final bundles =
          (((root as Map)['dsh'] as Map?)?['profile'] as Map?)?['bundles'];
      if (bundles is List) {
        return bundles.map((e) => e.toString()).toList();
      }
    } catch (_) {}
    return const [];
  }

  /// 列出运行清单中的全部插件（内置 bundle + profile/home 两层插件行）。
  ///
  /// 只有带 `name` 的补丁行才是插件；`web`、`sandbox-policy`、
  /// `agent-default-model` 等纯配置行不会误显示为可删除插件。
  Future<List<DshPluginEntry>> list() async {
    final profilePatch = await _readPatch(profilePatchPath);
    final homePatch = await _readPatch(homePatchPath);
    final builtins = (await _builtinBundleNames()).map((b) {
      final short = b.split('/').last;
      return DshPluginEntry(
        id: short,
        name: b,
        config: const {},
        builtin: true,
        source: 'bundle',
      );
    }).toList();
    final byId = <String, DshPluginEntry>{
      for (final entry in builtins) entry.id: entry,
    };
    for (final entry in parsePatch(profilePatch, source: 'profile')) {
      if (entry.name?.trim().isNotEmpty == true) byId[entry.id] = entry;
    }
    // home 层优先级高于 profile；同 id 时展示实际生效的 home 条目。
    for (final entry in parsePatch(homePatch, source: 'home')) {
      if (entry.name?.trim().isNotEmpty == true) byId[entry.id] = entry;
    }
    return byId.values.toList();
  }

  // ── 写操作（读 → 修改 → 原子写回）────────────────────────────────────

  /// 启用/停用一个插件。
  Future<String> setDisabled(String id, bool disabled) async {
    return _mutate(id, (block, keyIndent) {
      return _setBlockDisabled(block, keyIndent, disabled);
    });
  }

  /// 删除一个用户插入的插件条目。内置 bundle 不可删除。
  Future<String> remove(String id) async {
    return _mutate(id, null, allowDeleted: true);
  }

  /// 替换某个插件的 config。
  Future<String> updateConfig(String id, Map<String, dynamic> config) async {
    return _mutate(id, (block, keyIndent) {
      return _setBlockConfig(block, keyIndent, config);
    });
  }

  // ── 纯文本变换（可单测，不依赖文件系统）──────────────────────────────

  /// 给补丁文本中的 [id] 条目设置启用/停用，返回新文本；未命中返回 null。
  static String? applySetDisabled(String patch, String id, bool disabled) {
    return editPatchBlocks(
      patch,
      id,
      (block, keyIndent) => _setBlockDisabled(block, keyIndent, disabled),
    );
  }

  /// 从补丁文本删除 [id] 条目，返回新文本；未命中返回 null。
  static String? applyRemove(String patch, String id) {
    return editPatchBlocks(patch, id, null, allowDeleted: true);
  }

  /// 替换补丁文本中 [id] 条目的 config，返回新文本；未命中返回 null。
  static String? applySetConfig(
    String patch,
    String id,
    Map<String, dynamic> config,
  ) {
    return editPatchBlocks(
      patch,
      id,
      (block, keyIndent) => _setBlockConfig(block, keyIndent, config),
    );
  }

  Future<void> _writePatch(String path, String text) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final tmp = File('$path.tmp');
    await tmp.writeAsString(text);
    if (await file.exists()) await file.delete();
    await tmp.rename(path);
  }

  Future<String> _mutate(
    String id,
    List<String>? Function(List<String> block, int keyIndent)? mutator, {
    bool allowDeleted = false,
  }) async {
    // home 层优先级更高；同名条目存在时修改真正生效的那一层。
    for (final path in [homePatchPath, profilePatchPath]) {
      final patch = await _readPatch(path);
      final next = editPatchBlocks(
        patch,
        id,
        mutator,
        allowDeleted: allowDeleted,
      );
      if (next == null) continue;
      if (next.trim() != patch.trim()) await _writePatch(path, next);
      return next;
    }
    throw DshPluginStoreException('未找到可编辑的插件条目：$id');
  }

  // ── 纯文本扫描 + 编辑层（可单测）─────────────────────────────────────

  /// 扫描补丁中的 `- id:` 条目，定位目标，返回每个命中的 (start,end) 行区间。
  ///
  /// 同时识别顶层条目（缩进 0）与 `insert:` 列表内的子条目（缩进≥4）。
  static List<(int, int)> _locateSpans(List<String> lines, String id) {
    final spans = <(int, int)>[];
    var i = 0;
    while (i < lines.length) {
      final line = lines[i];
      if (_isItemStart(line)) {
        final itemIndent = _itemIndent(line);
        final itemId = _itemId(line);
        int end = i + 1;
        if (itemId != null) {
          while (end < lines.length &&
              !_isItemStart(lines[end]) &&
              _indentOf(lines[end]) > itemIndent) {
            end++;
          }
        }
        if (itemId == id) {
          spans.add((i, end));
        }
        i = end > i ? end : i + 1;
        continue;
      }
      i++;
    }
    return spans;
  }

  /// 在按 [id] 定位的条目上应用 [mutator]（行级，传 key 缩进）。返回新文本；
  /// 未命中返回 null；allowDeleted 且 mutator 返回 null 时删除该条目。
  static String? editPatchBlocks(
    String patch,
    String id,
    List<String>? Function(List<String> block, int keyIndent)? mutator, {
    bool allowDeleted = false,
  }) {
    final lines = patch.replaceAll('\r\n', '\n').split('\n');
    final spans = _locateSpans(lines, id);
    if (spans.isEmpty) return null;
    // 从后往前替换，避免行号偏移。
    var work = List<String>.of(lines);
    for (final (start, end) in spans.reversed) {
      final block = work.sublist(start, end);
      final keyIndent = _keyIndent(block);
      List<String>? replacement;
      if (mutator != null) {
        replacement = mutator(block, keyIndent);
      }
      if (replacement == null) {
        if (!allowDeleted) return null;
        work.removeRange(start, end);
      } else {
        work.replaceRange(start, end, replacement);
      }
    }
    return _normalizeOut(work);
  }

  static String _normalizeOut(List<String> lines) {
    final buf = StringBuffer();
    for (final line in lines) {
      buf.writeln(line);
    }
    final text = buf.toString().trimRight();
    return text.isEmpty ? '' : '$text\n';
  }

  static bool _isItemStart(String line) {
    final t = line.trimLeft();
    return t.startsWith('- ') || RegExp(r'^-\S').hasMatch(t);
  }

  static int _itemIndent(String line) {
    // `- ` 左侧的空格数。
    return line.length - line.trimLeft().length;
  }

  static int _indentOf(String line) {
    if (line.trim().isEmpty) return 9999;
    return line.length - line.trimLeft().length;
  }

  static String? _itemId(String line) {
    final t = line.trimLeft();
    final m = RegExp(r'^-\s+id:\s*(.+)$').firstMatch(t);
    return m?.group(1)?.trim();
  }

  /// 计算块内 `id:`/`name:` 等键的缩进（`- ` 缩进 + 2）。
  static int _keyIndent(List<String> block) {
    for (final line in block) {
      final t = line.trimLeft();
      if (t.startsWith('- ')) return line.length - line.trimLeft().length + 2;
      if (t.isNotEmpty && !t.startsWith('#')) {
        return line.length - line.trimLeft().length;
      }
    }
    return 2;
  }

  /// 在条目块内设置 `disabled:`（true/false）。
  static List<String> _setBlockDisabled(
    List<String> block,
    int keyIndent,
    bool disabled,
  ) {
    final hadDisabled = block.any((l) => l.trimLeft().startsWith('disabled:'));
    if (hadDisabled) {
      // 已有 disabled 键：只改写值。
      return block.map((line) {
        final t = line.trimLeft();
        if (!t.startsWith('disabled:')) return line;
        final lead = line.substring(0, line.length - line.trimLeft().length);
        return '${lead}disabled: $disabled';
      }).toList();
    }
    // 在 `- id: xxx` 条目开始行之后补一条 disabled（缩进与其它键一致）。
    final out = <String>[];
    var injected = false;
    for (final line in block) {
      out.add(line);
      if (!injected && line.trimLeft().startsWith('- ')) {
        out.add('${' ' * keyIndent}disabled: $disabled');
        injected = true;
      }
    }
    if (!injected) {
      out.add('${' ' * keyIndent}disabled: $disabled');
    }
    return out;
  }

  /// 替换条目块的 `config:` 子块为新的配置。
  static List<String> _setBlockConfig(
    List<String> block,
    int keyIndent,
    Map<String, dynamic> config,
  ) {
    final head = <String>[];
    var seen = false;
    for (final line in block) {
      final t = line.trimLeft();
      if (t.startsWith('config:')) {
        seen = true;
        final lead = line.substring(0, line.length - line.trimLeft().length);
        head.add('${lead}config:');
        break;
      }
      head.add(line);
    }
    if (!seen) {
      head.add('${' ' * keyIndent}config:');
    }
    head.addAll(_configLines(config, indent: keyIndent + 2));
    return head;
  }

  /// 将配置 Map 序列化为缩进的 YAML 行（对称于 DshModelSync 的手写风格）。
  static List<String> _configLines(
    Map<String, dynamic> map, {
    required int indent,
  }) {
    final out = <String>[];
    _appendMap(map, indent, out);
    return out;
  }

  static void _appendMap(
    Map<String, dynamic> map,
    int indent,
    List<String> out,
  ) {
    for (final entry in map.entries) {
      final key = entry.key;
      final value = entry.value;
      final pad = ' ' * indent;
      final line = '$pad$key:';
      if (value is Map) {
        out.add(line);
        _appendMap(_castMap(value), indent + 2, out);
      } else if (value is List) {
        if (value.isEmpty) {
          out.add('$line []');
        } else {
          out.add(line);
          for (final item in value) {
            out.add('${' ' * (indent + 2)}- ${_scalar(item)}');
          }
        }
      } else if (value == null || (value is String && value.isEmpty)) {
        out.add("$line ''");
      } else {
        out.add('$line ${_scalar(value)}');
      }
    }
  }

  static Map<String, dynamic> _castMap(dynamic v) =>
      (v as Map).map((k, e) => MapEntry(k.toString(), e));

  static String _scalar(dynamic value) {
    if (value is bool) return value ? 'true' : 'false';
    if (value is num) return value.toString();
    final s = value.toString();
    if (RegExp(r'^[A-Za-z0-9_./:@-]+$').hasMatch(s)) return s;
    return _quote(s);
  }

  static String _quote(String s) {
    final b = StringBuffer('"');
    for (final r in s.runes) {
      if (r == 0x5C) {
        b.write(r'\\');
      } else if (r == 0x22) {
        b.write(r'\"');
      } else if (r == 0x0A) {
        b.write(r'\n');
      } else if (r == 0x09) {
        b.write(r'\t');
      } else if (r < 0x20 || r == 0x7F) {
        b.write('\\u${r.toRadixString(16).padLeft(4, '0')}');
      } else {
        b.writeCharCode(r);
      }
    }
    b.write('"');
    return b.toString();
  }

  // ── 只读解析 ─────────────────────────────────────────────────────────

  /// 解析补丁文本为插件条目列表（仅清单中的条目，不含内置 bundle）。
  static List<DshPluginEntry> parsePatch(
    String patch, {
    String source = 'patch',
  }) {
    if (patch.trim().isEmpty) return const [];
    final dynamic root;
    try {
      root = y.loadYaml(patch);
    } catch (e) {
      debugPrint('DshPluginStore: failed to parse patch: $e');
      return const [];
    }
    if (root is! y.YamlList) return const [];
    final out = <DshPluginEntry>[];
    for (final raw in root) {
      if (raw is! y.YamlMap) continue;
      final insert = raw['insert'];
      if (insert is y.YamlList) {
        for (final item in insert) {
          if (item is! y.YamlMap) continue;
          final e = _fromMap(item, inserted: true, source: source);
          if (e != null) out.add(e);
        }
        continue;
      }
      final e = _fromMap(raw, inserted: false, source: source);
      if (e != null) out.add(e);
    }
    return out;
  }

  static DshPluginEntry? _fromMap(
    y.YamlMap map, {
    required bool inserted,
    required String source,
  }) {
    final id = map['id']?.toString();
    if (id == null || id.isEmpty) return null;
    return DshPluginEntry(
      id: id.trim(),
      name: map['name']?.toString(),
      config: _asConfig(map['config']),
      disabled: map['disabled'] == true,
      inserted: inserted,
      source: source,
    );
  }

  static Map<String, dynamic> _asConfig(dynamic v) {
    if (v is y.YamlMap) {
      return _deepToMap(v);
    }
    return const {};
  }

  static Map<String, dynamic> _deepToMap(dynamic node) {
    final out = <String, dynamic>{};
    if (node is y.YamlMap) {
      for (final entry in node.entries) {
        final key = entry.key.toString();
        final value = entry.value;
        if (value is y.YamlMap) {
          out[key] = _deepToMap(value);
        } else if (value is y.YamlList) {
          out[key] = value.map((e) {
            if (e is y.YamlMap) return _deepToMap(e);
            return _plainScalar(e);
          }).toList();
        } else {
          out[key] = _plainScalar(value);
        }
      }
    }
    return out;
  }

  static dynamic _plainScalar(dynamic v) {
    if (v is String || v is num || v is bool) return v;
    if (v == null) return null;
    return v.toString();
  }
}
