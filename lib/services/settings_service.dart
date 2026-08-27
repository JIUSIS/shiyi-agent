import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/model_presets.dart';
import '../core/models.dart';

class SettingsService {
  static const _key = 'shiyi_settings_v1';

  static const FlutterSecureStorage _secure = FlutterSecureStorage();
  static const _mainApiKeyKey = 'shiyi_api_key';
  static const _visionApiKeyKey = 'shiyi_vision_api_key';
  static const _socks5PasswordKey = 'shiyi_socks5_password';
  static const _socks5ServerPasswordsKey = 'shiyi_socks5_server_passwords';
  static const _dshRemoteTokenKey = 'shiyi_dsh_remote_token';
  static const _dshLanTokenKey = 'shiyi_dsh_lan_token';
  static const _profileKeyPrefix = 'shiyi_profile_api_key_v2_';
  static const _legacyProfileKeyPrefix = 'shiyi_profile_api_key_';

  Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return AppSettings();
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      // 迁移旧明文密钥：写入 Keystore 加密存储后从 SharedPreferences 移除。
      var dirty = false;
      final legacyApi = (json['apiKey'] ?? '').toString();
      final legacyVision = (json['visionApiKey'] ?? '').toString();
      if (legacyApi.isNotEmpty) {
        await _secure.write(key: _mainApiKeyKey, value: legacyApi);
        json.remove('apiKey');
        dirty = true;
      }
      if (legacyVision.isNotEmpty) {
        await _secure.write(key: _visionApiKeyKey, value: legacyVision);
        json.remove('visionApiKey');
        dirty = true;
      }
      if (dirty) await prefs.setString(_key, jsonEncode(json));
      final s = AppSettings.fromJson(json);
      s.apiKey = await _readKey(_mainApiKeyKey);
      s.visionApiKey = await _readKey(_visionApiKeyKey);
      s.socks5Password = await _readKey(_socks5PasswordKey);
      s.dshRemoteToken = await _readKey(_dshRemoteTokenKey);
      s.dshLanToken = await _readKey(_dshLanTokenKey);
      s.socks5Servers = await _attachServerPasswords(s.socks5Servers);
      s.contextLimit = sanitizeLoadedContextLimit(s.contextLimit);
      // 旧版本没有输出上限字段：按已选预设带出建议值，
      // 避免思考型模型继续用偏小的 8192。
      if (!json.containsKey('maxOutputTokens')) {
        for (final p in modelPresets) {
          if (p.baseUrl == s.baseUrl.trim()) {
            s.maxOutputTokens = p.suggestedMaxTokens;
            break;
          }
        }
      }
      // 自定义 OpenAI 兼容接口缺 /v1 时自动补上，避免请求打到错误路径。
      final isPreset = modelPresets.any((p) => p.baseUrl == s.baseUrl.trim());
      if ((s.apiProtocol == 'openai' || s.apiProtocol == 'responses') &&
          !isPreset) {
        final normalized = normalizeOpenAiBaseUrl(s.baseUrl);
        if (normalized != s.baseUrl.trim()) {
          s.baseUrl = normalized;
          json['baseUrl'] = normalized;
          await prefs.setString(_key, jsonEncode(json));
        }
      }
      return s;
    } catch (_) {
      return AppSettings();
    }
  }

  Future<void> save(AppSettings s) async {
    final json = s.toJson()
      ..remove('apiKey')
      ..remove('visionApiKey')
      ..remove('socks5Password')
      ..remove('dshRemoteToken')
      ..remove('dshLanToken');
    await _writeKey(_mainApiKeyKey, s.apiKey);
    await _writeKey(_visionApiKeyKey, s.visionApiKey);
    await _writeKey(_socks5PasswordKey, s.socks5Password);
    await _writeKey(_dshRemoteTokenKey, s.dshRemoteToken);
    await _writeKey(_dshLanTokenKey, s.dshLanToken);
    await _writeServerPasswords(s.socks5Servers);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(json));
  }

  /// API 配置列表（各服务商的接口地址/密钥/模型）单独存储，
  /// 切换配置时自动带出以前保存的 API Key。
  static const _profilesKey = 'shiyi_api_profiles_v1';

  Future<List<ApiProfile>> loadProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_profilesKey);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      var dirty = false;
      final out = <ApiProfile>[];
      final legacyUrlsMigrated = <String>{};
      for (final e in list) {
        final j = (e as Map<String, dynamic>);
        final p = ApiProfile.fromJson(j);
        final isPreset = modelPresets.any((m) => m.name == p.name);
        final baseUrl =
            isPreset ||
                (p.apiProtocol != 'openai' && p.apiProtocol != 'responses')
            ? p.baseUrl
            : normalizeOpenAiBaseUrl(p.baseUrl);
        if (baseUrl != p.baseUrl) {
          j['baseUrl'] = baseUrl;
          dirty = true;
        }
        final profileId = p.id.trim().isNotEmpty
            ? p.id.trim()
            : createApiProfileId(p.name, baseUrl, p.apiProtocol);
        if (profileId != p.id.trim()) {
          j['id'] = profileId;
          dirty = true;
        }
        final legacy = (j['apiKey'] ?? '').toString();
        if (legacy.isNotEmpty) {
          await _writeKey(_profileKey(profileId), legacy);
          j.remove('apiKey');
          dirty = true;
        }
        var apiKey = await _readKey(_profileKey(profileId));
        if (apiKey.isEmpty && legacyUrlsMigrated.add(_normalizedUrl(baseUrl))) {
          final oldKey = await _readKey(_legacyProfileKey(baseUrl));
          if (oldKey.isNotEmpty) {
            apiKey = oldKey;
            await _writeKey(_profileKey(profileId), oldKey);
            await _secure.delete(key: _legacyProfileKey(baseUrl));
          }
        }
        out.add(
          ApiProfile(
            id: profileId,
            name: p.name,
            baseUrl: baseUrl,
            apiKey: apiKey,
            model: p.model,
            apiProtocol: p.apiProtocol,
          ),
        );
      }
      if (dirty) {
        await prefs.setString(
          _profilesKey,
          jsonEncode([for (final p in out) p.toJson()..remove('apiKey')]),
        );
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  Future<void> saveProfiles(List<ApiProfile> profiles) async {
    for (final p in profiles) {
      await _writeKey(_profileKey(p.profileId), p.apiKey);
      await _secure.delete(key: _legacyProfileKey(p.baseUrl));
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _profilesKey,
      jsonEncode([
        for (final p in profiles)
          p.copyWith(id: p.profileId).toJson()..remove('apiKey'),
      ]),
    );
  }

  static String _profileKey(String profileId) =>
      '$_profileKeyPrefix${profileId.trim()}';

  static String _legacyProfileKey(String baseUrl) =>
      '$_legacyProfileKeyPrefix${_normalizedUrl(baseUrl)}';

  static String _normalizedUrl(String url) =>
      url.trim().replaceAll(RegExp(r'/+$'), '');

  Future<void> _writeKey(String key, String value) async {
    if (value.isEmpty) {
      await _secure.delete(key: key);
    } else {
      await _secure.write(key: key, value: value);
    }
  }

  Future<String> _readKey(String key) async {
    try {
      return await _secure.read(key: key) ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<List<Socks5Server>> _attachServerPasswords(
    List<Socks5Server> servers,
  ) async {
    if (servers.isEmpty) return servers;
    Map<String, dynamic> map = const {};
    try {
      final raw = await _secure.read(key: _socks5ServerPasswordsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) map = Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
    if (map.isEmpty) return servers;
    return [
      for (final s in servers)
        s.copyWith(password: map[s.id]?.toString() ?? s.password),
    ];
  }

  Future<void> _writeServerPasswords(List<Socks5Server> servers) async {
    final map = <String, String>{
      for (final s in servers)
        if (s.password.isNotEmpty) s.id: s.password,
    };
    if (map.isEmpty) {
      await _secure.delete(key: _socks5ServerPasswordsKey);
    } else {
      await _secure.write(
        key: _socks5ServerPasswordsKey,
        value: jsonEncode(map),
      );
    }
  }
}
