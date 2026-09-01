import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'file_workspace.dart';

/// App 级运行审计日志。记录运行事实，不记录明文凭据或完整敏感内容。
class RuntimeLogEntry {
  final String timestamp;
  final String level;
  final String module;
  final String event;
  final String sessionId;
  final String requestId;
  final int? durationMs;
  final String result;
  final Map<String, dynamic> data;

  const RuntimeLogEntry({
    required this.timestamp,
    required this.level,
    required this.module,
    required this.event,
    this.sessionId = '',
    this.requestId = '',
    this.durationMs,
    this.result = '',
    this.data = const {},
  });

  factory RuntimeLogEntry.fromJson(Map<String, dynamic> json) {
    final rawData = json['data'];
    return RuntimeLogEntry(
      timestamp: (json['timestamp'] ?? '').toString(),
      level: (json['level'] ?? 'info').toString(),
      module: (json['module'] ?? '').toString(),
      event: (json['event'] ?? '').toString(),
      sessionId: (json['sessionId'] ?? '').toString(),
      requestId: (json['requestId'] ?? '').toString(),
      durationMs: json['durationMs'] is num
          ? (json['durationMs'] as num).toInt()
          : int.tryParse((json['durationMs'] ?? '').toString()),
      result: (json['result'] ?? '').toString(),
      data: rawData is Map
          ? Map<String, dynamic>.from(rawData)
          : const <String, dynamic>{},
    );
  }

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp,
    'level': level,
    'module': module,
    'event': event,
    if (sessionId.isNotEmpty) 'sessionId': sessionId,
    if (requestId.isNotEmpty) 'requestId': requestId,
    if (durationMs != null) 'durationMs': durationMs,
    if (result.isNotEmpty) 'result': result,
    if (data.isNotEmpty) 'data': data,
  };

  String get oneLine => jsonEncode(toJson());
}

/// 前端操作追踪帧：记录当前操作名与该操作推进到的步骤。
class _UiOp {
  final String operation;
  String step;
  _UiOp(this.operation, this.step);
}

class RuntimeLogger {
  RuntimeLogger._();
  static final RuntimeLogger instance = RuntimeLogger._();

  static const int maxMemoryEntries = 1600;
  static const int maxFileBytes = 8 * 1024 * 1024;
  static const String fileName = 'runtime.jsonl';

  final ValueNotifier<int> revision = ValueNotifier(0);
  final List<RuntimeLogEntry> _memory = <RuntimeLogEntry>[];
  Future<void> _writeTail = Future<void>.value();
  String? _path;

  String? get path => _path;

  /// 当前页面（前端路由）上下文，给错误日志补「在哪一屏出错」。
  String _uiRoute = '';
  /// 当前操作推进到的步骤（如 buildRequest / stream），best-effort 提示。
  String _uiStep = '';
  final List<_UiOp> _uiOps = <_UiOp>[];

  /// 前端导航到某页面时调用，让后续日志带上「当前页面」上下文。
  void uiRoute(String route) => _uiRoute = route;

  /// 前端在操作内推进到某步骤时调用（best-effort，并发会话下提示最近步骤）。
  void uiStep(String step) {
    _uiStep = step;
    if (_uiOps.isNotEmpty) _uiOps.last.step = step;
  }

  /// 运行一段前端操作：开始记 ui.operation；失败时记 ui.error（带操作名/
  /// 页面/会话/步骤），再原样抛出。逻辑并发安全：上下文按操作自身记录。
  Future<T> uiGuard<T>({
    required String route,
    required String operation,
    String? sessionId,
    required Future<T> Function() body,
  }) async {
    final previousRoute = _uiRoute;
    _uiRoute = route;
    _uiOps.add(_UiOp(operation, _uiStep));
    try {
      unawaited(
        log(
          module: 'Ui',
          event: 'ui.operation',
          sessionId: sessionId ?? '',
          data: {'route': route, 'operation': operation, 'action': 'start'},
        ),
      );
      return await body();
    } catch (e, st) {
      // ui.error 尽力而为：即使日志落盘失败也不掩盖原始异常。
      unawaited(
        log(
          level: 'error',
          module: 'Ui',
          event: 'ui.error',
          sessionId: sessionId ?? '',
          result: 'failed',
          data: {
            'route': route,
            'operation': operation,
            'step': _uiStep,
            'error': '$e',
            'stack': '$st',
          },
        ),
      );
      rethrow;
    } finally {
      if (_uiOps.isNotEmpty) _uiOps.removeLast();
      if (_uiOps.isEmpty) _uiStep = '';
      _uiRoute = previousRoute;
    }
  }

  Future<void> info(
    String module,
    String event, {
    String sessionId = '',
    String requestId = '',
    int? durationMs,
    String result = '',
    Map<String, dynamic> data = const {},
  }) => log(
    module: module,
    event: event,
    sessionId: sessionId,
    requestId: requestId,
    durationMs: durationMs,
    result: result,
    data: data,
  );

  Future<void> warn(
    String module,
    String event, {
    String sessionId = '',
    String requestId = '',
    int? durationMs,
    String result = '',
    Map<String, dynamic> data = const {},
  }) => log(
    level: 'warn',
    module: module,
    event: event,
    sessionId: sessionId,
    requestId: requestId,
    durationMs: durationMs,
    result: result,
    data: data,
  );

