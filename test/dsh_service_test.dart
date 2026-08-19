import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyi_agent_app/core/models.dart';
import 'package:shiyi_agent_app/services/dsh_service.dart';
import 'package:shiyi_agent_app/services/network_proxy.dart';

/// DSH 服务版本比较（semver + rc 预发布）与网络辅助逻辑。
void main() {
  group('compareSemver', () {
    test('普通版本号比较', () {
      expect(DshService.compareSemver('0.1.0', '0.1.0'), 0);
      expect(DshService.compareSemver('0.1.1', '0.1.0'), greaterThan(0));
      expect(DshService.compareSemver('0.2.0', '0.1.9'), greaterThan(0));
      expect(DshService.compareSemver('1.0.0', '0.9.9'), greaterThan(0));
      expect(DshService.compareSemver('0.1.0', '0.1.1'), lessThan(0));
    });

    test('rc 预发布：rc < 正式版，rc 之间按数字比较', () {
      expect(DshService.compareSemver('0.1.0-rc.6', '0.1.0'), lessThan(0));
      expect(DshService.compareSemver('0.1.0', '0.1.0-rc.6'), greaterThan(0));
      expect(
        DshService.compareSemver('0.1.0-rc.7', '0.1.0-rc.6'),
        greaterThan(0),
      );
      expect(
        DshService.compareSemver('0.1.0-rc.10', '0.1.0-rc.9'),
        greaterThan(0),
      );
      expect(DshService.compareSemver('0.1.0-rc.6', '0.1.0-rc.6'), 0);
    });

    test('v 前缀与部分版本号容错', () {
      expect(DshService.compareSemver('v0.1.0', '0.1.0'), 0);
      expect(DshService.compareSemver('0.1.0-rc.6', '0.1.0-rc.7'), lessThan(0));
      expect(DshService.compareSemver('0.1', '0.1.0'), 0);
    });
  });

  group('parseCliVersion', () {
    test('成功输出才抽版本', () {
      expect(DshService.parseCliVersion('0.1.0-rc.6', 0), '0.1.0-rc.6');
      expect(DshService.parseCliVersion('v0.1.0', 0), '0.1.0');
      expect(DshService.parseCliVersion('dsh 0.1.0-rc.6', 0), '0.1.0-rc.6');
    });

    test('失败退出码不当版本，即使输出里有数字', () {
      const err =
          'CANNOT LINK EXECUTABLE: /data/user/0/com.shiyi.agent/files/termux/usr/lib/libz.so.1.3.2 is for EM_AARCH64';
      expect(DshService.parseCliVersion(err, 1), isNull);
      expect(DshService.parseCliVersion('0.1.0-rc.6', 127), isNull);
    });

    test('成功退出也不把 so 版本当 dsh 版本', () {
      expect(DshService.parseCliVersion('libz.so.1.3.2 loaded', 0), isNull);
    });
  });

  group('NetworkProxyDetector 解析', () {
    test('ProxyServer 简单 host:port 解析', () {
      final r = NetworkProxyDetector.parseProxyServer('127.0.0.1:7890');
      expect(r, isNotNull);
      expect(r!.$1, '127.0.0.1');
      expect(r.$2, 7890);
    });

    test('http= 前缀形式解析（忽略 socks 部分）', () {
      final r = NetworkProxyDetector.parseProxyServer(
        'http=127.0.0.1:7890;socks=127.0.0.1:7891',
      );
      expect(r, isNotNull);
      expect(r!.$1, '127.0.0.1');
      expect(r.$2, 7890);
    });

    test('非法值返回 null', () {
      expect(NetworkProxyDetector.parseProxyServer(''), isNull);
      expect(NetworkProxyDetector.parseProxyServer('abc'), isNull);
      expect(NetworkProxyDetector.parseProxyServer('http://x'), isNull);
    });
  });

  group('refreshStatus 进行中保护', () {
    test('安装中即使本地版本为空也不打回 idle（重进页面进度不丢）', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final dsh = DshService.instance;
      dsh.status.value = DshStatus.installing;
      final r = await dsh.refreshStatus();
      expect(r, DshStatus.installing);
      expect(dsh.status.value, DshStatus.installing);
      dsh.status.value = DshStatus.idle;
    });

    test('空闲且本地版本为空时归位未安装 idle', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final dsh = DshService.instance;
      dsh.status.value = DshStatus.running;
      final r = await dsh.refreshStatus();
      expect(r, isNull);
      expect(dsh.status.value, DshStatus.idle);
    });
  });

  group('installOutput 合并', () {
    test('追加保留完整输出', () {
      expect(DshService.mergeInstallOutput('a', 'b'), 'ab');
    });

    test('超过上限只保留尾部', () {
      final current = 'x' * 5;
      final r = DshService.mergeInstallOutput(current, 'y' * 10, maxLength: 10);
      expect(r.length, 10);
      expect(r.endsWith('yyyyy'), isTrue);
    });
  });

  group('sharp wasm32 版本匹配', () {
    test('版本一致跳过补装', () {
      const json = '{"name":"@img/sharp-wasm32", "version": "0.35.3"}';
      expect(DshService.sharpWasmVersionMatches(json, '0.35.3'), isTrue);
    });

    test('版本不一致需要补装', () {
      const json = '{"name":"@img/sharp-wasm32", "version": "0.35.2"}';
      expect(DshService.sharpWasmVersionMatches(json, '0.35.3'), isFalse);
    });
  });

  group('npm 网络错误识别', () {
    test('npm 网络类错误被识别（触发镜像重试）', () {
      expect(DshService.isNetworkError('npm ERR! code ENOTFOUND'), isTrue);
      expect(
        DshService.isNetworkError('network request failed ETIMEDOUT'),
        isTrue,
      );
      expect(DshService.isNetworkError('ECONNREFUSED 127.0.0.1'), isTrue);
    });

    test('非网络错误不触发镜像重试', () {
      expect(DshService.isNetworkError('npm ERR! code EEXIST'), isFalse);
      expect(DshService.isNetworkError('npm ERR! code EPERM'), isFalse);
      expect(DshService.isNetworkError(''), isFalse);
    });

    test('证书/代理/超时也视为网络错误', () {
      expect(
        DshService.isNetworkError('unable to get local issuer certificate'),
        isTrue,
      );
      expect(
        DshService.isNetworkError('tunneling socket could not be established'),
        isTrue,
      );
      expect(
        DshService.isNetworkError(
          'request to https://registry.npmjs.org failed, reason: connect ETIMEDOUT',
        ),
        isTrue,
      );
    });

    test('npmErrorTail 丢掉 debug log 路径，留下最后几行', () {
      const out = '''
npm ERR! code ECONNRESET
npm ERR! network aborted
A complete log of this run can be found in: /tmp/xxxx-debug-0.log
''';
      final tail = DshService.npmErrorTail(out);
      expect(tail.contains('ECONNRESET'), isTrue);
      expect(tail.contains('complete log'), isFalse);
    });
  });

  group('looksUnreachable', () {
    test('连接/超时类错误视为不可达', () {
      expect(
        DshService.looksUnreachable('DeepSeek Harness 服务不可达：TimeoutException'),
        isTrue,
      );
      expect(
        DshService.looksUnreachable('ClientException with SocketException'),
        isTrue,
      );
      expect(DshService.looksUnreachable('Connection refused'), isTrue);
      expect(DshService.looksUnreachable('Connection timed out'), isTrue);
    });

    test('业务错误不触发自愈', () {
      expect(DshService.looksUnreachable('agent-preset-invalid'), isFalse);
      expect(DshService.looksUnreachable(''), isFalse);
    });
  });

  group('dshUseProxy 设置持久化', () {
    test('默认开，随 JSON 往返', () {
      expect(AppSettings().dshUseProxy, isTrue);
      expect(AppSettings.fromJson({}).dshUseProxy, isTrue);
      expect(AppSettings.fromJson({'dshUseProxy': false}).dshUseProxy, isFalse);
      final saved = AppSettings(dshUseProxy: false).toJson();
      expect(AppSettings.fromJson(saved).dshUseProxy, isFalse);
    });
  });

  group('Android hardlink patch', () {
    test('session persist：EACCES 时改 rename', () {
      const src = r'''
import { link, mkdir, mkdtemp, open, readFile, readdir, realpath, rm, stat, truncate } from "node:fs/promises";
		try {
			await link(tmp, finalPath);
			linked = true;
		} finally {
			if (!linked) await rm(tmp, { force: true });
		}
''';
      final out = DshService.patchAndroidHardlinkPublish(src);
      expect(out, contains('rename'));
      expect(out, contains('error?.code !== "EACCES"'));
      expect(out, contains('error?.code !== "ENOSYS"'));
      expect(out, contains('error?.code !== "EPERM"'));
      expect(out, contains('error?.code !== "ENOTSUP"'));
      expect(out, contains('error?.code !== "EOPNOTSUPP"'));
      expect(out, contains('await rename(tmp, finalPath)'));
    });

    test('fs-local：createIfAbsent 的 EACCES 走 rename', () {
      const src = r'''
		if (createIfAbsent !== void 0) try {
			await linkFile(tempPath, absolutePath);
		} catch (error) {
			await throwGuardedCreateFailure(error, absolutePath, createIfAbsent.displayPath, inspectPublicationTarget);
		}
''';
      final out = DshService.patchAndroidFsLocalLink(src);
      expect(out, contains('error?.code === "EACCES"'));
      expect(out, contains('error?.code === "ENOSYS"'));
      expect(out, contains('error?.code === "EPERM"'));
      expect(out, contains('error?.code === "ENOTSUP"'));
      expect(out, contains('error?.code === "EOPNOTSUPP"'));
      expect(out, contains('await rename(tempPath, absolutePath)'));
    });
  });

  group('Android sandbox patch (cordis.patch.yml)', () {
    test('空文件写出完整补丁', () {
      final out = DshService.upsertSandboxPatchYaml('');
      expect(out, startsWith('# ShiYi Android'));
      expect(out, contains('- id: sandbox-policy'));
      expect(out, contains('    mode: danger-full-access'));
      expect(out, contains('- id: approval'));
      expect(out, contains('    policy: never'));
    });

    test('已含补丁标记时幂等', () {
      final once = DshService.upsertSandboxPatchYaml('');
      final twice = DshService.upsertSandboxPatchYaml(once);
      expect(twice, once);
      expect(
        '${DshService.upsertSandboxPatchYaml(once)}\n'.split('\n'),
        hasLength(once.split('\n').length + 1),
      );
    });

    test('模板空列表 [] 替换为补丁条目', () {
      const template = '''
# Your patch layer for this dsh profile, applied after every bundle layer:
# a top-level YAML array of loader patch entries (id-targeted config
# overrides, disables, and insert lists; `!!js` expressions allowed).
[]
''';
      final out = DshService.upsertSandboxPatchYaml(template);
      expect(out, isNot(contains('\n[]')));
      expect(out, contains('- id: sandbox-policy'));
      expect(out, startsWith('# Your patch layer'));
    });

    test('已有用户条目时末尾追加', () {
      const existing = '''
- id: telemetry
  config:
    mode: DISABLED
''';
      final out = DshService.upsertSandboxPatchYaml(existing);
      expect(out, startsWith('- id: telemetry'));
      expect(out, contains('mode: DISABLED'));
      expect(out, contains('- id: sandbox-policy'));
      expect(out, contains('    mode: danger-full-access'));
    });
  });

  group('DSH built-in free search patch', () {
    test('插件资源已打包且不依赖外部 npm 包', () async {
      final package = await rootBundle.loadString(
        'assets/dsh_plugins/shiyi_free_search/package.json',
      );
      final source = await rootBundle.loadString(
        'assets/dsh_plugins/shiyi_free_search/lib/index.js',
      );
      expect(package, isNot(contains('"dependencies"')));
      expect(source, contains('registerSearchProvider'));
      expect(source, contains('name: "plugin_list"'));
      expect(source, contains('ctx.tools.register'));
      expect(source, contains('cordis_inspect_self only lists'));
      expect(source, contains('render(_args, value)'));
    });

    test('插件部署在 web profile 的相对路径根目录', () {
      expect(
        DshService.builtInSearchPluginDir('/root/.dsh'),
        '/root/.dsh/profiles/web/plugins/shiyi-free-search',
      );
    });

    test('空文件写入 provider 与 web 选择器', () {
      final out = DshService.upsertBuiltInSearchPatchYaml('');
      expect(out, contains('name: ./plugins/shiyi-free-search/lib/index.js'));
      expect(out, contains('searchProvider: shiyi-free'));
      expect(out, isNot(contains('provider: auto')));
    });

    test('重复 upsert 替换自有块且保留用户条目', () {
      const existing = '- id: telemetry\n  disabled: true\n';
      final once = DshService.upsertBuiltInSearchPatchYaml(existing);
      final twice = DshService.upsertBuiltInSearchPatchYaml(once);
      expect(twice, once);
      expect(twice, startsWith('- id: telemetry'));
      expect('searchProvider: shiyi-free'.allMatches(twice), hasLength(1));
    });

    test('空列表模板被替换', () {
      final out = DshService.upsertBuiltInSearchPatchYaml('header\n[]\n');
      expect(out, startsWith('header'));
      expect(out, isNot(contains('\n[]')));
      expect(out, contains('web-search-shiyi-free'));
    });
  });

  group('missingAndroidBuildTools', () {
    test('探测成功且无输出视为工具链齐全', () {
      expect(DshService.missingAndroidBuildTools(''), isEmpty);
    });

    test('只回报真正缺的工具', () {
      expect(DshService.missingAndroidBuildTools('cmake\nninja\n'), [
        'cmake',
        'ninja',
      ]);
    });

    test('探测失败视为全部缺失', () {
      expect(DshService.missingAndroidBuildTools('', probeFailed: true), [
        'gcc',
        'g++',
        'make',
        'python3',
        'cmake',
        'ninja',
      ]);
    });
  });
}
