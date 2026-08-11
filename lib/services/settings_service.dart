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
  static const _profileKeyPrefix = 'shiyi_profile_api_key_';

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
      // 迁移旧默认：此前按“字符”计、默认 100 万；现按 token 计，默认 128k。
      if (s.contextLimit >= 500000) s.contextLimit = 128000;
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
      return s;
    } catch (_) {
      return AppSettings();
    }
  }

  Future<void> save(AppSettings s) async {
    final json = s.toJson()
      ..remove('apiKey')
      ..remove('visionApiKey');
    await _writeKey(_mainApiKeyKey, s.apiKey);
    await _writeKey(_visionApiKeyKey, s.visionApiKey);
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
      for (final e in list) {
        final j = (e as Map<String, dynamic>);
        final baseUrl = (j['baseUrl'] ?? '').toString();
        final legacy = (j['apiKey'] ?? '').toString();
        if (legacy.isNotEmpty) {
          await _writeKey(_profileKey(baseUrl), legacy);
          j.remove('apiKey');
          dirty = true;
        }
        final p = ApiProfile.fromJson(j);
        out.add(
          ApiProfile(
            name: p.name,
            baseUrl: p.baseUrl,
            apiKey: await _readKey(_profileKey(baseUrl)),
            model: p.model,
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
      await _writeKey(_profileKey(p.baseUrl), p.apiKey);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _profilesKey,
      jsonEncode([for (final p in profiles) p.toJson()..remove('apiKey')]),
    );
  }

  static String _profileKey(String baseUrl) =>
      '$_profileKeyPrefix${baseUrl.trim().replaceAll(RegExp(r'/+$'), '')}';

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
}
