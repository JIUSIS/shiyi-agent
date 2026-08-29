import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../core/models.dart';
import 'llm_client.dart';
import 'runtime_logger.dart';

/// 手机侧 API 中转。
///
/// 远端 DSH 只知道 relay URL 和独立 relay token；真实拾忆 API Key 只在
/// 本进程内读取并写入上游请求，绝不下发给 DSH 主机。
class ShiyiApiRelay {
  static final instance = ShiyiApiRelay._();
  static const routePrefix = '/__shiyi/relay';

  HttpServer? _server;
  HttpClient? _client;
  AppSettings? _settings;
  final Map<String, AppSettings> _routeSettings = {};
  final Map<String, String> _routeTokens = {};
  String _token = '';

  ShiyiApiRelay._();

  bool get isRunning => _server != null;
  int? get port => _server?.port;
  String get token => _token;

  /// 返回手机当前可供局域网 DSH 访问的 IPv4 地址。
  /// 回环地址和链路本地地址不能用于远端连接。
  static Future<String> preferredLanIpv4() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      final candidates = <({String name, String address})>[];
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (address.isLoopback || address.address.startsWith('169.254.')) {
            continue;
          }
          candidates.add((
            name: interface.name.toLowerCase(),
            address: address.address,
          ));
        }
      }
      bool privateAddress(String value) =>
          value.startsWith('10.') ||
          value.startsWith('192.168.') ||
          RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(value);
      for (final candidate in candidates) {
        if ((candidate.name.contains('wlan') ||
                candidate.name.contains('wifi')) &&
            privateAddress(candidate.address)) {
          return candidate.address;
        }
      }
      for (final candidate in candidates) {
        if (privateAddress(candidate.address)) return candidate.address;
      }
      if (candidates.isNotEmpty) return candidates.first.address;
    } catch (_) {}
    return '';
  }

  /// 生成目标 DSH 可访问的手机局域网 Relay 地址。
  /// LAN / 公网连接模式共用这一条地址和同一个监听服务。
  static String reachableBaseUrl({required String lanIpv4, required int port}) {
    final host = lanIpv4.trim();
    if (host.isEmpty) return '';
    final authority = host.contains(':') && !host.startsWith('[')
        ? '[$host]'
        : host;
    return 'http://$authority:$port$routePrefix';
  }

  /// Relay 运行期间只更新手机侧上游配置，不重启监听端口。
  ///
  /// 这样用户修改 API 地址、协议或 Key 后，已有 DSH 连接仍然可用，
  /// 下一次请求会使用最新配置；真实 Key 仍只保留在手机进程内。
  void updateSettings(AppSettings settings) {
    if (!isRunning) return;
    _settings = settings;
  }

  /// 注册一个只存在于手机内存里的 API 路由。目标 DSH 只知道 [routeId]，
  /// 不会拿到该配置的真实 API 地址或密钥。
  void registerRoute(String routeId, AppSettings settings) {
    final id = routeId.trim();
    if (id.isEmpty) return;
    _routeSettings[id] = settings;
    _routeTokens.remove(id);
  }

  /// 注册一个会话级临时路由。该 token 只能访问这一条 route，
  /// 不会获得其它手机 API 配置的访问权。
  void registerLease({
    required String routeId,
    required AppSettings settings,
    required String token,
  }) {
    final id = routeId.trim();
    final value = token.trim();
    if (id.isEmpty || value.isEmpty) return;
    _routeSettings[id] = settings;
    _routeTokens[id] = value;
  }

  /// 撤销会话级临时路由和 token。
  void revokeLease(String routeId, {String? token}) {
    final id = routeId.trim();
    if (id.isEmpty) return;
    final expected = token?.trim() ?? '';
    if (expected.isNotEmpty && _routeTokens[id] != expected) return;
    _routeSettings.remove(id);
    _routeTokens.remove(id);
  }

  void clearRoutes() {
    _routeSettings.clear();
    _routeTokens.clear();
  }

  static String routeIdForProfile(ApiProfile profile, {String sessionId = ''}) {
    final encoded = base64Url
        .encode(utf8.encode(profile.profileId))
        .replaceAll('=', '')
        .toLowerCase();
    final profilePart = encoded.substring(0, encoded.length.clamp(0, 16));
    final session = sessionId.trim();
    return session.isEmpty
        ? 'p_$profilePart'
        : 'p_${profilePart}_s${_shortHash(session)}';
  }

  static String _shortHash(String value) {
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(value)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  static String newToken() {
    final bytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  Future<void> start({
    required AppSettings settings,
    required String token,
    int port = 43121,
  }) async {
    await stop();
    _settings = settings;
    _token = token.trim();
    _client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    _server = await HttpServer.bind(
      InternetAddress.anyIPv4,
      port,
      shared: true,
    );
    _server!.listen(
      _handle,
      onError: (Object error, StackTrace stack) {
        unawaited(
          RuntimeLogger.instance.error(
            'Relay',
            'server.error',
            result: 'failed',
            data: {'error': '$error', 'stack': '$stack'},
          ),
        );
      },
    );
    unawaited(
      RuntimeLogger.instance.info(
        'Relay',
        'server.started',
        data: {'port': _server!.port, 'route': routePrefix},
      ),
    );
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _settings = null;
    _routeSettings.clear();
    _routeTokens.clear();
    _client?.close(force: true);
    _client = null;
    if (server != null) await server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    if (request.method.toUpperCase() != 'POST' ||
        !_isRelayPath(request.uri.path)) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    final relativePath = request.uri.path.substring(routePrefix.length);
    final segments = relativePath
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList();
    final requestedRoute = segments.isNotEmpty ? segments.first : '';
    final routeId = _routeSettings.containsKey(requestedRoute)
        ? segments.removeAt(0)
        : '';
    if (!_authorized(request, routeId)) {
      response.statusCode = HttpStatus.unauthorized;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode({'error': 'invalid relay token'}));
      await response.close();
      return;
    }
    if (routeId.isEmpty && requestedRoute.startsWith('p_')) {
      response.statusCode = HttpStatus.serviceUnavailable;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode({'error': '拾忆 API 中转路由尚未恢复'}));
      await response.close();
      return;
    }
    final settings = routeId.isEmpty ? _settings : _routeSettings[routeId];
    if (settings == null || settings.apiKey.trim().isEmpty) {
      response.statusCode = HttpStatus.serviceUnavailable;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode({'error': '拾忆 API 未配置'}));
      await response.close();
      return;
    }

    final path = segments.join('/');
    final body = await request.fold<List<int>>(<int>[], (out, chunk) {
      out.addAll(chunk);
      return out;
    });
    final upstream = _client;
    if (upstream == null) {
      response.statusCode = HttpStatus.serviceUnavailable;
      await response.close();
      return;
    }

    try {
      final target = upstreamUri(settings, path, request.uri.queryParameters);
      final outgoing = await upstream.postUrl(target);
      _copyRequestHeaders(request, outgoing, settings);
      outgoing.add(body);
      final incoming = await outgoing.close().timeout(
        const Duration(seconds: 120),
      );
      response.statusCode = incoming.statusCode;
      _copyResponseHeaders(incoming, response);
      await incoming.pipe(response);
    } catch (error, stack) {
      try {
        response.statusCode = HttpStatus.badGateway;
        response.headers.contentType = ContentType.json;
        response.write(
          jsonEncode({'error': '上游 API 请求失败', 'detail': '$error'}),
        );
        await response.close();
      } catch (_) {}
      unawaited(
        RuntimeLogger.instance.error(
          'Relay',
          'upstream.failed',
          result: 'failed',
          data: {'error': '$error', 'stack': '$stack'},
        ),
      );
    }
  }

  bool _authorized(HttpRequest request, String routeId) {
    final header = request.headers.value('authorization') ?? '';
    final bearer = header.startsWith('Bearer ')
        ? header.substring(7).trim()
        : '';
    final custom = request.headers.value('x-shiyi-relay-token')?.trim() ?? '';
    final supplied = bearer.isNotEmpty ? bearer : custom;
    if (supplied.isEmpty) return false;
    // The long-lived server token remains compatible with the old local API.
    if (_token.isNotEmpty && supplied == _token) return true;
    final routeToken = _routeTokens[routeId];
    return routeToken != null && supplied == routeToken;
  }

  static bool _isRelayPath(String path) =>
      path == routePrefix || path.startsWith('$routePrefix/');

  static Uri upstreamUri(
    AppSettings settings,
    String requestPath,
    Map<String, String> query,
  ) {
    var baseText = settings.baseUrl.trim();
    if (settings.apiProtocol == 'anthropic') {
      baseText = LlmClient.normalizeAnthropicBaseUrl(baseText);
    } else if (settings.apiProtocol == 'responses') {
      baseText = LlmClient.normalizeResponsesBaseUrl(baseText);
    }
    final base = Uri.parse(baseText);
    var basePath = base.path.replaceFirst(RegExp(r'/+$'), '');
    final isDeepSeekResponses =
        settings.apiProtocol == 'responses' &&
        (base.host == 'api.deepseek.com' || base.host == 'api.deepseek.ai');
    if (isDeepSeekResponses) basePath = '';
    final suffix = requestPath.isEmpty
        ? ''
        : (requestPath.startsWith('/') ? requestPath : '/$requestPath');
    final path = '$basePath$suffix';
    return base.replace(
      path: path.isEmpty ? '/' : path,
      queryParameters: query.isEmpty ? null : query,
    );
  }

  static void _copyRequestHeaders(
    HttpRequest incoming,
    HttpClientRequest outgoing,
    AppSettings settings,
  ) {
    const hopByHop = {
      'authorization',
      'connection',
      'content-length',
      'host',
      'transfer-encoding',
    };
    incoming.headers.forEach((name, values) {
      if (hopByHop.contains(name.toLowerCase())) return;
      outgoing.headers.set(name, values);
    });
    if (settings.apiProtocol == 'anthropic') {
      outgoing.headers.removeAll('x-api-key');
      outgoing.headers.set('x-api-key', settings.apiKey.trim());
      outgoing.headers.set('anthropic-version', '2023-06-01');
      outgoing.headers.set('anthropic-beta', 'prompt-caching-2024-07-31');
    } else {
      outgoing.headers.set('authorization', 'Bearer ${settings.apiKey.trim()}');
    }
  }

  static void _copyResponseHeaders(
    HttpClientResponse incoming,
    HttpResponse outgoing,
  ) {
    const hopByHop = {
      'connection',
      'content-length',
      'keep-alive',
      'proxy-authenticate',
      'proxy-authorization',
      'te',
      'trailer',
      'transfer-encoding',
      'upgrade',
    };
    incoming.headers.forEach((name, values) {
      if (hopByHop.contains(name.toLowerCase())) return;
      outgoing.headers.set(name, values);
    });
  }
}
