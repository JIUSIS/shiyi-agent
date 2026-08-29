import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yaml/yaml.dart';

import '../core/models.dart';
import '../core/reasoning_models.dart';
import 'dsh_api.dart';
import 'dsh_endpoint.dart';
import 'dsh_service.dart';
import 'shiyi_api_relay.dart';
import 'runtime_logger.dart';

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

/// 一次 DSH 会话回合使用的手机 Relay 租约。
///
/// provider / route 对同一手机、配置和会话保持稳定，保证模型请求前缀不因
/// 每轮 token 轮换而变化；token 只存在于本回合，结束后立即撤销。
class DshRelayLease {
  final DshApiClient api;
  final String sessionId;
  final String profileId;
  final String model;
  final String provider;
  final String credential;
  final String routeId;
  final String token;
  final String scopeKey;
  final String previousProvider;
  final String previousModel;
  final String? previousReasoningEffort;

  const DshRelayLease({
    required this.api,
    required this.sessionId,
    required this.profileId,
    required this.model,
    required this.provider,
    required this.credential,
    required this.routeId,
    required this.token,
    required this.scopeKey,
    this.previousProvider = '',
    this.previousModel = '',
    this.previousReasoningEffort,
  });
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
  static const relayProvider = 'shiyi_relay';
  static const relayCredentialEnv = 'SHIYI_RELAY_TOKEN';
  static const _responseModelsPrefsPrefix = 'dsh_response_models_v1_';
  static const _modelCatalogPrefsPrefix = 'dsh_model_catalog_v1_';
  static const _injectedPrefsKey = 'dsh_injected_configs_v1';
  static const _scopedInjectedPrefsPrefix = 'dsh_injected_configs_v2_';
  static const _injectedIdsPrefsKey = 'dsh_injected_provider_ids_v1';

  static const searchConfigFile = 'shiyi-free-search.json';
  static const searchNs = 'shiyi-free-search';
  static const legacySearchNs = 'web-search-deepseek';
  static const _defaultModelPatchStart = '# ShiYi agent default model: begin';
  static const _defaultModelPatchEnd = '# ShiYi agent default model: end';

  /// 拾忆 API 统一走手机侧「临时中转」租约：局域网目标经手机局域网地址、
  /// 本机目标经 127.0.0.1（与 relay 同设备），随用随删。公网拨不进手机，
  /// 走直接注入（injectShiyiDirectNow）。旧的「批量注入到本机
  /// settings.yaml」链路已随 API 来源开关一并移除（#307）。
  static bool canUseShiyiRelay(AppSettings s) =>
      DshEndpoint.modeOf(s) != 'remote';

  /// 把当前拾忆设置映射为 Relay 路由身份。身份只参与手机内存路由和
  /// 远端 provider 名称，不包含 API 地址或密钥。
  static ApiProfile relayProfileForSettings(AppSettings s) => ApiProfile(
    id: s.apiProfileId.trim(),
    name: s.apiProfileId.trim().isEmpty ? displayName : s.apiProfileId.trim(),
    baseUrl: s.baseUrl,
    apiKey: s.apiKey,
    model: s.model,
    apiProtocol: s.apiProtocol,
  );

  static String relayProviderForSettings(
    AppSettings s, {
    String relayInstanceId = '',
  }) => relayProviderForProfile(
    relayProfileForSettings(s),
    relayInstanceId: relayInstanceId,
  );

  static String relayRouteIdForSettings(AppSettings s) =>
      ShiyiApiRelay.routeIdForProfile(relayProfileForSettings(s));

  // All read/modify/write operations on DSH files share this queue.  Settings
  // changes can originate from several unawaited UI callbacks while DSH is
  // starting, so a per-call lock would still allow stale snapshots to race.
  static Future<void> _fileSyncTail = Future<void>.value();

