import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/models.dart';

class SettingsService {
  static const _key = 'shiyi_settings_v1';

  Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return AppSettings();
    try {
      final s = AppSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      // 迁移旧默认：此前按“字符”计、默认 100 万；现按 token 计，默认 128k。
      if (s.contextLimit >= 500000) s.contextLimit = 128000;
      return s;
    } catch (_) {
      return AppSettings();
    }
  }

  Future<void> save(AppSettings s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(s.toJson()));
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
      return list
          .map((e) => ApiProfile.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveProfiles(List<ApiProfile> profiles) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _profilesKey, jsonEncode([for (final p in profiles) p.toJson()]));
  }
}