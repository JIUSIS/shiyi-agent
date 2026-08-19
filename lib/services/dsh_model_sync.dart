import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/models.dart';
import 'dsh_api.dart';
import 'dsh_service.dart';

/// 一份已注入到 DSH 的 API 配置。每份对应 `llm-pi-ai.providers` 下的一个提供商。
class DshInjectedConfig {
  final String id;
  final String name;
  final String baseUrl;
  final String apiProtocol;
  final String model;
  final String credentialEnv;

  const DshInjectedConfig({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.apiProtocol,
    required this.model,
    required this.credentialEnv,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'baseUrl': baseUrl,
    'apiProtocol': apiProtocol,
    'model': model,
    'credentialEnv': credentialEnv,
  };

  factory DshInjectedConfig.fromJson(Map<String, dynamic> j) =>
      DshInjectedConfig(
        id: (j['id'] ?? '').toString().trim(),
        name: (j['name'] ?? '').toString().trim(),
        baseUrl: (j['baseUrl'] ?? '').toString().trim(),
        apiProtocol: (j['apiProtocol'] ?? 'openai').toString().trim(),
        model: (j['model'] ?? '').toString().trim(),
        credentialEnv: (j['credentialEnv'] ?? '').toString().trim(),
      );
}

/// 把拾忆模型 API 配置同步到 DeepSeek Harness。
///
/// 每份已保存并注入的 API 配置写成独立的 `llm-pi-ai.providers.shiyi_*` 路由：
/// `api` + `baseURL` + 非空 `models`，密钥只进 `.credentials.yaml`。
/// 新注入只追加或更新对应项，不会覆盖其它已注入配置。
class DshModelSync {
  static const providerId = 'shiyi';
  static const credentialEnv = 'SHIYI_API_KEY';
  static const searchCredentialEnv = 'SHIYI_DSH_SEARCH_KEY';
  static const displayName = '拾忆';
  static const settingsNs = 'llm-pi-ai';
  static const defaultModelNs = 'agent-default-model';
  static const officialProvider = 'deepseek-official';
  static const _responseModelsPrefsPrefix = 'dsh_response_models_v1_';
  static const _modelCatalogPrefsPrefix = 'dsh_model_catalog_v1_';
  static const _injectedPrefsKey = 'dsh_injected_configs_v1';
  static const _injectedIdsPrefsKey = 'dsh_injected_provider_ids_v1';

  static const searchConfigFile = 'shiyi-free-search.json';
  static const searchNs = 'shiyi-free-search';
  static const legacySearchNs = 'web-search-deepseek';
  static const _defaultModelPatchStart = '# ShiYi agent default model: begin';
  static const _defaultModelPatchEnd = '# ShiYi agent default model: end';

  /// 拾忆协议 -> DSH 手写路由协议。
  static String dshApiFor(String protocol) =>
      protocol == 'anthropic' ? 'anthropic-messages' : 'openai-completions';

  /// DSH 的 pi-ai provider 需要显式的 reasoning 档位才会向部分网关请求
  /// `reasoning_content`。只给明显支持思考输出的模型加默认档位，普通模型
  /// 不注入该字段，避免把不支持 reasoning 的模型误切到 thinking 请求。
  static String? defaultReasoningEffort(String model) {
    final id = model.trim().toLowerCase();
    if (id.isEmpty) return null;
    if (id.contains('deepseek') ||
        id.contains('reasoner') ||
        id.contains('thinking') ||
        id.contains('mimo') ||
        id.contains('qwq') ||
        id.contains('r1') ||
        RegExp(r'(^|[-_/])o[134](?:$|[-_/])').hasMatch(id)) {
      return 'high';
    }
    return null;
  }

  static Map<String, String?>? reasoningEffortsForModel(String model) {
    if (defaultReasoningEffort(model) == null) return null;
    final id = model.trim().toLowerCase();
    // OpenAI o 系列支持 low/medium/high，部分支持 xhigh；不支持 off/max。
    if (RegExp(r'(^|[-_/])o[134](?:$|[-_/])').hasMatch(id)) {
      return const {'low': 'low', 'medium': 'medium', 'high': 'high'};
    }
    // DeepSeek / QwQ / R1 等支持 off/low/medium/high/max。
    return const {
      'off': null,
      'low': 'low',
      'medium': 'medium',
      'high': 'high',
      'max': 'max',
    };
  }

  static bool _isMissingPiAiSettings(Object error) =>
      error is DshApiException &&
      error.code == 'settings-rejected' &&
      error.message.contains('namespace "$settingsNs" is not registered');

  static bool canWriteProvider(AppSettings s) =>
      s.baseUrl.trim().isNotEmpty && s.model.trim().isNotEmpty;

  /// 已保存配置名对应的 DSH 提供商 id。默认/无名配置仍用 [providerId]。
  static String providerIdForName(String name) {
    final slug = name
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9一-鿿]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    if (slug.isEmpty || slug == providerId) return providerId;
    final ascii = slug.replaceAll(RegExp(r'[^\x00-\x7F]'), '');
    if (ascii.isEmpty) {
      final digest = base64Url
          .encode(utf8.encode(slug))
          .replaceAll('=', '')
          .toLowerCase();
      return '${providerId}_${digest.substring(0, digest.length.clamp(0, 12))}';
    }
    return '${providerId}_$ascii';
  }