  static Future<T> _withFileSyncLock<T>(Future<T> Function() action) {
    final result = _fileSyncTail.then<T>((_) => action());
    _fileSyncTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  @visibleForTesting
  static Future<void> waitForFileSyncs() => _fileSyncTail;

  static Future<void> _writeAtomically(File target, String contents) async {
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(contents, flush: true);
    // Do not delete the target first: rename keeps either the old complete
    // document or the new complete document visible to the DSH parser.
    await tmp.rename(target.path);
  }

  /// 拾忆协议 -> DSH 手写路由协议。
  static String dshApiFor(String protocol) => protocol == 'anthropic'
      ? 'anthropic-messages'
      : protocol == 'responses'
      ? 'openai-responses'
      : 'openai-completions';

  /// pi-ai 按 URL 识别 OpenRouter；手写 `shiyi_*` 路由也必须走同一套判断。
  static bool isOpenRouterBase(String baseUrl) =>
      baseUrl.toLowerCase().contains('openrouter.ai');

  /// OpenRouter 不是 OpenAI：`store` 会被原样转发并 400。
  /// pi-ai 只把 deepseek/moonshot 等标成非标准网关，openrouter.ai 仍
  /// `supportsStore: true`。手写注入必须显式关掉。
  /// Anthropic 协议没有 `supportsStore`，写进去会被 llm-pi-ai 直接拒配置。
  static Map<String, dynamic>? completionsCompatFor(
    String baseUrl, {
    String protocol = 'openai',
  }) {
    if (dshApiFor(protocol) != 'openai-completions') return null;
    if (!isOpenRouterBase(baseUrl)) return null;
    return const {'supportsStore': false};
  }

  /// OpenRouter 在 `model.reasoning=true` 且思考关闭时仍发送
  /// `reasoning: {effort: none}`，非思考模型会 HTTP 400。只给真正的思考
  /// 模型声明档位；其它网关保持原样（会话页通用按钮仍可显示）。
  static bool declareReasoningCapability(String model, String baseUrl) {
    if (defaultReasoningEffort(model) != null) return true;
    if (isOpenRouterBase(baseUrl)) return false;
    return reasoningEffortsForModel(model) != null;
  }

  /// DSH 的 pi-ai provider 需要显式的 reasoning 档位才会向部分网关请求
  /// `reasoning_content`。只给明显支持思考输出的模型加默认档位，普通模型
  /// 不注入该字段，避免把不支持 reasoning 的模型误切到 thinking 请求。
  static String? defaultReasoningEffort(String model) =>
      ReasoningModels.defaultEffort(model);

  static Map<String, String?>? reasoningEffortsForModel(String model) =>
      ReasoningModels.effortsFor(model);

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

  /// 每份手机 API 配置使用独立的远端 relay provider，避免不同 DSH 会话
  /// 切换配置时共用 `shiyi_relay` 而互相覆盖。
  static String relayProviderForProfile(
    ApiProfile profile, {
    String relayInstanceId = '',
  }) {
    final encoded = base64Url
        .encode(utf8.encode(profile.profileId))
        .replaceAll('=', '')
        .toLowerCase();
    final profilePart = encoded.substring(0, encoded.length.clamp(0, 16));
    final normalizedInstance = relayInstanceId.trim().toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]+'),
      '',
    );
    final instancePart = normalizedInstance.substring(
      0,
      normalizedInstance.length.clamp(0, 12),
    );
    final base = '${relayProvider}_$profilePart';
    return instancePart.isEmpty ? base : '${base}_$instancePart';
  }

  /// 会话级 provider 身份。每轮复用同一个名字，避免影响模型端缓存前缀；
  /// 不同 DSH 会话使用不同 provider，清理时不会互相误删。
  static String relayProviderForSession(
    ApiProfile profile, {
    required String sessionId,
    String relayInstanceId = '',
  }) {
    final base = relayProviderForProfile(
      profile,
      relayInstanceId: relayInstanceId,
    );
    final sessionPart = relayInstanceIdForToken(sessionId.trim());
    return '${base}_s$sessionPart';
  }

  /// 从随机 Relay token 派生不可逆的短实例标识，只用于避免多台手机在
  /// 同一 DSH 上写入同名 provider。真实 token 不进入 provider 或日志。
  static String relayInstanceIdForToken(String token) {
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(token.trim())) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  static String relayCredentialEnvForProvider(String provider) {
    final id = provider.trim();
    if (id.isEmpty || id == relayProvider) return relayCredentialEnv;
    return '${relayCredentialEnv}_${relayInstanceIdForToken(id).toUpperCase()}';
  }

  static bool isRelayProvider(String provider) {
    final id = provider.trim();
    return id == relayProvider || id.startsWith('${relayProvider}_');
  }

  /// 返回临时 Relay 结束后应恢复的目标 DSH 模型。
  /// 当前选择若已是旧 Relay 残留，则优先回到官方默认组，再回退首个可用组。
  static DshModelSelection? restorableSelection(
    DshModelSelection current,
    List<DshModelGroup> groups,
  ) {
    DshModelSelection? fromGroup(DshModelGroup group) {
      if (isRelayProvider(group.id) || group.models.isEmpty) return null;
      final currentModel = current.model.trim();
      final model = group.models
          .where((item) => item.id.trim() == currentModel)
          .firstOrNull;
      final chosen = model ?? group.models.first;
      return DshModelSelection(
        provider: group.id.trim(),
        model: chosen.id.trim(),
        reasoningEffort: group.id.trim() == current.provider.trim()
            ? current.reasoningEffort
            : null,
      );
    }

    final provider = current.provider.trim();
    final model = current.model.trim();
    if (provider.isNotEmpty && model.isNotEmpty && !isRelayProvider(provider)) {
      for (final group in groups) {
        if (group.id.trim() != provider) continue;
        final exists = group.models.any((item) => item.id.trim() == model);
        if (exists) return current;
      }
    }
    for (final group in groups) {
      if (group.id.trim() == officialProvider) {
        final selection = fromGroup(group);
        if (selection != null) return selection;
      }
    }
    for (final group in groups) {
      final selection = fromGroup(group);
      if (selection != null) return selection;
    }
    return null;
  }

  static bool isRelayProviderForInstance(
    String provider,
    String relayInstanceId,
  ) {
    final id = provider.trim().toLowerCase();
    final instance = relayInstanceId.trim().toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]+'),
      '',
    );
    if (!isRelayProvider(id) || instance.isEmpty) return false;
    final part = instance.substring(0, instance.length.clamp(0, 12));
    return id.endsWith('_$part') || id.contains('_${part}_s');
  }

  static bool isManagedProviderId(String id) {
    final value = id.trim();
    return value == providerId || value.startsWith('${providerId}_');
  }

  static String _scopedKey(String scopeKey) {
    final encoded = base64Url
        .encode(utf8.encode(scopeKey.trim()))
        .replaceAll('=', '');
    return '$_scopedInjectedPrefsPrefix$encoded';
  }

  static String _injectedConfigsKey(String? scopeKey) {
    final normalized = scopeKey?.trim() ?? '';
    return normalized.isEmpty ? _injectedPrefsKey : _scopedKey(normalized);
  }

  static bool _isLocalScope(String? scopeKey) {
    final normalized = scopeKey?.trim() ?? '';
    return normalized.isEmpty || normalized.startsWith('local\u0000');
  }

  static Future<List<DshInjectedConfig>> listInjectedConfigs({
    String? scopeKey,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (scopeKey == null || scopeKey.trim().isEmpty) {
      await _migrateLegacyInjectedIds(prefs);
    } else {
      // 旧版只有一份全局注入记录，按兼容约定归入本机；局域网和公网
      // 从此只读自己的桶，不会把本机配置显示成远端已注入。
      final key = _injectedConfigsKey(scopeKey);
      final localScope = DshEndpoint.scopeKeyOf(AppSettings());
      if (scopeKey == localScope &&
          !prefs.containsKey(key) &&
          prefs.containsKey(_injectedPrefsKey)) {
        final legacy = prefs.getString(_injectedPrefsKey);
        if (legacy != null) await prefs.setString(key, legacy);
      }
    }
    final raw = prefs.getString(_injectedConfigsKey(scopeKey));
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
    List<DshInjectedConfig> items, {
    String? scopeKey,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _injectedConfigsKey(scopeKey),
      jsonEncode([for (final item in items) item.toJson()]),
    );
    if (scopeKey == null || scopeKey.trim().isEmpty) {
      await prefs.setStringList(_injectedIdsPrefsKey, [
        for (final item in items) item.id,
      ]);
    }
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
    String? scopeKey,
  }) async {
    final incoming = _configFromSettings(s, name: name);
    final current = await listInjectedConfigs(scopeKey: scopeKey);
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
    await _saveInjectedConfigs(next, scopeKey: scopeKey);
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

  /// llm-pi-ai 模型条目。`input` 声明模型能力。注入拾忆 provider 时统一声明
  /// `[text, image]`，这样 DSH 的 `read_image` 工具不会因 provider 条目缺少
  /// image 能力而在调用前被拒绝；是否配置独立视觉模型仍由视觉设置控制。
  static Map<String, dynamic> _modelEntry(String id, {String baseUrl = ''}) {
    final reasoningEfforts = declareReasoningCapability(id, baseUrl)
        ? reasoningEffortsForModel(id)
        : null;
    return {
      'id': id,
      'name': id,
      'input': ['text', 'image'],
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
    final baseUrl = s.baseUrl.trim();
    final seen = <String>{primary};
    final models = <Map<String, dynamic>>[
      _modelEntry(primary, baseUrl: baseUrl),
    ];
    if (s.visionEnabled && vision.isNotEmpty && seen.add(vision)) {
      models.add(_modelEntry(vision, baseUrl: baseUrl));
    }
    final aliases = _normalizedResponseModels([
      ..._compatibilityResponseModels(primary),
      ...responseModels,
      ...catalogModels,
    ]).toList()..sort();
    for (final alias in aliases) {
      if (seen.add(alias)) models.add(_modelEntry(alias, baseUrl: baseUrl));
    }
    final reasoning = defaultReasoningEffort(primary);
    final compat = completionsCompatFor(baseUrl, protocol: s.apiProtocol);
    final id = (provider ?? providerId).trim();
    final label = (name ?? '').trim();
    return {
      'displayName': label.isEmpty ? displayName : label,
      'apiKeyEnv': (apiKeyEnv ?? credentialEnvFor(id)).trim(),
      'api': dshApiFor(s.apiProtocol),
      'baseURL': baseUrl,
      'models': models,
      ...?(compat == null ? null : {'compat': compat}),
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
    final id = s.apiProfileId.trim();
    final fingerprint = id.isEmpty
        ? jsonEncode([s.apiProtocol.trim(), s.baseUrl.trim(), s.model.trim()])
        : jsonEncode([
            id,
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
    final id = s.apiProfileId.trim();
    final fingerprint = id.isEmpty
        ? jsonEncode([s.apiProtocol.trim(), s.baseUrl.trim()])
        : jsonEncode([id, s.apiProtocol.trim(), s.baseUrl.trim()]);
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

  /// 保存一次获取到的全部模型名称，并立即刷新运行中的 DSH 提供商。
  static Future<bool> rememberModelCatalog(
    AppSettings s,
    Iterable<String> modelIds, {
    DshApiClient? api,
    String? scopeKey,
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
    return changed;
  }

  /// 从缓存目录移除一个模型。当前主模型和视觉模型由设置页拥有，不允许删除。
  static Future<bool> removeCachedModel(
    AppSettings s,
    String model, {
    DshApiClient? api,
    String? scopeKey,
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
    return true;
  }

  /// 从已注入列表和 DSH 设置里删除一份 API 配置，不影响其它已注入项。
  static Future<bool> removeInjectedConfig(
    String provider, {
    DshApiClient? api,
    Future<bool> Function()? isRunning,
    Future<String> Function()? homeDir,
    String? scopeKey,
  }) async {
    final id = provider.trim();
    if (id.isEmpty || !isManagedProviderId(id)) return false;
    final current = await listInjectedConfigs(scopeKey: scopeKey);
    DshInjectedConfig? removed;
    final next = <DshInjectedConfig>[];
    for (final item in current) {
      if (item.id == id) {
        removed = item;
      } else {
        next.add(item);
      }
    }
    await _saveInjectedConfigs(next, scopeKey: scopeKey);

    if (!_isLocalScope(scopeKey)) return false;
    final client = api ?? DshService.instance.api;
    final running = await (isRunning ?? client.rpcPing)();
    if (running) {
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
    if (_isLocalScope(scopeKey)) {
      try {
        await _withFileSyncLock<void>(() async {
          final home = await (homeDir ?? DshService.instance.homeDir)();
          await Directory(home).create(recursive: true);
          final file = File('$home/settings.yaml');
          if (await file.exists()) {
            final yaml = removeProviderYaml(await file.readAsString(), id);
            await _writeAtomically(file, yaml);
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
              await _writeAtomically(cred, text);
            }
          }
        });
      } catch (e) {
        debugPrint('DshModelSync remove files failed: $e');
      }
    }
    return true;
  }

  /// 记住历史里新发现的 responseModel，并立即刷新运行中 DSH 的 provider。
  static Future<bool> rememberResponseModels(
    AppSettings s,
    Iterable<String> responseModels, {
    DshApiClient? api,
    String? scopeKey,
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
      before.visionEnabled != after.visionEnabled ||
      before.visionBaseUrl != after.visionBaseUrl ||
      before.visionApiKey != after.visionApiKey ||
      before.visionModel != after.visionModel ||
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

  static Future<void> injectRelayNow(
    AppSettings s, {
    required DshApiClient api,
    required String relayBaseUrl,
    required String relayToken,
    String provider = relayProvider,
    String? sessionId,
    String? name,
    Future<bool> Function()? isRunning,
    String? scopeKey,
    bool setDefault = true,
    bool selectSessions = true,
  }) async {
    if (!canUseShiyiRelay(s)) {
      throw StateError('公网 DSH 拨不进手机，拾忆 API 走直接注入而非中转');
    }
    if (relayBaseUrl.trim().isEmpty || relayToken.trim().isEmpty) {
      throw ArgumentError('拾忆 API 中转配置不完整');
    }
    final running = await (isRunning ?? api.rpcPing)();
    if (!running) throw StateError('当前 DSH 未连接');
    final relaySettings = s.copyWith(baseUrl: relayBaseUrl.trim());
    unawaited(
      RuntimeLogger.instance.info(
        'Relay',
        'provider.inject.started',
        data: {
          'provider': provider,
          'model': s.model,
          'protocol': s.apiProtocol,
          'scopeKey': scopeKey ?? '',
          'relayUrl': _safeBaseUrl(relayBaseUrl),
        },
      ),
    );
    final credential = relayCredentialEnvForProvider(provider);
    await api.setCredential(credential, relayToken.trim());
    unawaited(
      RuntimeLogger.instance.info(
        'Relay',
        'credential.synced',
        data: {
          'provider': provider,
          'credential': credential,
          'scopeKey': scopeKey ?? '',
        },
      ),
    );
    await api.mutateSettings(
      settingsNs,
      mutateOps(
        relaySettings,
        responseModels: await responseModelsFor(s),
        catalogModels: await cachedModelCatalogFor(s),
        provider: provider,
        name: name ?? '拾忆 API 安全中转',
        apiKeyEnv: credential,
      ),
    );
    // DSH 的 provider 目录是最终验收点。某些远端部署会返回 settings.mutate
    // 成功但异步加载配置，切换请求紧接着到达时会暂时看不到 provider；等待
    // 一次目录确认，避免把“尚未加载”伪装成模型切换失败。
    await _waitForProvider(api, provider);
    try {
      if (setDefault && (sessionId == null || sessionId.trim().isEmpty)) {
        await api.mutateSettings(
          defaultModelNs,
          defaultModelOps(s, provider: provider),
        );
      }
    } catch (_) {}
    if (!selectSessions) return;
    final sessions = sessionId != null && sessionId.trim().isNotEmpty
        ? [sessionId.trim()]
        : [for (final session in await api.listSessions()) session.sessionId];
    for (final id in sessions) {
      try {
        await api.selectModel(id, provider, s.model.trim());
      } catch (_) {}
    }
    unawaited(
      RuntimeLogger.instance.info(
        'Relay',
        'provider.injected',
        data: {
          'provider': provider,
          'scopeKey': scopeKey ?? '',
          'relayUrl': _safeBaseUrl(relayBaseUrl),
          'apiKeyForwarded': false,
        },
      ),
    );
  }

  /// 公网 DSH 直接注入拾忆 API：真实 baseUrl + API Key 写进目标主机
  /// （credentials.set + settings.mutate），持久生效，目标主机的模型数据页
  /// 可查看、可手动删除。与手机中转不同，这里目标主机能拿到真实密钥——
  /// 仅在 Relay 地址不可达（公网）时按用户要求使用，调用方保证 mode。
  static Future<void> injectShiyiDirectNow(
    AppSettings s, {
    required DshApiClient api,
    required String provider,
    String? name,
    String? sessionId,
    Future<bool> Function()? isRunning,
  }) async {
    if (s.apiKey.trim().isEmpty) {
      throw StateError('拾忆配置缺少 API Key，无法直接注入');
    }
    final running = await (isRunning ?? api.rpcPing)();
    if (!running) throw StateError('当前 DSH 未连接');
    final credential = relayCredentialEnvForProvider(provider);
    unawaited(
      RuntimeLogger.instance.info(
        'DSH',
        'shiyi_direct.started',
        data: {
          'provider': provider,
          'model': s.model,
          'protocol': s.apiProtocol,
          'baseUrl': _safeBaseUrl(s.baseUrl),
        },
      ),
    );
    await api.setCredential(credential, s.apiKey.trim());
    await api.mutateSettings(
      settingsNs,
      mutateOps(
        s,
        responseModels: await responseModelsFor(s),
        catalogModels: await cachedModelCatalogFor(s),
        provider: provider,
        name: name ?? '拾忆',
        apiKeyEnv: credential,
      ),
    );
    await _waitForProvider(api, provider);
    final session = sessionId?.trim() ?? '';
    if (session.isNotEmpty) {
      try {
        await api.selectModel(session, provider, s.model.trim());
      } catch (_) {}
    }
    unawaited(
      RuntimeLogger.instance.info(
        'DSH',
        'shiyi_direct.injected',
        data: {'provider': provider, 'apiKeyForwarded': true},
      ),
    );
  }

  /// 删除一个临时 Relay provider 和对应凭据。只接受拾忆 Relay 命名空间，
  /// 绝不触碰目标 DSH 自有 provider。
  static Future<void> removeRelayNow({    required DshApiClient api,
    required String provider,
    String? scopeKey,
  }) async {
    final id = provider.trim();
    if (!isRelayProvider(id)) {
      throw ArgumentError('拒绝删除非拾忆 Relay provider：$id');
    }
    final credential = relayCredentialEnvForProvider(id);
    Object? firstError;
    try {
      await api.mutateSettings(settingsNs, unsetProviderOps(id));
    } catch (error) {
      firstError = error;
    }
    try {
      await api.unsetCredential(credential);
    } catch (error) {
      firstError ??= error;
    }
    unawaited(
      RuntimeLogger.instance.info(
        'Relay',
        'provider.removed',
        result: firstError == null ? 'ok' : 'partial',
        data: {
          'provider': id,
          'credential': credential,
          'scopeKey': scopeKey ?? '',
          if (firstError != null) 'error': '$firstError',
        },
      ),
    );
    if (firstError != null) throw firstError;
  }

  /// App 重启后清理当前手机实例遗留的临时 provider。其它手机以及目标 DSH
  /// 自有配置都不在匹配范围内。
  static Future<void> cleanupRelayProvidersForInstance({
    required DshApiClient api,
    required String relayInstanceId,
    String? scopeKey,
  }) async {
    await cleanupStaleRelayDefault(api: api, scopeKey: scopeKey);
    final providers = await api.llmProviders();
    for (final item in providers) {
      final id = (item['provider'] ?? item['id'] ?? item['providerId'] ?? '')
          .toString()
          .trim();
      if (!isRelayProviderForInstance(id, relayInstanceId)) continue;
      try {
        await removeRelayNow(api: api, provider: id, scopeKey: scopeKey);
      } catch (_) {
        // Token 已随 App 进程消失，残留 provider 即使暂时删不掉也无法访问上游。
      }
    }
  }

  /// 旧版曾把临时 Relay 写成目标 DSH 的全局默认模型。provider 清掉后，
  /// `agent-default-model.user` 仍可能指向不存在的 relay，导致公网实例后续
  /// 新会话无法选择模型。仅当用户层 provider 明确属于拾忆 Relay 时移除
  /// 覆盖，让 DSH 自己的 base/default 重新生效。
  @visibleForTesting
  static Future<bool> cleanupStaleRelayDefault({
    required DshApiClient api,
    String? scopeKey,
  }) async {
    try {
      final described = await api.describeSettings();
      final namespace = described.namespaces
          .where((item) => item.ns == defaultModelNs)
          .firstOrNull;
      final provider = (namespace?.user['provider'] ?? '').toString().trim();
      if (!isRelayProvider(provider)) return false;
      await api.mutateSettings(defaultModelNs, const [
        {
          'op': 'unset',
          'path': ['provider'],
        },
        {
          'op': 'unset',
          'path': ['model'],
        },
        {
          'op': 'unset',
          'path': ['reasoningEffort'],
        },
      ]);
      unawaited(
        RuntimeLogger.instance.info(
          'Relay',
          'legacy_default.cleaned',
          data: {'provider': provider, 'scopeKey': scopeKey ?? ''},
        ),
      );
      return true;
    } catch (error) {
      unawaited(
        RuntimeLogger.instance.warn(
          'Relay',
          'legacy_default.cleanup_skipped',
          result: 'skipped',
          data: {'scopeKey': scopeKey ?? '', 'error': '$error'},
        ),
      );
      return false;
    }
  }

  static Future<void> _waitForProvider(
    DshApiClient api,
    String provider,
  ) async {
    final id = provider.trim();
    if (id.isEmpty) throw ArgumentError('Relay provider 为空');
    Object? lastError;
    for (var attempt = 0; attempt < 8; attempt++) {
      try {
        final providers = await api.llmProviders();
        final found = providers.any((item) {
          final actual =
              (item['provider'] ?? item['id'] ?? item['providerId'] ?? '')
                  .toString()
                  .trim();
          return actual == id;
        });
        if (found) return;
        lastError = DshApiException(
          '远端 DSH provider 目录中未找到 $id',
          code: 'relay-provider-not-loaded',
        );
      } catch (e) {
        if (e is DshApiException && e.code == 'unsupported') return;
        lastError = e;
      }
      if (attempt < 7) {
        await Future<void>.delayed(Duration(milliseconds: 120 * (attempt + 1)));
      }
    }
    throw DshApiException(
      '远端 DSH 未确认中转 provider 已加载：$id',
      code: lastError is DshApiException
          ? lastError.code
          : 'relay-provider-not-loaded',
    );
  }

  static String _safeBaseUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null) return '<endpoint>';
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port${uri.path}';
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
    await _withFileSyncLock<void>(() async {
      final target = File('$home/settings.yaml');
      if (!await target.exists()) return;
      final existing = await target.readAsString();
      final next = removeLegacySearchSections(existing);
      if (next == existing) return;
      await _writeAtomically(target, next);
    });
  }

  /// DSH 只认 owner-only（0600）的 `.credentials.yaml`，group/other 可读会拒读。
  @visibleForTesting
  static Future<void> writeCredentialsFile(
    String home,
    String key, {
    String searchKey = '',
    String apiKeyEnv = credentialEnv,
  }) => _withFileSyncLock(
    () => _writeCredentialsFile(
      home,
      key,
      searchKey: searchKey,
      apiKeyEnv: apiKeyEnv,
    ),
  );

  static Future<void> _writeCredentialsFile(
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
    final compat = completionsCompatFor(baseUrl, protocol: apiProtocol);
    if (compat != null) {
      lines.add('${child}compat:');
      for (final e in compat.entries) {
        lines.add('$item${e.key}: ${e.value}');
      }
    }
    final reasoning = defaultReasoningEffort(model);
    if (reasoning != null) lines.add('${child}reasoning: $reasoning');
    lines.addAll([
      '${child}models:',
      '$item- id: ${yamlScalar(model)}',
      '$item  name: ${yamlScalar(model)}',
      '$item  input: [text, image]',
    ]);
    if (mainReasoningEfforts != null &&
        declareReasoningCapability(model, baseUrl)) {
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
      if (declareReasoningCapability(visionModel, baseUrl)) {
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
        '$item  input: [text, image]',
      ]);
      if (declareReasoningCapability(alias, baseUrl)) {
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


  /// DSH 0.1.1 `credentialRef`：POSIX 标识符。顶层只认 version / refs / records。
  static final _credentialRefRe = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

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

  /// 写出 DSH 0.1.1-rc.2 认的 version-1 文档。
  ///
  /// 旧扁平 `SHIYI_API_KEY:` 顶层映射、以及 DSH 迁完 version 后又被
  /// 旧写入器追加到顶层的密钥，都会收进 `refs:`。`records` 原样保留。
  static String upsertCredentialsYaml(
    String existing,
    String key,
    String value,
  ) {
    final doc = _parseCredentialsDocument(existing);
    if (value.trim().isEmpty) {
      doc.refs.remove(key);
    } else {
      doc.refs[key] = value;
    }
    return _renderCredentialsDocument(doc);
  }

  static _CredentialsDocument _parseCredentialsDocument(String existing) {
    if (existing.trim().isEmpty) {
      return _CredentialsDocument();
    }
    try {
      final yaml = loadYaml(existing);
      if (yaml is YamlMap) return _credentialsFromYaml(yaml, existing);
    } catch (_) {}
    final sanitized = _joinLines(
      _sanitizeCredentialLines(_splitLines(existing)),
    );
    if (sanitized.trim().isEmpty) return _CredentialsDocument();
    try {
      final yaml = loadYaml(sanitized);
      if (yaml is YamlMap) return _credentialsFromYaml(yaml, sanitized);
    } catch (_) {}
    return _credentialsFromLines(sanitized);
  }

  static _CredentialsDocument _credentialsFromYaml(YamlMap yaml, String text) {
    final refs = <String, String>{};
    void collect(YamlMap map) {
      for (final e in map.entries) {
        final k = e.key.toString();
        if (k == 'version' || k == 'refs' || k == 'records') continue;
        if (!_credentialRefRe.hasMatch(k)) continue;
        final v = e.value;
        if (v is String && v.isNotEmpty) refs[k] = v;
      }
    }

    final nested = yaml['refs'];
    if (nested is YamlMap) collect(nested);
    collect(yaml);
    String? recordsBlock;
    if (yaml['records'] is YamlMap) {
      recordsBlock = _extractTopLevelBlock(text, 'records');
    }
    return _CredentialsDocument(refs: refs, recordsBlock: recordsBlock);
  }

  static _CredentialsDocument _credentialsFromLines(String text) {
    final refs = <String, String>{};
    final lines = _splitLines(text);
    final versioned = lines.any((line) {
      final t = line.trim();
      return t == 'version: 1' || t.startsWith('version:');
    });
    for (final line in lines) {
      final t = line.trimLeft();
      if (t.isEmpty || t.startsWith('#')) continue;
      final indent = line.length - t.length;
      final colon = t.indexOf(':');
      if (colon <= 0) continue;
      final k = t.substring(0, colon).trim();
      if (k == 'version' || k == 'refs' || k == 'records') continue;
      if (!_credentialRefRe.hasMatch(k)) continue;
      if (versioned) {
        if (indent != 0 && indent != 2) continue;
      } else if (indent != 0) {
        continue;
      }
      final v = t.substring(colon + 1).trim();
      if (v.isEmpty) continue;
      refs[k] = v;
    }
    return _CredentialsDocument(refs: refs);
  }

  static String? _extractTopLevelBlock(String text, String key) {
    final lines = _splitLines(text);
    final start = _findKey(lines, 0, lines.length, 0, key);
    if (start == null) return null;
    final end = _blockEnd(lines, start, 0);
    final block = _joinLines(lines.sublist(start, end));
    return block.trim().isEmpty ? null : block.trimRight();
  }

  static String _renderCredentialsDocument(_CredentialsDocument doc) {
    final hasRefs = doc.refs.isNotEmpty;
    final records = doc.recordsBlock?.trimRight();
    final hasRecords = records != null && records.isNotEmpty;
    if (!hasRefs && !hasRecords) return '';
    final buf = StringBuffer('version: 1\n');
    if (hasRefs) {
      buf.writeln('refs:');
      for (final e in doc.refs.entries) {
        buf.writeln('  ${e.key}: ${yamlScalar(e.value)}');
      }
    }
    if (hasRecords) {
      buf.write(records);
      if (!records.endsWith('\n')) buf.write('\n');
    }
    return buf.toString();
  }
}

class _CredentialsDocument {
  _CredentialsDocument({Map<String, String>? refs, this.recordsBlock})
    : refs = refs ?? <String, String>{};

  final Map<String, String> refs;
  final String? recordsBlock;
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
