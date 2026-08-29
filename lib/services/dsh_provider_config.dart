import 'dart:convert';

import 'dsh_api.dart';
import 'dsh_model_sync.dart';

class DshProviderConfig {
  final String id;
  final String displayName;
  final String protocol;
  final String baseUrl;
  final String credentialRef;
  final List<String> models;
  final Map<String, dynamic> raw;

  const DshProviderConfig({
    required this.id,
    required this.displayName,
    required this.protocol,
    required this.baseUrl,
    required this.credentialRef,
    required this.models,
    this.raw = const {},
  });

  /// 目录条目声明的设置命名空间（空 = 内部镜像，如 vision-toolkit-*）。
  String get settingsNs => (raw['settingsNs'] ?? '').toString().trim();

  /// 目录条目声明的设置路径（空 = 无 settings 路由可清除，如内置声明）。
  List<String> get settingsPath =>
      (raw['settingsPath'] as List?)?.map((item) => item.toString()).toList() ??
      const <String>[];

  /// 是否为 DSH 内置声明（有命名空间但没有 settings 路由，如
  /// deepseek-official / llm-deepseek）：不能从设置里删除路由，
  /// 最多清除其凭据。
  bool get isBuiltinDeclared =>
      settingsNs.isNotEmpty &&
      settingsNs != DshModelSync.settingsNs &&
      settingsPath.isEmpty;

  factory DshProviderConfig.fromMap(Map<String, dynamic> source) {
    final id = _providerId(source);
    final rawModels = source['models'];
    final models = <String>[];
    if (rawModels is List) {
      for (final item in rawModels) {
        final value = item is Map
            ? (item['id'] ?? item['name'] ?? '').toString().trim()
            : item.toString().trim();
        if (value.isNotEmpty && !models.contains(value)) models.add(value);
      }
    }
    final name = (source['displayName'] ?? source['name'] ?? id)
        .toString()
        .trim();
    return DshProviderConfig(
      id: id,
      displayName: name.isEmpty ? id : name,
      protocol: shiyiProtocolForDshApi(
        (source['api'] ?? 'openai-completions').toString(),
      ),
      baseUrl: (source['baseURL'] ?? source['baseUrl'] ?? '').toString().trim(),
      credentialRef: (source['apiKeyEnv'] ?? '').toString().trim(),
      models: models,
      raw: Map<String, dynamic>.from(source),
    );
  }

  Map<String, dynamic> toProviderValue({
    required String displayName,
    required String protocol,
    required String baseUrl,
    required String credentialRef,
    required List<String> models,
  }) {
    final value = Map<String, dynamic>.from(raw)
      ..remove('id')
      ..remove('provider')
      ..remove('providerId')
      ..remove('key')
      ..remove('name')
      ..remove('baseUrl')
      ..remove('settingsNs')
      ..remove('settingsPath')
      ..remove('active')
      ..remove('declared');
    value
      ..['displayName'] = displayName.trim().isEmpty ? id : displayName.trim()
      ..['api'] = DshModelSync.dshApiFor(protocol)
      ..['baseURL'] = baseUrl.trim()
      ..['apiKeyEnv'] = credentialRef.trim()
      ..['models'] = [
        for (final model in models)
          if (model.trim().isNotEmpty)
            {'id': model.trim(), 'name': model.trim()},
      ];
    return value;
  }
}

String shiyiProtocolForDshApi(String value) {
  switch (value.trim().toLowerCase()) {
    case 'openai-responses':
      return 'responses';
    case 'anthropic-messages':
      return 'anthropic';
    default:
      return 'openai';
  }
}

String dshProviderIdFromName(String name) {
  final normalized = name
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fff]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
  if (normalized.isEmpty) return 'custom_api';
  final ascii = normalized.replaceAll(RegExp(r'[^\x00-\x7f]'), '');
  if (ascii.isNotEmpty) return ascii;
  final encoded = base64Url
      .encode(utf8.encode(normalized))
      .replaceAll('=', '')
      .toLowerCase();
  final end = encoded.length < 12 ? encoded.length : 12;
  return 'provider_${encoded.substring(0, end)}';
}