  static String credentialEnvFor(String id) {
    final value = id.trim();
    if (value.isEmpty || value == providerId) return credentialEnv;
    final suffix = value.startsWith('${providerId}_')
        ? value.substring(providerId.length + 1)
        : value;
    final envSuffix = suffix
        .toUpperCase()
        .replaceAll(RegExp(r'[^A-Z0-9]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    if (envSuffix.isEmpty) return credentialEnv;
    return '${credentialEnv}_$envSuffix';
  }

  static bool isManagedProviderId(String id) {
    final value = id.trim();
    return value == providerId || value.startsWith('${providerId}_');
  }

  static Future<List<DshInjectedConfig>> listInjectedConfigs() async {
    final prefs = await SharedPreferences.getInstance();
    await _migrateLegacyInjectedIds(prefs);
    final raw = prefs.getString(_injectedPrefsKey);
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return [
        for (final item in list)
          if (item is Map)
            DshInjectedConfig.fromJson(item.cast<String, dynamic>()),
      ].where((e) => e.id.isNotEmpty).toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> _saveInjectedConfigs(
    List<DshInjectedConfig> items,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _injectedPrefsKey,
      jsonEncode([for (final item in items) item.toJson()]),
    );
    await prefs.setStringList(_injectedIdsPrefsKey, [
      for (final item in items) item.id,
    ]);
  }

  static Future<void> _migrateLegacyInjectedIds(SharedPreferences prefs) async {
    if (prefs.containsKey(_injectedPrefsKey)) return;
    final ids = prefs.getStringList(_injectedIdsPrefsKey) ?? const [];
    if (ids.isEmpty) return;
    await prefs.setString(
      _injectedPrefsKey,
      jsonEncode([
        for (final id in ids)
          if (id.trim().isNotEmpty)
            DshInjectedConfig(
              id: id.trim(),
              name: id.trim() == providerId ? displayName : id.trim(),
              baseUrl: '',
              apiProtocol: 'openai',
              model: '',
              credentialEnv: credentialEnvFor(id.trim()),
            ).toJson(),
      ]),
    );
  }

  static DshInjectedConfig _configFromSettings(AppSettings s, {String? name}) {
    final label = (name ?? '').trim();
    final id = label.isEmpty ? providerId : providerIdForName(label);
    return DshInjectedConfig(
      id: id,
      name: label.isEmpty ? displayName : label,
      baseUrl: s.baseUrl.trim(),
      apiProtocol: s.apiProtocol.trim().isEmpty
          ? 'openai'
          : s.apiProtocol.trim(),
      model: s.model.trim(),
      credentialEnv: credentialEnvFor(id),
    );
  }

  static List<DshInjectedConfig> configsForDisplay({
    required List<DshInjectedConfig> stored,
    AppSettings? settings,
  }) {
    if (stored.isNotEmpty) return List<DshInjectedConfig>.from(stored);
    if (settings != null && canWriteProvider(settings)) {
      return [_configFromSettings(settings)];
    }
    return const [];
  }

  static Future<DshInjectedConfig> rememberInjectedConfig(
    AppSettings s, {
    String? name,
  }) async {
    final incoming = _configFromSettings(s, name: name);
    final current = await listInjectedConfigs();
    final next = <DshInjectedConfig>[];
    var replaced = false;
    for (final item in current) {
      final sameId = item.id == incoming.id;
      final sameName =
          incoming.name.isNotEmpty &&
          incoming.name != displayName &&
          item.name == incoming.name;
      if (sameId || sameName) {
        if (!replaced) next.add(incoming);
        replaced = true;
      } else {
        next.add(item);
      }
    }
    if (!replaced) next.add(incoming);
    await _saveInjectedConfigs(next);
    return incoming;
  }

  static DshInjectedConfig? injectedConfigForSettings(
    AppSettings s,
    Iterable<DshInjectedConfig> injected, {
    String? name,
  }) {
    final label = (name ?? '').trim();
    if (label.isNotEmpty) {
      final id = providerIdForName(label);
      for (final item in injected) {
        if (item.id == id || item.name == label) return item;
      }
    }
    final baseUrl = s.baseUrl.trim();
    final protocol = s.apiProtocol.trim();
    for (final item in injected) {
      if (item.baseUrl == baseUrl &&
          (item.apiProtocol.isEmpty || item.apiProtocol == protocol)) {
        return item;
      }
    }
    return null;
  }

  static String providerIdForSettings(
    AppSettings s,
    Iterable<DshInjectedConfig> injected, {
    String? name,
  }) =>
      injectedConfigForSettings(s, injected, name: name)?.id ??
      ((name ?? '').trim().isEmpty ? providerId : providerIdForName(name!));

  static Future<({String id, String name, String env})> _targetProvider(
    AppSettings s, {
    String? name,
  }) async {
    final injected = await listInjectedConfigs();
    final match = injectedConfigForSettings(s, injected, name: name);
    if (match != null) {
      return (id: match.id, name: match.name, env: match.credentialEnv);
    }
    final fallback = _configFromSettings(s, name: name);
    return (id: fallback.id, name: fallback.name, env: fallback.credentialEnv);
  }

  /// llm-pi-ai 模型条目。`input` 声明模型能力（缺省只有 text，
  /// read_image 工具会因「未声明 image input」报错）；拾忆开启视觉时
  /// 主模型声明 [text, image]，视觉模型若不同则单独加入列表。
  static Map<String, dynamic> _modelEntry(String id, bool vision) {
    final reasoningEfforts = reasoningEffortsForModel(id);
    return {
      'id': id,
      'name': id,
      'input': vision ? ['text', 'image'] : ['text'],
      ...?(reasoningEfforts == null
          ? null
          : {'reasoningEfforts': reasoningEfforts}),
    };
  }

  static Map<String, dynamic> providerProfile(
    AppSettings s, {
    Iterable<String> responseModels = const [],
    Iterable<String> catalogModels = const [],
    String? provider,
    String? name,
    String? apiKeyEnv,
  }) {
    final primary = s.model.trim();
    final vision = s.visionModel.trim();
    final seen = <String>{primary};
    final models = <Map<String, dynamic>>[
      _modelEntry(primary, s.visionEnabled),
    ];
    if (s.visionEnabled && vision.isNotEmpty && seen.add(vision)) {
      models.add(_modelEntry(vision, true));
    }
    final aliases = _normalizedResponseModels([
      ..._compatibilityResponseModels(primary),
      ...responseModels,
      ...catalogModels,
    ]).toList()..sort();
    for (final alias in aliases) {
      if (seen.add(alias)) models.add(_modelEntry(alias, s.visionEnabled));
    }
    final reasoning = defaultReasoningEffort(primary);
    final id = (provider ?? providerId).trim();
    final label = (name ?? '').trim();
    return {
      'displayName': label.isEmpty ? displayName : label,
      'apiKeyEnv': (apiKeyEnv ?? credentialEnvFor(id)).trim(),
      'api': dshApiFor(s.apiProtocol),
      'baseURL': s.baseUrl.trim(),
      'models': models,
      ...?(reasoning == null ? null : {'reasoning': reasoning}),
    };
  }

  static List<Map<String, dynamic>> mutateOps(
    AppSettings s, {
    Iterable<String> responseModels = const [],
    Iterable<String> catalogModels = const [],
    String? provider,
    String? name,
    String? apiKeyEnv,
  }) {
    final id = (provider ?? providerId).trim();
    return [
      {
        'op': 'set',
        'path': ['providers', id],
        'value': providerProfile(
          s,
          responseModels: responseModels,
          catalogModels: catalogModels,
          provider: id,
          name: name,
          apiKeyEnv: apiKeyEnv,
        ),
      },
    ];
  }

  static List<Map<String, dynamic>> unsetProviderOps(String provider) => [
    {
      'op': 'unset',
      'path': ['providers', provider.trim()],
    },
  ];

  /// `deepseek-chat` 是网关请求别名，但部分网关在响应中回报真实模型
  /// `deepseek-v4-flash`。DSH 子代理会继承后者，预声明可保证首次调用也成功。
  static Set<String> _compatibilityResponseModels(String configuredModel) =>
      configuredModel.trim() == 'deepseek-chat'
      ? const {'deepseek-v4-flash'}
      : const {};

  static Set<String> _normalizedResponseModels(Iterable<String> values) =>
      values
          .map((e) => e.trim())
          .where(
            (e) =>
                e.isNotEmpty &&
                e.length <= 200 &&
                !e.contains(RegExp(r'[\x00-\x1F\x7F]')),
          )
          .toSet();

  static String _responseModelsPrefsKey(AppSettings s) {
    final fingerprint = jsonEncode([
      s.apiProtocol.trim(),
      s.baseUrl.trim(),
      s.model.trim(),
    ]);
    final encoded = base64Url
        .encode(utf8.encode(fingerprint))
        .replaceAll('=', '');
    return '$_responseModelsPrefsPrefix$encoded';
  }

  static String _modelCatalogPrefsKey(AppSettings s) {
    final fingerprint = jsonEncode([s.apiProtocol.trim(), s.baseUrl.trim()]);
    final encoded = base64Url
        .encode(utf8.encode(fingerprint))
        .replaceAll('=', '');
    return '$_modelCatalogPrefsPrefix$encoded';
  }

  /// 当前网关配置已知的真实响应模型，按配置指纹隔离，避免不同网关串用。
  static Future<Set<String>> responseModelsFor(AppSettings s) async {
    final prefs = await SharedPreferences.getInstance();
    return _normalizedResponseModels([
      ..._compatibilityResponseModels(s.model),
      ...?prefs.getStringList(_responseModelsPrefsKey(s)),
    ]);
  }

  /// 设置页通过 /models 获取到的完整模型目录，按接口地址和协议隔离。
  static Future<List<String>> cachedModelCatalogFor(AppSettings s) async {
    final prefs = await SharedPreferences.getInstance();
    return _normalizedResponseModels(
      prefs.getStringList(_modelCatalogPrefsKey(s)) ?? const [],
    ).toList()..sort();
  }

  /// 当前应该注入到 DSH 拾忆提供商的完整模型目录。
  static Future<Set<String>> modelCatalogFor(AppSettings s) async {
    return <String>{
      ...await cachedModelCatalogFor(s),
      ..._compatibilityResponseModels(s.model),
      if (s.model.trim().isNotEmpty) s.model.trim(),
      if (s.visionModel.trim().isNotEmpty) s.visionModel.trim(),
    };
  }

  static Future<List<Map<String, dynamic>>> _mutateOpsFor(
    AppSettings s, {
    Iterable<String> responseModels = const [],
    Iterable<String> catalogModels = const [],
    String? name,
  }) async {
    final target = await _targetProvider(s, name: name);
    return mutateOps(
      s,
      responseModels: responseModels,
      catalogModels: catalogModels,
      provider: target.id,
      name: target.name,
      apiKeyEnv: target.env,
    );
  }

  /// 保存一次获取到的全部模型名称，并立即刷新运行中的 DSH 提供商。
  static Future<bool> rememberModelCatalog(
    AppSettings s,
    Iterable<String> modelIds, {
    DshApiClient? api,
  }) async {
    final incoming = _normalizedResponseModels(modelIds);
    if (incoming.isEmpty) return false;
    final prefs = await SharedPreferences.getInstance();
    final key = _modelCatalogPrefsKey(s);
    final stored = _normalizedResponseModels(
      prefs.getStringList(key) ?? const [],
    );
    final merged = <String>{...stored, ...incoming};
    final changed = merged.length != stored.length;
    if (changed) {
      await prefs.setStringList(key, merged.toList()..sort());
    }
    final client = api;
    if (client != null && canWriteProvider(s)) {
      try {
        await client.mutateSettings(
          settingsNs,
          await _mutateOpsFor(
            s,
            responseModels: await responseModelsFor(s),
            catalogModels: merged,
          ),
        );
      } catch (e) {
        debugPrint('DshModelSync model catalog sync failed: $e');
      }
    }
    return changed;
  }

  /// 从缓存目录移除一个模型。当前主模型和视觉模型由设置页拥有，不允许删除。
  static Future<bool> removeCachedModel(
    AppSettings s,
    String model, {
    DshApiClient? api,
  }) async {
    final target = model.trim();
    if (target.isEmpty ||
        target == s.model.trim() ||
        target == s.visionModel.trim()) {
      return false;
    }
    final prefs = await SharedPreferences.getInstance();
    final key = _modelCatalogPrefsKey(s);
    final stored = _normalizedResponseModels(
      prefs.getStringList(key) ?? const [],
    );
    if (!stored.remove(target)) return false;
    await prefs.setStringList(key, stored.toList()..sort());
    final client = api;
    if (client != null && canWriteProvider(s)) {
      await client.mutateSettings(
        settingsNs,
        await _mutateOpsFor(
          s,
          responseModels: await responseModelsFor(s),
          catalogModels: stored,
        ),
      );
    }
    return true;
  }

  /// 从已注入列表和 DSH 设置里删除一份 API 配置，不影响其它已注入项。
  static Future<bool> removeInjectedConfig(
    String provider, {
    DshApiClient? api,
    Future<bool> Function()? isRunning,
    Future<String> Function()? homeDir,
  }) async {
    final id = provider.trim();
    if (id.isEmpty || !isManagedProviderId(id)) return false;
    final current = await listInjectedConfigs();
    DshInjectedConfig? removed;
    final next = <DshInjectedConfig>[];
    for (final item in current) {
      if (item.id == id) {
        removed = item;
      } else {
        next.add(item);
      }
    }
    await _saveInjectedConfigs(next);

    final running = await (isRunning ?? DshService.instance.isRunning)();
    if (running) {
      final client = api ?? DshApiClient.instance;
      try {
        await client.mutateSettings(settingsNs, unsetProviderOps(id));
      } catch (e) {
        debugPrint('DshModelSync remove provider failed: $e');
      }
      final env = removed?.credentialEnv ?? credentialEnvFor(id);
      if (env != credentialEnv && env != searchCredentialEnv) {
        try {
          await client.unsetCredential(env);
        } catch (e) {
          debugPrint('DshModelSync remove credential failed: $e');
        }
      }
    }
    try {
      final home = await (homeDir ?? DshService.instance.homeDir)();
      await Directory(home).create(recursive: true);
      final file = File('$home/settings.yaml');
      if (await file.exists()) {
        final yaml = removeProviderYaml(await file.readAsString(), id);
        await file.writeAsString(yaml);
      }
      if (removed != null &&
          removed.credentialEnv != credentialEnv &&
          removed.credentialEnv != searchCredentialEnv) {
        final cred = File('$home/.credentials.yaml');
        if (await cred.exists()) {
          final text = upsertCredentialsYaml(
            await cred.readAsString(),
            removed.credentialEnv,
            '',
          );
          await cred.writeAsString(text);
        }
      }
    } catch (e) {
      debugPrint('DshModelSync remove files failed: $e');
    }
    return true;
  }

  /// 记住历史里新发现的 responseModel，并立即刷新运行中 DSH 的 provider。
  static Future<bool> rememberResponseModels(
    AppSettings s,
    Iterable<String> responseModels, {
    DshApiClient? api,
  }) async {
    final incoming = _normalizedResponseModels(responseModels)
      ..remove(s.model.trim())
      ..remove(s.visionModel.trim());
    if (incoming.isEmpty) return false;
    final prefs = await SharedPreferences.getInstance();
    final key = _responseModelsPrefsKey(s);
    final stored = _normalizedResponseModels(
      prefs.getStringList(key) ?? const [],
    );
    final merged = <String>{...stored, ...incoming};
    final changed = merged.length != stored.length;
    if (changed) {
      final ordered = merged.toList()..sort();
      await prefs.setStringList(key, ordered);
    }
    final client = api;
    if (client != null && canWriteProvider(s)) {
      try {
        await client.mutateSettings(
          settingsNs,
          await _mutateOpsFor(
            s,
            responseModels: merged,
            catalogModels: await cachedModelCatalogFor(s),
          ),
        );
      } catch (e) {
        debugPrint('DshModelSync response model sync failed: $e');
      }
    }
    return changed;
  }

  static List<Map<String, dynamic>> defaultModelOps(
    AppSettings s, {
    String? provider,
  }) => [
    {
      'op': 'set',
      'path': ['provider'],
      'value': (provider ?? providerId).trim(),
    },
    {
      'op': 'set',
      'path': ['model'],
      'value': s.model.trim(),
    },
  ];

  static bool isModelSettingsChange(AppSettings before, AppSettings after) =>
      before.baseUrl != after.baseUrl ||
      before.apiKey != after.apiKey ||
      before.model != after.model ||
      before.apiProtocol != after.apiProtocol ||
      before.dshSearchProvider != after.dshSearchProvider ||
      before.dshSearchKey != after.dshSearchKey;

  /// 内置搜索插件独立读取该 JSON，不依赖 DSH settings 插件命名空间。
  static Map<String, dynamic> searchConfig(AppSettings s) => {
    'provider': normalizedSearchProvider(s.dshSearchProvider),
    'region': 'cn-zh',
    'bingMarket': 'zh-CN',
  };

  static String normalizedSearchProvider(String raw) =>
      const {'auto', 'bing', 'ddg', 'ddg-lite', 'deepseek'}.contains(raw)
      ? raw
      : 'auto';

  static String effectiveSearchKey(AppSettings s) {
    final explicit = s.dshSearchKey.trim();
    if (explicit.isNotEmpty) return explicit;
    if (s.baseUrl.trim().contains('api.deepseek.com')) {
      return s.apiKey.trim();
    }
    return '';
  }

  /// 手动注入：把当前拾忆模型配置写入 DSH，并把所有已有会话切到当前模型。
  /// 只追加/更新这一份配置，不会覆盖其它已注入项。
  static Future<void> injectNow(
    AppSettings s, {
    DshApiClient? api,
    Future<bool> Function()? isRunning,
    Future<String> Function()? homeDir,
    String? name,
  }) async {
    await rememberInjectedConfig(s, name: name);
    await syncFromShiyi(
      s,
      api: api,
      isRunning: isRunning,
      homeDir: homeDir,
      allowClear: true,
      name: name,
    );
    final running = await (isRunning ?? DshService.instance.isRunning)();
    if (!running) return;
    final client = api ?? DshApiClient.instance;
    try {
      for (final sess in await client.listSessions()) {
        await applyToSessionIfDifferent(client, sess.sessionId, s, name: name);
      }
    } catch (e) {
      debugPrint('DshModelSync inject sessions failed: $e');
    }
  }

  /// 拾忆设置变更后调用。失败只打日志，不挡拾忆保存。
  /// [allowClear] 为 true 时，拾忆密钥被清空才去卸 DSH 凭据；启动同步不要带这个。
  static Future<void> syncFromShiyi(
    AppSettings s, {
    DshApiClient? api,
    Future<bool> Function()? isRunning,
    Future<String> Function()? homeDir,
    bool allowClear = false,
    String? name,
  }) async {
    try {
      final resolveHome = homeDir ?? DshService.instance.homeDir;
      final running = await (isRunning ?? DshService.instance.isRunning)();
      if (running) {
        final client = api ?? DshApiClient.instance;
        try {
          await syncLive(
            s,
            client,
            homeDir: resolveHome,
            allowClear: allowClear,
            name: name,
          );
        } catch (e) {
          if (!_isMissingPiAiSettings(e)) rethrow;

          // 非法 llm-pi-ai 配置会让整个命名空间加载失败，此时 live RPC
          // 已无法自救。先重写合法文件；生产环境再重启一次 DSH 让插件恢复。
          await syncFiles(s, await resolveHome(), name: name);
          final canRestart =
              api == null && isRunning == null && homeDir == null;
          if (!canRestart) return;
          await DshService.instance.stop();
          if (!await DshService.instance.start()) return;
          await syncLive(
            s,
            DshApiClient.instance,
            homeDir: DshService.instance.homeDir,
            allowClear: allowClear,
            name: name,
          );
        }
      } else {
        await syncFiles(s, await resolveHome(), name: name);
      }
    } catch (e, st) {
      debugPrint('DshModelSync failed: $e\n$st');
    }
  }

  @visibleForTesting
  static Future<void> syncLive(
    AppSettings s,
    DshApiClient api, {
    Future<String> Function()? homeDir,
    bool allowClear = false,
    String? name,
  }) async {
    final home = await (homeDir ?? DshService.instance.homeDir)();
    await writeSearchConfig(home, s);
    await cleanupLegacySearchSettingsFile(home);
    final target = await _targetProvider(s, name: name);
    await syncAgentDefaultModelPatch(home, s, provider: target.id);
    if (canWriteProvider(s)) {
      final responseModels = await responseModelsFor(s);
      final catalogModels = await cachedModelCatalogFor(s);
      await api.mutateSettings(
        settingsNs,
        mutateOps(
          s,
          responseModels: responseModels,
          catalogModels: catalogModels,
          provider: target.id,
          name: target.name,
          apiKeyEnv: target.env,
        ),
      );
      try {
        await api.mutateSettings(
          defaultModelNs,
          defaultModelOps(s, provider: target.id),
        );
      } catch (_) {
        // Android 精简预设未必挂 agent-default-model，会话创建时再 selectModel。
      }
    }
    var credentialsOk = true;
    Future<void> syncCredential(String ref, String value) async {
      if (value.isEmpty && !allowClear) return;
      try {
        if (value.isEmpty) {
          await api.unsetCredential(ref);
        } else {
          await api.setCredential(ref, value);
        }
      } catch (e) {
        credentialsOk = false;
        debugPrint('DshModelSync credential sync failed ($ref): $e');
      }
    }

    await syncCredential(target.env, s.apiKey.trim());
    await syncCredential(searchCredentialEnv, effectiveSearchKey(s));
    if (!credentialsOk) {
      await writeCredentialsFile(
        home,
        s.apiKey.trim(),
        searchKey: effectiveSearchKey(s),
        apiKeyEnv: target.env,
      );
    }
  }

  @visibleForTesting
  static Future<void> syncFiles(
    AppSettings s,
    String home, {
    String? name,
  }) async {
    await Directory(home).create(recursive: true);
    final file = File('$home/settings.yaml');
    var yaml = await file.exists() ? await file.readAsString() : '';
    final target = await _targetProvider(s, name: name);
    if (canWriteProvider(s)) {
      final responseModels = await responseModelsFor(s);
      final catalogModels = await cachedModelCatalogFor(s);
      yaml = upsertSettingsYaml(
        yaml,
        baseUrl: s.baseUrl,
        model: s.model,
        apiProtocol: s.apiProtocol,
        visionEnabled: s.visionEnabled,
        visionModel: s.visionModel,
        responseModels: [...responseModels, ...catalogModels],
        provider: target.id,
        name: target.name,
        apiKeyEnv: target.env,
      );
      yaml = upsertDefaultModelYaml(yaml, s.model, provider: target.id);
    }
    yaml = removeLegacySearchSections(yaml);
    await file.writeAsString(yaml);
    await writeSearchConfig(home, s);
    await writeCredentialsFile(
      home,
      s.apiKey.trim(),
      searchKey: effectiveSearchKey(s),
      apiKeyEnv: target.env,
    );
    await syncAgentDefaultModelPatch(home, s, provider: target.id);
  }

  /// 写入 Cordis 组合层默认模型，spawn/fork 子代理会读取这里而不是
  /// settings.yaml 的网页 Agent 默认配置。该受管区块不改动用户其他补丁。
  @visibleForTesting
  static Future<void> syncAgentDefaultModelPatch(
    String home,
    AppSettings s, {
    String? provider,
  }) async {
    await Directory(home).create(recursive: true);
    final patch = File('$home/cordis.patch.yml');
    final existing = await patch.exists() ? await patch.readAsString() : '';
    final next = canWriteProvider(s)
        ? upsertAgentDefaultModelPatchYaml(
            existing,
            s.model,
            provider: provider,
          )
        : removeAgentDefaultModelPatchYaml(existing);
    if (next != existing) await patch.writeAsString(next);
  }

  /// 把拾忆默认模型补丁写入 Cordis 组合层。Cordis 会把该配置用于
  /// spawn/fork 的新 Agent，因此不能只写 settings.yaml。
  @visibleForTesting
  static String upsertAgentDefaultModelPatchYaml(
    String existing,
    String model, {
    String? provider,
  }) {
    final id = (provider ?? providerId).trim();
    final base = removeAgentDefaultModelPatchYaml(existing).trimRight();
    final block =
        '$_defaultModelPatchStart\n'
        '- id: $defaultModelNs\n'
        '  config:\n'
        '    provider: $id\n'
        '    model: ${yamlScalar(model)}\n'
        '$_defaultModelPatchEnd';
    if (base.endsWith('[]')) {
      final head = base.substring(0, base.length - 2).trimRight();
      return head.isEmpty ? '$block\n' : '$head\n$block\n';
    }
    return base.isEmpty ? '$block\n' : '$base\n$block\n';
  }

  @visibleForTesting
  static String removeAgentDefaultModelPatchYaml(String existing) {
    final start = existing.indexOf(_defaultModelPatchStart);
    if (start < 0) return existing;
    final end = existing.indexOf(_defaultModelPatchEnd, start);
    if (end < 0) return existing;
    final after = end + _defaultModelPatchEnd.length;
    final beforeText = existing.substring(0, start).trimRight();
    final afterText = existing.substring(after).trimLeft();
    if (beforeText.isEmpty) return afterText;
    if (afterText.isEmpty) return '$beforeText\n';
    return '$beforeText\n$afterText';
  }

  @visibleForTesting
  static Future<void> writeSearchConfig(String home, AppSettings s) async {
    await Directory(home).create(recursive: true);
    final target = File('$home/$searchConfigFile');
    final tmp = File('$home/$searchConfigFile.tmp');
    final text =
        '${const JsonEncoder.withIndent('  ').convert(searchConfig(s))}\n';
    await tmp.writeAsString(text);
    await tmp.rename(target.path);
  }

  @visibleForTesting
  static Future<void> cleanupLegacySearchSettingsFile(String home) async {
    final target = File('$home/settings.yaml');
    if (!await target.exists()) return;
    final existing = await target.readAsString();
    final next = removeLegacySearchSections(existing);
    if (next == existing) return;
    final tmp = File('$home/settings.yaml.tmp');
    await tmp.writeAsString(next);
    await tmp.rename(target.path);
  }

  /// DSH 只认 owner-only（0600）的 `.credentials.yaml`，group/other 可读会拒读。
  @visibleForTesting
  static Future<void> writeCredentialsFile(
    String home,
    String key, {
    String searchKey = '',
    String apiKeyEnv = credentialEnv,
  }) async {
    await Directory(home).create(recursive: true);
    final cred = File('$home/.credentials.yaml');
    final existing = await cred.exists() ? await cred.readAsString() : '';
    var text = upsertCredentialsYaml(existing, apiKeyEnv, key);
    text = upsertCredentialsYaml(text, searchCredentialEnv, searchKey);
    final tmp = File('$home/.credentials.yaml.tmp');
    await tmp.writeAsString(text);
    await restrictOwnerOnly(tmp.path);
    // POSIX rename 原子覆盖目标：不要先 delete 再 rename——
    // 两步之间有被杀/并发写窗口，会留下丢失或损坏的凭据文件。
    await tmp.rename(cred.path);
    await restrictOwnerOnly(cred.path);
  }

  @visibleForTesting
  static Future<void> restrictOwnerOnly(String path) async {
    if (Platform.isWindows) return;
    final result = await Process.run('chmod', ['600', path]);
    if (result.exitCode != 0) {
      debugPrint('chmod 600 failed for credentials: ${result.stderr}');
    }
  }

  static String yamlScalar(String s) {
    final t = s.trim();
    if (t.isEmpty) return "''";
    if (RegExp(r'^[A-Za-z0-9_./+-]+$').hasMatch(t)) return t;
    // YAML 双引号字符串：转义反斜杠、双引号与全部控制字符。
    // 裸换行/制表符会让 DSH 的 YAML 解析器报 UNEXPECTED_TOKEN
    //（实测 API key 粘贴带入换行 → .credentials.yaml 非法 → 启动即崩）。
    final buf = StringBuffer('"');
    for (final r in t.runes) {
      if (r == 0x5C) {
        buf.write(r'\\');
      } else if (r == 0x22) {
        buf.write(r'\"');
      } else if (r == 0x0A) {
        buf.write(r'\n');
      } else if (r == 0x0D) {
        buf.write(r'\r');
      } else if (r == 0x09) {
        buf.write(r'\t');
      } else if (r < 0x20 || r == 0x7F) {
        buf.write('\\u${r.toRadixString(16).padLeft(4, '0')}');
      } else {
        buf.writeCharCode(r);
      }
    }
    buf.write('"');
    return buf.toString();
  }

  static String renderShiyiProviderBlock({
    required String baseUrl,
    required String model,
    required String apiProtocol,
    bool visionEnabled = false,
    String visionModel = '',
    Iterable<String> responseModels = const [],
    int indent = 4,
    String provider = providerId,
    String? name,
    String? apiKeyEnv,
  }) {
    final pad = ' ' * indent;
    final child = ' ' * (indent + 2);
    final item = ' ' * (indent + 4);
    final mainReasoningEfforts = reasoningEffortsForModel(model);
    final id = provider.trim().isEmpty ? providerId : provider.trim();
    final label = (name ?? '').trim();
    final lines = <String>[
      '$pad$id:',
      '${child}displayName: ${yamlScalar(label.isEmpty ? displayName : label)}',
      '${child}apiKeyEnv: ${apiKeyEnv ?? credentialEnvFor(id)}',
      '${child}api: ${dshApiFor(apiProtocol)}',
      '${child}baseURL: ${yamlScalar(baseUrl)}',
    ];
    final reasoning = defaultReasoningEffort(model);
    if (reasoning != null) lines.add('${child}reasoning: $reasoning');
    lines.addAll([
      '${child}models:',
      '$item- id: ${yamlScalar(model)}',
      '$item  name: ${yamlScalar(model)}',
      '$item  input: ${visionEnabled ? '[text, image]' : '[text]'}',
    ]);
    if (mainReasoningEfforts != null) {
      lines.addAll(_renderReasoningEfforts(item));
    }
    if (visionEnabled &&
        visionModel.trim().isNotEmpty &&
        visionModel.trim() != model.trim()) {
      lines.addAll([
        '$item- id: ${yamlScalar(visionModel.trim())}',
        '$item  name: ${yamlScalar(visionModel.trim())}',
        '$item  input: [text, image]',
      ]);
      if (reasoningEffortsForModel(visionModel) != null) {
        lines.addAll(_renderReasoningEfforts(item));
      }
    }
    final seen = <String>{model.trim(), visionModel.trim()};
    final aliases = _normalizedResponseModels([
      ..._compatibilityResponseModels(model),
      ...responseModels,
    ]).toList()..sort();
    for (final alias in aliases) {
      if (!seen.add(alias)) continue;
      lines.addAll([
        '$item- id: ${yamlScalar(alias)}',
        '$item  name: ${yamlScalar(alias)}',
        '$item  input: ${visionEnabled ? '[text, image]' : '[text]'}',
      ]);
      if (reasoningEffortsForModel(alias) != null) {
        lines.addAll(_renderReasoningEfforts(item));
      }
    }
    return lines.join('\n');
  }

  static List<String> _renderReasoningEfforts(String item) => [
    '$item  reasoningEfforts:',
    '$item    off: null',
    '$item    low: low',
    '$item    high: high',
    '$item    max: max',
  ];

  static String upsertSettingsYaml(
    String existing, {
    required String baseUrl,
    required String model,
    required String apiProtocol,
    bool visionEnabled = false,
    String visionModel = '',
    Iterable<String> responseModels = const [],
    String provider = providerId,
    String? name,
    String? apiKeyEnv,
  }) {
    final id = provider.trim().isEmpty ? providerId : provider.trim();
    final block = renderShiyiProviderBlock(
      baseUrl: baseUrl,
      model: model,
      apiProtocol: apiProtocol,
      visionEnabled: visionEnabled,
      visionModel: visionModel,
      responseModels: responseModels,
      provider: id,
      name: name,
      apiKeyEnv: apiKeyEnv,
    );
    final lines = _splitLines(existing);
    final ns = _findKey(lines, 0, lines.length, 0, settingsNs);
    if (ns == null) {
      final out = <String>[
        ..._trimTrailingEmpty(lines),
        if (lines.any((l) => l.trim().isNotEmpty)) '',
        '$settingsNs:',
        '  providers:',
        ...block.split('\n'),
        '',
      ];
      return out.join('\n');
    }
    final nsEnd = _blockEnd(lines, ns, 0);
    final providers = _findKey(lines, ns + 1, nsEnd, 2, 'providers');
    if (providers == null) {
      final next = [
        ...lines.sublist(0, nsEnd),
        '  providers:',
        ...block.split('\n'),
        ...lines.sublist(nsEnd),
      ];
      return _joinLines(next);
    }
    final providersEnd = _blockEnd(lines, providers, 2);
    final found = _findKey(lines, providers + 1, providersEnd, 4, id);
    if (found == null) {
      final next = [
        ...lines.sublist(0, providersEnd),
        ...block.split('\n'),
        ...lines.sublist(providersEnd),
      ];
      return _joinLines(next);
    }
    final foundEnd = _blockEnd(lines, found, 4);
    final next = [
      ...lines.sublist(0, found),
      ...block.split('\n'),
      ...lines.sublist(foundEnd),
    ];
    return _joinLines(next);
  }

  static String removeProviderYaml(String existing, String provider) {
    final id = provider.trim();
    if (id.isEmpty) return existing;
    final lines = _splitLines(existing);
    final ns = _findKey(lines, 0, lines.length, 0, settingsNs);
    if (ns == null) return existing;
    final nsEnd = _blockEnd(lines, ns, 0);
    final providers = _findKey(lines, ns + 1, nsEnd, 2, 'providers');
    if (providers == null) return existing;
    final providersEnd = _blockEnd(lines, providers, 2);
    final found = _findKey(lines, providers + 1, providersEnd, 4, id);
    if (found == null) return existing;
    final foundEnd = _blockEnd(lines, found, 4);
    return _joinLines([...lines.sublist(0, found), ...lines.sublist(foundEnd)]);
  }

  /// 搜索配置已迁移到独立 JSON；清理旧设置段，避免 DSH 加载未知命名空间。
  static String removeLegacySearchSections(String existing) {
    var lines = _splitLines(existing);
    for (final namespace in [legacySearchNs, searchNs]) {
      while (true) {
        final found = _findKey(lines, 0, lines.length, 0, namespace);
        if (found == null) break;
        final end = _blockEnd(lines, found, 0);
        lines = [...lines.sublist(0, found), ...lines.sublist(end)];
      }
    }
    return _joinLines(_trimTrailingEmpty(lines));
  }

  static String upsertDefaultModelYaml(
    String existing,
    String model, {
    String? provider,
  }) {
    final id = (provider ?? providerId).trim();
    final block = [
      '$defaultModelNs:',
      '  provider: $id',
      '  model: ${yamlScalar(model)}',
    ].join('\n');
    final lines = _splitLines(existing);
    final found = _findKey(lines, 0, lines.length, 0, defaultModelNs);
    if (found == null) {
      return _joinLines([
        ..._trimTrailingEmpty(lines),
        if (lines.any((l) => l.trim().isNotEmpty)) '',
        ...block.split('\n'),
      ]);
    }
    final end = _blockEnd(lines, found, 0);
    return _joinLines([
      ...lines.sublist(0, found),
      ...block.split('\n'),
      ...lines.sublist(end),
    ]);
  }

  /// 把当前拾忆模型切到指定会话。新建会话后调用。
  static Future<void> applyToSession(
    DshApiClient api,
    String sessionId,
    AppSettings s, {
    String? name,
  }) async {
    if (!canWriteProvider(s) || sessionId.isEmpty) return;
    final target = await _targetProvider(s, name: name);
    await api.selectModel(sessionId, target.id, s.model.trim());
  }

  /// 已经是同 provider + 同模型就不打扰。
  static Future<void> applyToSessionIfDifferent(
    DshApiClient api,
    String sessionId,
    AppSettings s, {
    String? name,
  }) async {
    if (!canWriteProvider(s) || sessionId.isEmpty) return;
    final target = await _targetProvider(s, name: name);
    try {
      final models = await api.sessionModels(sessionId);
      if (models.current.provider == target.id &&
          models.current.model.trim() == s.model.trim()) {
        return;
      }
    } catch (_) {
      return;
    }
    await applyToSession(api, sessionId, s, name: name);
  }

  /// 会话已经选过模型时不要覆盖，避免打开旧会话把用户选择冲掉。
  static Future<void> syncSessionToAppModel(
    DshApiClient api,
    String sessionId,
    AppSettings s,
  ) async {
    if (!canWriteProvider(s) || sessionId.isEmpty) return;
    try {
      final models = await api.sessionModels(sessionId);
      if (models.current.model.trim().isNotEmpty) return;
    } catch (_) {
      return;
    }
    await applyToSession(api, sessionId, s);
  }

  /// 清洗 credentials 文档：只保留 `key:` 行与注释行，丢弃其他行。
  /// 旧版本 yamlScalar 不转义换行时可能写出非法 YAML（DSH 启动即崩），
  /// 清洗让「读入坏文件 → 重写」自动修复，而不是把坏行原样保留。
  static List<String> _sanitizeCredentialLines(List<String> lines) {
    final keyRe = RegExp(r'^[A-Za-z0-9_.-]+\s*:');
    return lines.where((l) {
      final t = l.trimLeft();
      if (t.isEmpty || t.startsWith('#')) return true;
      return keyRe.hasMatch(t);
    }).toList();
  }

  static String upsertCredentialsYaml(
    String existing,
    String key,
    String value,
  ) {
    final lines = _sanitizeCredentialLines(_splitLines(existing));
    final kept = <String>[];
    final prefix = '$key:';
    for (final line in lines) {
      final trimmed = line.trimLeft();
      if (trimmed == prefix || trimmed.startsWith('$prefix ')) continue;
      kept.add(line);
    }
    final compact = _trimTrailingEmpty(kept);
    if (value.isEmpty) {
      return compact.isEmpty ? '' : '${compact.join('\n')}\n';
    }
    compact.add('$key: ${yamlScalar(value)}');
    return '${compact.join('\n')}\n';
  }
}

List<String> _splitLines(String text) {
  if (text.isEmpty) return <String>[];
  final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final lines = normalized.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  return lines;
}

List<String> _trimTrailingEmpty(List<String> lines) {
  final out = [...lines];
  while (out.isNotEmpty && out.last.trim().isEmpty) {
    out.removeLast();
  }
  return out;
}

String _joinLines(List<String> lines) {
  final compact = _trimTrailingEmpty(lines);
  return compact.isEmpty ? '' : '${compact.join('\n')}\n';
}

int? _findKey(List<String> lines, int start, int end, int indent, String key) {
  final exact = '${' ' * indent}$key:';
  for (var i = start; i < end && i < lines.length; i++) {
    final line = lines[i];
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
    final ind = line.length - line.trimLeft().length;
    if (ind < indent) return null;
    if (ind != indent) continue;
    if (line == exact ||
        line.startsWith('$exact ') ||
        line.startsWith('$exact\t')) {
      return i;
    }
  }
  return null;
}

int _blockEnd(List<String> lines, int start, int indent) {
  for (var i = start + 1; i < lines.length; i++) {
    final line = lines[i];
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
    final ind = line.length - line.trimLeft().length;
    if (ind <= indent) return i;
  }
  return lines.length;
}
