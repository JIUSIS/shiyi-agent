import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/models.dart';
import 'package:shiyi_agent_app/services/socks5_config.dart';

void main() {
  group('Socks5Endpoint.parse', () {
    test('host:port', () {
      final e = Socks5Endpoint.parse('127.0.0.1:1080');
      expect(e, isNotNull);
      expect(e!.host, '127.0.0.1');
      expect(e.port, 1080);
      expect(e.username, isNull);
      expect(e.password, isNull);
    });

    test('socks5://user:pass@host:port', () {
      final e = Socks5Endpoint.parse('socks5://alice:s3cret@proxy.example.com:1080');
      expect(e, isNotNull);
      expect(e!.host, 'proxy.example.com');
      expect(e.port, 1080);
      expect(e.username, 'alice');
      expect(e.password, 's3cret');
    });

    test('socks5h://host:port 默认 1080', () {
      final e = Socks5Endpoint.parse('socks5h://proxy.example.com');
      expect(e, isNotNull);
      expect(e!.host, 'proxy.example.com');
      expect(e.port, 1080);
    });

    test('空或非法返回 null', () {
      expect(Socks5Endpoint.parse(''), isNull);
      expect(Socks5Endpoint.parse('   '), isNull);
      expect(Socks5Endpoint.parse('https://127.0.0.1:7890'), isNull);
      expect(Socks5Endpoint.parse('not-a-proxy'), isNull);
    });

    test('http://host:port 当作 Clash mixed 地址', () {
      final e = Socks5Endpoint.parse('http://127.0.0.1:7890');
      expect(e, isNotNull);
      expect(e!.host, '127.0.0.1');
      expect(e.port, 7890);
    });
  });

  test('SOCKS5 设置默认关闭，并随 JSON 往返', () {
    expect(AppSettings().socks5Enabled, isFalse);
    expect(AppSettings().socks5Host, '');
    expect(AppSettings().socks5Port, 1080);
    expect(AppSettings.fromJson({}).socks5Enabled, isFalse);

    final saved = AppSettings(
      socks5Enabled: true,
      socks5Host: '127.0.0.1',
      socks5Port: 1080,
      socks5User: 'u',
      socks5Password: 'p',
    ).toJson();
    final restored = AppSettings.fromJson(saved);
    expect(restored.socks5Enabled, isTrue);
    expect(restored.socks5Host, '127.0.0.1');
    expect(restored.socks5Port, 1080);
    expect(restored.socks5User, 'u');
    expect(saved.containsKey('socks5Password'), isFalse);
  });

  test('从设置拼出 endpoint：关着或没填主机则为空', () {
    expect(Socks5Endpoint.fromSettings(AppSettings()), isNull);
    expect(
      Socks5Endpoint.fromSettings(
        AppSettings(socks5Enabled: true, socks5Host: ''),
      ),
      isNull,
    );
    final e = Socks5Endpoint.fromSettings(
      AppSettings(
        socks5Enabled: true,
        socks5Host: '1.2.3.4',
        socks5Port: 9050,
        socks5User: 'n',
        socks5Password: 's',
      ),
    );
    expect(e, isNotNull);
    expect(e!.host, '1.2.3.4');
    expect(e.port, 9050);
    expect(e.username, 'n');
    expect(e.password, 's');
  });

  test('socks5Mode 默认 off，auto/custom 随 JSON 往返', () {
    expect(AppSettings().socks5Mode, 'off');
    expect(AppSettings.fromJson({}).socks5Mode, 'off');
    final saved = AppSettings(socks5Mode: 'auto').toJson();
    expect(AppSettings.fromJson(saved).socks5Mode, 'auto');
    expect(
      AppSettings().copyWith(socks5Mode: 'custom').socks5Mode,
      'custom',
    );
  });

  test('旧版只有 socks5Enabled=true 时视为 custom', () {
    final restored = AppSettings.fromJson({
      'socks5Enabled': true,
      'socks5Host': '127.0.0.1',
      'socks5Port': 7891,
    });
    expect(restored.socks5Mode, 'custom');
    expect(restored.socks5Enabled, isTrue);
  });

  test('自动模式不从设置写死 endpoint，等本地探测', () {
    expect(
      Socks5Endpoint.fromSettings(
        AppSettings(
          socks5Enabled: true,
          socks5Mode: 'auto',
          socks5Host: '127.0.0.1',
          socks5Port: 7890,
        ),
      ),
      isNull,
    );
  });

  test('自定义代理服务器列表往返且不含密码', () {
    final saved = AppSettings(
      socks5Mode: 'custom',
      socks5Servers: const [
        Socks5Server(
          id: 'a1',
          name: '机场 A',
          host: 'proxy.example.com',
          port: 1080,
          user: 'u',
          password: 'secret',
        ),
      ],
      socks5ActiveId: 'a1',
    ).toJson();
    expect(saved['socks5ActiveId'], 'a1');
    final list = saved['socks5Servers'] as List;
    expect(list, hasLength(1));
    expect(list.single['name'], '机场 A');
    expect(list.single['host'], 'proxy.example.com');
    expect(list.single['port'], 1080);
    expect(list.single.containsKey('password'), isFalse);

    final restored = AppSettings.fromJson(saved);
    expect(restored.socks5Servers, hasLength(1));
    expect(restored.socks5Servers.single.id, 'a1');
    expect(restored.socks5Servers.single.name, '机场 A');
    expect(restored.socks5ActiveId, 'a1');
    expect(restored.socks5Servers.single.password, isEmpty);
  });

  test('选中已保存服务器时用该条目作为自定义通道', () {
    final e = Socks5Endpoint.fromSettings(
      AppSettings(
        socks5Enabled: true,
        socks5Mode: 'custom',
        socks5Host: 'stale.example.com',
        socks5Port: 1,
        socks5ActiveId: 'a1',
        socks5Servers: const [
          Socks5Server(
            id: 'a1',
            name: 'Clash 本机',
            host: '127.0.0.1',
            port: 7891,
            user: 'n',
            password: 's',
          ),
        ],
      ),
    );
    expect(e, isNotNull);
    expect(e!.host, '127.0.0.1');
    expect(e.port, 7891);
    expect(e.username, 'n');
    expect(e.password, 's');
  });

  test('Clash/V2Ray 常见 SOCKS 端口表', () {
    expect(Socks5LocalProbe.commonPorts, containsAll([7890, 7891, 7897, 10808, 1080]));
  });

  test('握手应答 05 00 / 05 02 才算 SOCKS5', () {
    expect(Socks5LocalProbe.isSocks5Greeting([0x05, 0x00]), isTrue);
    expect(Socks5LocalProbe.isSocks5Greeting([0x05, 0x02]), isTrue);
    expect(Socks5LocalProbe.isSocks5Greeting([0x05, 0xFF]), isTrue);
    expect(Socks5LocalProbe.isSocks5Greeting([0x48, 0x54]), isFalse);
    expect(Socks5LocalProbe.isSocks5Greeting([0x00, 0x00]), isFalse);
    expect(Socks5LocalProbe.isSocks5Greeting([]), isFalse);
  });

  test('本地探测按端口表顺序返回第一个 SOCKS5', () async {
    final found = await Socks5LocalProbe.detect(
      isSocks5: (port) async => port == 7891,
    );
    expect(found, isNotNull);
    expect(found!.host, '127.0.0.1');
    expect(found.port, 7891);
  });

  test('本地探测全灭则空', () async {
    expect(
      await Socks5LocalProbe.detect(isSocks5: (_) async => false),
      isNull,
    );
  });
}