String dshCredentialRefForProvider(String providerId) {
  final suffix = providerId
      .trim()
      .toUpperCase()
      .replaceAll(RegExp(r'[^A-Z0-9]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
  return '${suffix.isEmpty ? 'CUSTOM_API' : suffix}_API_KEY';
}

bool isValidDshProviderId(String value) =>
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]*$').hasMatch(value.trim());

bool isValidDshCredentialRef(String value) =>
    RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(value.trim());

List<Map<String, dynamic>> settingsProviderMaps(
  DshSettingsNamespace? namespace,
) {
  if (namespace == null) return const [];
  dynamic raw = namespace.user['providers'];
  if (raw is! Map || raw.isEmpty) raw = namespace.value['providers'];
  if (raw is! Map) return const [];
  return [
    for (final entry in raw.entries)
      if (entry.value is Map)
        {
          'id': entry.key.toString(),
          ...(entry.value as Map).cast<String, dynamic>(),
        },
  ];
}

/// 模型数据页的展示口径：目录里"用户可见"的 provider——
/// 路由已启用（active）或在 llm-pi-ai 手写过路由（declared），且带设置
/// 命名空间。`vision-toolkit-*` 等内部镜像的 settingsNs 为空，不展示；
/// 未启用也未手写的目录噪音（amazon-bedrock 等全套目录项）不展示。
List<Map<String, dynamic>> visibleDirectoryProviderMaps(
  Iterable<Map<String, dynamic>> directory,
) {
  return [
    for (final raw in directory)
      if (_isVisibleDirectoryProvider(raw)) Map<String, dynamic>.from(raw),
  ];
}

bool _isVisibleDirectoryProvider(Map<String, dynamic> provider) {
  final id = _providerId(provider);
  if (id.isEmpty) return false;
  final settingsNs = (provider['settingsNs'] ?? '').toString().trim();
  if (settingsNs.isEmpty) return false;
  return provider['active'] == true || provider['declared'] == true;
}

List<DshModelGroup> dshModelGroupsFromProviders(
  Iterable<Map<String, dynamic>> providers,
) {
  final groups = <DshModelGroup>[];
  for (final provider in providers) {
    final id = _providerId(provider);
    if (id.isEmpty) continue;
    final name = (provider['displayName'] ?? provider['name'] ?? id)
        .toString()
        .trim();
    final rawModels = provider['models'];
    final entries = rawModels is List
        ? rawModels
        : rawModels is Map
        ? rawModels.values
        : const <dynamic>[];
    final models = <DshModelInfo>[];
    for (final item in entries) {
      final modelId = item is Map
          ? (item['id'] ?? item['model'] ?? item['name'] ?? '')
                .toString()
                .trim()
          : item.toString().trim();
      if (modelId.isEmpty) continue;
      models.add(
        DshModelInfo(
          id: modelId,
          name: item is Map ? (item['name'] ?? modelId).toString() : modelId,
          providerId: id,
          providerName: name,
        ),
      );
    }
    if (models.isEmpty) continue;
    groups.add(DshModelGroup(id: id, name: name, models: models));
  }
  return groups;
}

List<DshProviderConfig> mergeDshProviderConfigs({
  required Iterable<Map<String, dynamic>> settings,
  required Iterable<Map<String, dynamic>> directory,
  required Iterable<DshModelGroup> groups,
}) {
  final byId = <String, Map<String, dynamic>>{};
  void merge(Map<String, dynamic> source) {
    final id = _providerId(source);
    if (id.isEmpty) return;
    final previous = byId[id] ?? const <String, dynamic>{};
    final models = <String>{
      ...DshProviderConfig.fromMap(previous).models,
      ...DshProviderConfig.fromMap(source).models,
    };
    final merged = <String, dynamic>{'id': id, ...previous, ...source};
    for (final key in const [
      'displayName',
      'name',
      'api',
      'baseURL',
      'baseUrl',
      'apiKeyEnv',
    ]) {
      final next = merged[key]?.toString().trim() ?? '';
      final old = previous[key]?.toString().trim() ?? '';
      if (next.isEmpty && old.isNotEmpty) merged[key] = previous[key];
    }
    if (models.isNotEmpty) {
      merged['models'] = [
        for (final model in models) {'id': model, 'name': model},
      ];
    }
    byId[id] = merged;
  }

  for (final source in settings) {
    merge(source);
  }
  for (final source in visibleDirectoryProviderMaps(directory)) {
    merge(source);
  }
  for (final group in groups) {
    final current = byId[group.id];
    if (current == null) continue;
    final models = <String>{
      ...DshProviderConfig.fromMap(current).models,
      for (final model in group.models)
        if (model.id.trim().isNotEmpty) model.id.trim(),
    };
    current['models'] = [
      for (final model in models) {'id': model, 'name': model},
    ];
  }
  final result = [
    for (final raw in byId.values)
      if (_providerId(raw).isNotEmpty) DshProviderConfig.fromMap(raw),
  ];
  result.sort(
    (a, b) =>
        a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
  );
  return result;
}

String _providerId(Map source) =>
    (source['id'] ??
            source['provider'] ??
            source['providerId'] ??
            source['key'] ??
            '')
        .toString()
        .trim();
