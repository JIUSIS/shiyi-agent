import '../core/models.dart';

/// DSH 连接地址：本机 / 局域网 / 公网。
///
/// 只做 URL 规范化，不启停进程。远程模式由 [DshService.applyConnection]
/// 关掉本机进程管理。
class DshEndpoint {
  static const localUrl = 'http://127.0.0.1:3080';
  static const defaultPort = 3080;

  static String modeOf(AppSettings s) {
    switch (s.dshConnectionMode.trim().toLowerCase()) {
      case 'lan':
        return 'lan';
      case 'remote':
        return 'remote';
      default:
        return 'local';
    }
  }

  static bool isLocal(AppSettings s) => modeOf(s) == 'local';

  /// DSH 实例隔离键：模式本身也参与键值，避免本机和局域网恰好使用
  /// 相同地址时共用探测、Host 覆盖和 RPC 合并状态。
  static String scopeKeyOf(AppSettings s) {
    final mode = modeOf(s);
    return '$mode\u0000${stripSlash(urlOf(s))}';
  }

  static String urlOf(AppSettings s) {
    switch (modeOf(s)) {
      case 'lan':
        return lanUrl(s.dshLanHost, s.dshLanPort);
      case 'remote':
        return remoteUrl(s.dshRemoteUrl);
      default:
        return localUrl;
    }
  }

  static String lanUrl(String host, int port) {
    final raw = host.trim();
    if (raw.isEmpty) return '';
    Uri? uri;
    if (raw.contains('://')) {
      uri = Uri.tryParse(raw);
    } else if (raw.contains('/')) {
      uri = Uri.tryParse('http://$raw');
    }
    if (uri != null && uri.host.isNotEmpty) {
      final scheme = uri.scheme == 'https' ? 'https' : 'http';
      final p = uri.hasPort ? uri.port : validPort(port);
      final path = stripSlash(uri.path);
      final base = '$scheme://${uri.host}:$p';
      return path.isEmpty ? base : '$base$path';
    }
    var h = raw;
    var p = validPort(port);
    if (h.startsWith('[') && h.contains(']:')) {
      final end = h.indexOf(']:');
      final maybe = int.tryParse(h.substring(end + 2));
      if (maybe != null) {
        h = h.substring(0, end + 1);
        p = validPort(maybe);
      }
    } else {
      final colon = h.lastIndexOf(':');
      if (colon > 0 && !h.contains('/')) {
        final maybe = int.tryParse(h.substring(colon + 1));
        if (maybe != null) {
          h = h.substring(0, colon);
          p = validPort(maybe);
        }
      }
    }
    return 'http://$h:$p';
  }

  static String remoteUrl(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return '';
    if (!s.contains('://')) {
      s = '${_isIpLiteral(s) ? 'http' : 'https'}://$s';
    }
    final uri = Uri.tryParse(s);
    if (uri == null || uri.host.isEmpty) return '';
    return stripSlash(uri.toString());
  }

  static bool isIpLiteralUrl(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return false;
    if (!value.contains('://')) value = 'http://$value';
    final host = Uri.tryParse(value)?.host;
    return host != null && _isIpHost(host);
  }

  /// 远程转发使用的自定义 Host。与局域网地址完全分离，显式配置优先。
  static List<String> remoteCustomCompatibilityHosts(AppSettings s) {
    if (modeOf(s) != 'remote') return const [];
    final remote = remoteUrl(s.dshRemoteUrl);
    if (remote.isEmpty) return const [];
    final ports = _remoteCompatibilityPorts(remote);
    final out = <String>[];
    void add(String value) {
      final normalized = value.trim();
      if (normalized.isNotEmpty && !out.contains(normalized)) {
        out.add(normalized);
      }
    }

    for (final raw in s.dshRemoteHost.split(RegExp(r'[\s,;]+'))) {
      final value = raw.trim();
      if (value.isEmpty) continue;
      var parsed = value.contains('://')
          ? Uri.tryParse(value)
          : Uri.tryParse('http://$value');
      if (parsed == null || parsed.host.isEmpty) continue;
      final host = parsed.host;
      if (parsed.hasPort) add(_hostAuthority(host, parsed.port));
      for (final port in ports) {
        add(_hostAuthority(host, port));
      }
    }
    return out;
  }

  /// 仅远程模式启用的常用本地服务器 Host/端口预设。
  static List<String> remotePresetCompatibilityHosts(AppSettings s) {
    if (modeOf(s) != 'remote') return const [];
    final remote = remoteUrl(s.dshRemoteUrl);
    if (remote.isEmpty) return const [];
    final out = <String>[];
    for (final host in const ['127.0.0.1', 'localhost', '0.0.0.0']) {
      for (final port in _remoteCompatibilityPorts(remote)) {
        final authority = _hostAuthority(host, port);
        if (!out.contains(authority)) out.add(authority);
      }
    }
    return out;
  }

  static List<String> remoteCompatibilityHosts(AppSettings s) {
    final out = <String>[];
    for (final host in [
      ...remoteCustomCompatibilityHosts(s),
      ...remotePresetCompatibilityHosts(s),
    ]) {
      if (!out.contains(host)) out.add(host);
    }
    return out;
  }

  static List<int> _remoteCompatibilityPorts(String remote) {
    final remoteUri = Uri.tryParse(remote);
    final out = <int>[];
    void add(int port) {
      final normalized = validPort(port);
      if (!out.contains(normalized)) out.add(normalized);
    }

    if (remoteUri != null && remoteUri.hasPort) add(remoteUri.port);
    for (final port in const [43120, 3080, 3000, 8080, 8000, 8888]) {
      add(port);
    }
    return out;
  }

  static String _hostAuthority(String host, int port) {
    final normalized = host.trim();
    if (normalized.contains(':') && !normalized.startsWith('[')) {
      return '[$normalized]:$port';
    }
    return '$normalized:$port';
  }

  static bool _isIpLiteral(String address) {
    final uri = Uri.tryParse('http://$address');
    final host = uri?.host;
    return host != null && _isIpHost(host);
  }

  static bool _isIpHost(String host) {
    if (host.isEmpty) return false;
    if (host.contains(':')) return true;
    final parts = host.split('.');
    return parts.length == 4 &&
        parts.every((part) {
          final value = int.tryParse(part);
          return value != null && value >= 0 && value <= 255;
        });
  }

  static int validPort(int port) =>
      port > 0 && port <= 65535 ? port : defaultPort;

  static String stripSlash(String url) {
    var s = url.trim();
    while (s.endsWith('/') && s != 'http://' && s != 'https://') {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  static String displayHost(String url) {
    final raw = stripSlash(url);
    if (raw.isEmpty) return '';
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.host.isEmpty) return raw;
    final port = uri.hasPort ? ':${uri.port}' : '';
    final path = stripSlash(uri.path);
    final host = '${uri.host}$port';
    return path.isEmpty ? host : '$host$path';
  }

  static String shortLabel(AppSettings s) {
    switch (modeOf(s)) {
      case 'lan':
        final host = displayHost(urlOf(s));
        return host.isEmpty ? 'DeepSeek Harness · 局域网' : '局域网 $host';
      case 'remote':
        final host = displayHost(urlOf(s));
        return host.isEmpty ? 'DeepSeek Harness · 公网' : '公网 $host';
      default:
        return 'DeepSeek Harness · 本机';
    }
  }
}