  Future<void> error(
    String module,
    String event, {
    String sessionId = '',
    String requestId = '',
    int? durationMs,
    String result = '',
    Map<String, dynamic> data = const {},
  }) => log(
    level: 'error',
    module: module,
    event: event,
    sessionId: sessionId,
    requestId: requestId,
    durationMs: durationMs,
    result: result,
    data: data,
  );

  Future<void> log({
    String level = 'info',
    required String module,
    required String event,
    String sessionId = '',
    String requestId = '',
    int? durationMs,
    String result = '',
    Map<String, dynamic> data = const {},
  }) {
    final uiActive = _uiRoute.isNotEmpty || _uiStep.isNotEmpty;
    final finalData = uiActive
        ? <String, dynamic>{
            ...data,
            'ui': <String, dynamic>{
              if (_uiRoute.isNotEmpty) 'route': _uiRoute,
              if (_uiStep.isNotEmpty) 'step': _uiStep,
            },
          }
        : data;
    final entry = RuntimeLogEntry(
      timestamp: DateTime.now().toIso8601String(),
      level: level,
      module: module,
      event: event,
      sessionId: sessionId,
      requestId: requestId,
      durationMs: durationMs,
      result: result,
      data: _redactMap(finalData),
    );
    _memory.add(entry);
    if (_memory.length > maxMemoryEntries) {
      _memory.removeRange(0, _memory.length - maxMemoryEntries);
    }
    revision.value++;
    final write = _writeTail.then<void>((_) => _append(entry));
    _writeTail = write.catchError((_) {});
    return write;
  }

  List<RuntimeLogEntry> recent({int limit = 120}) {
    final n = limit.clamp(1, maxMemoryEntries);
    return _memory.reversed.take(n).toList(growable: false);
  }

  Future<List<RuntimeLogEntry>> read({int limit = 500}) async {
    await _writeTail;
    final file = await _runtimeFile();
    if (!await file.exists()) return recent(limit: limit);
    final text = await file.readAsString();
    final entries = <RuntimeLogEntry>[];
    for (final line in text.split('\n').reversed) {
      if (line.trim().isEmpty) continue;
      try {
        entries.add(RuntimeLogEntry.fromJson(jsonDecode(line)));
      } catch (_) {}
      if (entries.length >= limit.clamp(1, 2000)) break;
    }
    if (entries.isNotEmpty) {
      _memory
        ..clear()
        ..addAll(entries.take(maxMemoryEntries).toList().reversed);
    }
    return entries;
  }

  Future<void> clear() async {
    await _writeTail;
    final file = await _runtimeFile();
    if (await file.exists()) await file.writeAsString('');
    final rotated = File('${file.path}.1');
    if (await rotated.exists()) await rotated.delete();
    _memory.clear();
    revision.value++;
  }

  Future<String> diagnosticSnapshot({int limit = 80}) async {
    final entries = await read(limit: limit);
    final errors = entries.where((e) => e.level == 'error').length;
    final warnings = entries.where((e) => e.level == 'warn').length;
    final modules = <String, int>{};
    for (final e in entries) {
      modules[e.module] = (modules[e.module] ?? 0) + 1;
    }
    return jsonEncode({
      'path': _path ?? '',
      'entries': entries.length,
      'errors': errors,
      'warnings': warnings,
      'modules': modules,
      'recent': entries.map((e) => e.toJson()).toList(),
    });
  }

  Future<File> _runtimeFile() async {
    final dir = await FileWorkspace.ensure();
    final file = File('$dir/logs/$fileName');
    await file.parent.create(recursive: true);
    _path = file.path;
    return file;
  }

  Future<void> _append(RuntimeLogEntry entry) async {
    final file = await _runtimeFile();
    await file.writeAsString(
      '${entry.oneLine}\n',
      mode: FileMode.append,
      flush: true,
    );
    final length = await file.length();
    if (length <= maxFileBytes) return;
    final rotated = File('${file.path}.1');
    if (await rotated.exists()) await rotated.delete();
    await file.rename(rotated.path);
    await file.create(recursive: true);
  }

  static Map<String, dynamic> _redactMap(
    Map<String, dynamic> input,
  ) => Map<String, dynamic>.fromEntries(
    input.entries.map((e) {
      final key = e.key.toString();
      final sensitive = RegExp(
        r'(api[-_]?key|authorization|token|cookie|password|secret|credential)',
        caseSensitive: false,
      ).hasMatch(key);
      return MapEntry(key, sensitive ? '<redacted>' : _redact(e.value));
    }),
  );

  @visibleForTesting
  static dynamic redactForTest(dynamic value) => _redact(value);

  @visibleForTesting
  static Map<String, dynamic> redactMapForTest(Map<String, dynamic> value) =>
      _redactMap(value);

  static dynamic _redact(dynamic value) {
    if (value is Map) {
      return <String, dynamic>{
        for (final e in value.entries) e.key.toString(): _redact(e.value),
      };
    }
    if (value is Iterable) return value.map(_redact).toList();
    if (value is! String) return value;
    var text = value;
    text = text.replaceAll(
      RegExp(
        r'(authorization|api[-_]?key|token|cookie|password|secret)\s*[:=]\s*[^,\s;}]+',
        caseSensitive: false,
      ),
      r'$1=<redacted>',
    );
    text = text.replaceAll(
      RegExp(
        r'\b(sk-[A-Za-z0-9._-]{8,}|xai-[A-Za-z0-9._-]{8,})\b',
        caseSensitive: false,
      ),
      '<redacted>',
    );
    return text.length > 12000
        ? '${text.substring(0, 12000)}…<truncated>'
        : text;
  }
}
