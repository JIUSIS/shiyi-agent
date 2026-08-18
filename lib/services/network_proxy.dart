import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 检测到的代理信息。
class ProxyInfo {
  final String host;
  final int port;

  /// 来源：system（Windows 系统代理）/ probe（本地端口探测）。
  final String source;

  ProxyInfo({required this.host, required this.port, required this.source});

  String get url => 'http://$host:$port';
}

/// 自动代理检测：
/// 1. Windows 系统代理（注册表，经 `reg query` 读取，零依赖）；
/// 2. 常见本地代理端口探测（Clash/V2Ray 等，兜底）。
///
/// 结果短时缓存（30s），安装/更新前实时重新检测。
class NetworkProxyDetector {
  NetworkProxyDetector._();
  static final NetworkProxyDetector instance = NetworkProxyDetector._();

  /// 最近检测结果（null = 未检测到可用代理）。
  final ValueNotifier<ProxyInfo?> detected = ValueNotifier<ProxyInfo?>(null);

  /// 常见本地代理端口（Clash / V2RayN / Shadowsocks 等默认端口）。
  static const List<int> _probePorts = [
    7890, // Clash 默认
    7897, // Clash Verge
    10809, // V2RayN http
    10808, // V2RayN socks（http 代理一般走 10809）
    1080, // Shadowsocks
    8888, // 常见自定义
  ];

  ProxyInfo? _cached;
  DateTime? _cachedAt;
  static const Duration _cacheTtl = Duration(seconds: 30);

  /// 检测可用代理（系统代理优先，端口探测兜底），带短缓存。
  Future<ProxyInfo?> detect({bool force = false}) async {
    final now = DateTime.now();
    if (!force && _cached != null && _cachedAt != null) {
      if (now.difference(_cachedAt!) < _cacheTtl) return _cached;
    }
    ProxyInfo? found;
    try {
      found = await _detectSystemProxy();
    } catch (_) {}
    if (found == null) {
      try {
        found = await _probeLocalPorts();
      } catch (_) {}
    }
    _cached = found;
    _cachedAt = now;
    detected.value = found;
    return found;
  }

  /// 系统代理检测：
  /// - Windows：注册表 Internet Settings（reg query）
  /// - Android：原生 MethodChannel 读 ConnectivityManager.defaultProxy
  Future<ProxyInfo?> _detectSystemProxy() async {
    if (Platform.isAndroid) {
      return _detectAndroidSystemProxy();
    }
    if (!Platform.isWindows) return null;
    const key =
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
    try {
      final enable = await _regValue(key, 'ProxyEnable');
      if (enable == null || enable.trim() != '1') return null;
      final server = await _regValue(key, 'ProxyServer');
      if (server == null) return null;
      final info = parseProxyServer(server.trim());
      if (info == null) return null;
      // 验证代理端口可达（系统代理可能指向已关闭的软件）。
      if (await _portAlive(info.$1, info.$2)) {
        return ProxyInfo(
          host: info.$1,
          port: info.$2,
          source: 'system',
        );
      }
    } catch (_) {}
    return null;
  }

  /// Android 系统代理（WiFi/APN 设置），经原生 channel 读取。
  Future<ProxyInfo?> _detectAndroidSystemProxy() async {
    try {
      final result = await const MethodChannel('shiyi/system_proxy')
          .invokeMethod<Map<dynamic, dynamic>>('getProxy')
          .timeout(const Duration(seconds: 3));
      if (result == null) return null;
      final host = result['host']?.toString();
      final port = int.tryParse('${result['port']}');
      if (host == null || host.isEmpty || port == null || port <= 0) {
        return null;
      }
      if (await _portAlive(host, port)) {
        return ProxyInfo(host: host, port: port, source: 'system');
      }
    } catch (_) {}
    return null;
  }

  /// 读取注册表字符串值（reg query 输出解析，零依赖）。
  Future<String?> _regValue(String key, String name) async {
    final r = await Process.run('reg', [
      'query',
      key,
      '/v',
      name,
    ]).timeout(const Duration(seconds: 5));
    if (r.exitCode != 0) return null;
    final out = '${r.stdout} ${r.stderr}';
    // 输出形如：  ProxyServer    REG_SZ    127.0.0.1:7890
    final lines = out.split('\n');
    for (final line in lines) {
      if (line.contains(name)) {
        final m = RegExp(r'REG_\w+\s+(.+)$').firstMatch(line.trim());
        if (m != null) return m.group(1)?.trim();
      }
    }
    return null;
  }

  /// 解析 ProxyServer 值（支持 host:port、http=host:port;socks=... 等）。
  static (String, int)? parseProxyServer(String raw) {
    var s = raw;
    // 取 http 部分（如 "http=127.0.0.1:7890;socks=..."）。
    final httpM = RegExp(r'http=([^;]+)').firstMatch(s);
    if (httpM != null) s = httpM.group(1)!;
    final m = RegExp(r'^([\w.\-]+):(\d+)$').firstMatch(s.trim());
    if (m == null) return null;
    return (m.group(1)!, int.parse(m.group(2)!));
  }

  /// 常见本地代理端口探测。
  Future<ProxyInfo?> _probeLocalPorts() async {
    for (final port in _probePorts) {
      if (await _portAlive('127.0.0.1', port)) {
        return ProxyInfo(host: '127.0.0.1', port: port, source: 'probe');
      }
    }
    return null;
  }

  /// TCP 连通性探测（500ms 超时）。
  Future<bool> _portAlive(String host, int port) async {
    try {
      final socket = await Socket.connect(host, port,
              timeout: const Duration(milliseconds: 500))
          .timeout(const Duration(milliseconds: 800));
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }
}
