import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:socks5_proxy/socks_client.dart';

import '../core/models.dart';

/// 自定义 SOCKS5 通道：给对话、拉模型、联网搜索走境外出口。
class Socks5Endpoint {
  final String host;
  final int port;
  final String? username;
  final String? password;

  const Socks5Endpoint({
    required this.host,
    required this.port,
    this.username,
    this.password,
  });

  static String modeOf(AppSettings s) {
    final m = s.socks5Mode.trim();
    if (m == 'auto' || m == 'custom') return m;
    if (s.socks5Enabled) return 'custom';
    return 'off';
  }

  static Socks5Endpoint? fromSettings(AppSettings s) {
    if (modeOf(s) != 'custom') return null;

    Socks5Server? active;
    final id = s.socks5ActiveId.trim();
    if (id.isNotEmpty) {
      for (final e in s.socks5Servers) {
        if (e.id == id) {
          active = e;
          break;
        }
      }
    }
    if (active != null && active.host.trim().isNotEmpty) {
      final user = active.user.trim();
      final pass = active.password;
      return Socks5Endpoint(
        host: active.host.trim(),
        port: active.port <= 0 ? 1080 : active.port,
        username: user.isEmpty ? null : user,
        password: user.isEmpty || pass.isEmpty ? null : pass,
      );
    }

    final host = s.socks5Host.trim();
    if (host.isEmpty) return null;
    final port = s.socks5Port <= 0 ? 1080 : s.socks5Port;
    final user = s.socks5User.trim();
    final pass = s.socks5Password;
    return Socks5Endpoint(
      host: host,
      port: port,
      username: user.isEmpty ? null : user,
      password: user.isEmpty || pass.isEmpty ? null : pass,
    );
  }

  /// 支持 `host:port`、`socks5://user:pass@host:port`、`socks5h://host`、
  /// Clash mixed 的 `http://host:port`。
  static Socks5Endpoint? parse(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    if (s.startsWith('https://')) return null;
    var rest = s;
    if (rest.startsWith('socks5h://')) {
      rest = rest.substring('socks5h://'.length);
    } else if (rest.startsWith('socks5://')) {
      rest = rest.substring('socks5://'.length);
    } else if (rest.startsWith('http://')) {
      rest = rest.substring('http://'.length);
    } else if (rest.contains('://')) {
      return null;
    }
    String? user;
    String? pass;
    final at = rest.lastIndexOf('@');
    if (at >= 0) {
      final auth = rest.substring(0, at);
      rest = rest.substring(at + 1);
      final colon = auth.indexOf(':');
      if (colon >= 0) {
        user = Uri.decodeComponent(auth.substring(0, colon));
        pass = Uri.decodeComponent(auth.substring(colon + 1));
      } else {
        user = Uri.decodeComponent(auth);
      }
    }
    if (rest.isEmpty) return null;
    String host;
    var port = 1080;
    var hadScheme = s.startsWith('socks5://') ||
        s.startsWith('socks5h://') ||
        s.startsWith('http://');
    if (rest.startsWith('[')) {
      final end = rest.indexOf(']');
      if (end < 0) return null;
      host = rest.substring(1, end);
      final after = rest.substring(end + 1);
      if (after.startsWith(':')) {
        port = int.tryParse(after.substring(1)) ?? 1080;
      } else if (!hadScheme) {
        return null;
      }
    } else {
      final colon = rest.lastIndexOf(':');
      if (colon >= 0 && !rest.substring(colon + 1).contains('/')) {
        host = rest.substring(0, colon);
        port = int.tryParse(rest.substring(colon + 1)) ?? 1080;
      } else if (hadScheme) {
        host = rest;
      } else {
        return null;
      }
    }
    host = host.trim();
    if (host.isEmpty || host.contains('/') || host.contains(' ')) return null;
    if (port <= 0 || port > 65535) return null;
    return Socks5Endpoint(
      host: host,
      port: port,
      username: (user == null || user.isEmpty) ? null : user,
      password: (pass == null || pass.isEmpty) ? null : pass,
    );
  }
}

/// 扫本机 Clash / V2Ray / SS 常见 SOCKS 口。
class Socks5LocalProbe {
  Socks5LocalProbe._();

  /// Clash mixed 7890、Clash SOCKS 7891、Clash Verge 7897、
  /// V2RayN SOCKS 10808、Shadowsocks 1080。
  static const List<int> commonPorts = [7890, 7891, 7897, 10808, 1080, 1086, 7892];

  static bool isSocks5Greeting(List<int> bytes) {
    return bytes.length >= 2 && bytes[0] == 0x05;
  }

  static Future<Socks5Endpoint?> detect({
    Future<bool> Function(int port)? isSocks5,
    Duration timeout = const Duration(milliseconds: 400),
  }) async {
    final check = isSocks5 ?? ((port) => _handshake('127.0.0.1', port, timeout));
    for (final port in commonPorts) {
      if (await check(port)) {
        return Socks5Endpoint(host: '127.0.0.1', port: port);
      }
    }
    return null;
  }

  static Future<bool> _handshake(String host, int port, Duration timeout) async {
    Socket? socket;
    try {
      socket = await Socket.connect(host, port, timeout: timeout)
          .timeout(timeout + const Duration(milliseconds: 200));
      socket.add(const [0x05, 0x01, 0x00]);
      await socket.flush();
      final buf = <int>[];
      await for (final chunk in socket.timeout(
        timeout,
        onTimeout: (sink) => sink.close(),
      )) {
        buf.addAll(chunk);
        if (buf.length >= 2) break;
      }
      return isSocks5Greeting(buf);
    } catch (_) {
      return false;
    } finally {
      socket?.destroy();
    }
  }
}

/// 当前进程生效的自定义 SOCKS5（设置变更时写入）。
class Socks5Proxy {
  Socks5Proxy._();
  static Socks5Endpoint? current;
  static Future<void>? _autoJob;
  static int _gen = 0;

  static void apply(AppSettings s) {
    _gen++;
    final gen = _gen;
    final mode = Socks5Endpoint.modeOf(s);
    if (mode == 'auto') {
      current = null;
      _autoJob = () async {
        final found = await Socks5LocalProbe.detect();
        if (gen == _gen) current = found;
      }();
      return;
    }
    _autoJob = null;
    current = Socks5Endpoint.fromSettings(s);
  }

  static Future<Socks5Endpoint?> detectLocal() => Socks5LocalProbe.detect();

  static Future<http.Client> client() async {
    final job = _autoJob;
    if (job != null) await job;
    final ep = current;
    if (ep == null) return http.Client();
    final io = HttpClient();
    final addrs = await InternetAddress.lookup(ep.host);
    if (addrs.isEmpty) {
      throw const SocketException('SOCKS5 主机无法解析');
    }
    SocksTCPClient.assignToHttpClient(io, [
      ProxySettings(
        addrs.first,
        ep.port,
        username: ep.username,
        password: ep.password,
      ),
    ]);
    return IOClient(io);
  }
}
