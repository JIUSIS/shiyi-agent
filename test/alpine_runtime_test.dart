import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/services/termux_runtime.dart';

/// 从 lib/services/termux_runtime.dart 源码中提取 raw string 常量，
/// 断言真实脚本内容（源码改动后测试自动跟随，不会失真）。
void main() {
  final source = File('lib/services/termux_runtime.dart').readAsStringSync();
  late final String initHost;
  late final String init;
  late final String apkSources;

  setUpAll(() {
    initHost = _extractRawConst(source, '_initHostScript');
    init = _extractRawConst(source, '_initScript');
    apkSources = _extractRawConst(source, 'apkSourcesScript');
    expect(initHost, isNotEmpty, reason: 'init-host 脚本常量存在');
    expect(init, isNotEmpty, reason: 'init 脚本常量存在');
    expect(apkSources, isNotEmpty, reason: 'apkSourcesScript 常量存在');
  });

  group('isAarch64Machine', () {
    test('真机常见值算 aarch64', () {
      expect(TermuxRuntime.isAarch64Machine('aarch64'), isTrue);
      expect(TermuxRuntime.isAarch64Machine('ARM64'), isTrue);
      expect(TermuxRuntime.isAarch64Machine('armv8l'), isTrue);
    });

    test('x86 模拟器不算', () {
      expect(TermuxRuntime.isAarch64Machine('x86_64'), isFalse);
      expect(TermuxRuntime.isAarch64Machine('i686'), isFalse);
    });
  });

  group('init-host 启动脚本', () {
    test('proot 关键参数齐全（link2symlink / root-id / sysvipc）', () {
      expect(initHost, contains('--link2symlink'));
      expect(initHost, contains('-0'));
      expect(initHost, contains('--sysvipc'));
    });

    test('home 绑定：rootfs 内 /root = 宿主 home（DSH 数据无缝迁移）', () {
      expect(initHost, contains('-b \$PREFIX/home:/root'));
    });

    test('rootfs 指定与 -c 命令形态（run_terminal 兼容）', () {
      expect(initHost, contains('-r \$ROOTFS'));
      expect(initHost, contains('init-host -c <command>'));
      expect(initHost, contains('exec /bin/sh -c "\$1" init-host "\$@"'));
    });

    test('init-host 首次启动走 init 脚本（就绪标记幂等）', () {
      expect(initHost, contains('SHIYI_READY=/etc/shiyi-ready'));
      expect(initHost, contains('SHIYI_INIT='));
      expect(initHost, contains('/bin/sh "\$SHIYI_INIT"'));
    });

    test('init-host 禁用 proot seccomp（libfetch connect 误判 EACCES）', () {
      expect(initHost, contains('PROOT_NO_SECCOMP=1'));
    });

    test('init-host：源脚本缺失或非新版时重跑 init 补齐', () {
      expect(initHost, contains('shiyi-apk-sources'));
      expect(
        initHost,
        contains('! grep -q "v2-uricheck" /usr/local/bin/shiyi-apk-sources'),
      );
    });

    test('proot 未部署 / rootfs 缺失时报 127 并带可读错误', () {
      expect(initHost, contains('proot 未部署'));
      expect(initHost, contains('Alpine rootfs 未部署'));
      expect(initHost, contains('exit 127'));
    });
  });

  group('rootfs init 脚本', () {
    test('apk 源：官方优先 + 国内镜像测速自动切换（探测可达才写入）', () {
      expect(init, contains('shiyi-apk-sources'));
      expect(init, contains('http://dl-cdn.alpinelinux.org/alpine'));
      expect(init, contains('OFFICIAL=http://dl-cdn.alpinelinux.org/alpine'));
      expect(init, contains('http://mirrors.tuna.tsinghua.edu.cn/alpine'));
      expect(init, contains('http://mirrors.aliyun.com/alpine'));
      expect(init, contains('http://mirrors.ustc.edu.cn/alpine'));
      expect(init, contains('http://mirrors.cloud.tencent.com/alpine'));
      expect(init, contains('http://mirrors.huaweicloud.com/alpine'));
      expect(init, contains('/etc/apk/repositories'));
      expect(init, contains('curl -m 4'));
      expect(init, contains('wget -q -T 4'));
      expect(init, contains('sort -n'));
      expect(init, contains('v2-uricheck'));
      expect(init, contains('http://*|https://*)'));
    });

    test('基础包含 bash（DSH 终端/脚本依赖）', () {
      expect(init, contains('add bash gcompat glib nano curl'));
      expect(init, contains(r'[ -x /bin/bash ] && touch /etc/shiyi-ready'));
      expect(init, contains(r'apk $APK_TO cache clean'));
    });

    test('apk 参数按主版本（apk2 --wait 300 网络，apk3 --wait 60 锁等待）', () {
      expect(init, contains('APK_TO="--wait 60 --no-cache"'));
      expect(
        init,
        contains(
          "grep -q 'apk-tools 2' && APK_TO=\"--wait 300 --no-cache\"",
        ),
      );
      expect(init, contains(r'timeout 90 apk $APK_TO $APK_SINGLE update'));
      expect(init, contains(r'timeout 120 apk $APK_TO $APK_SINGLE add bash'));
      expect(init, isNot(contains('--network-timeout 300')));
    });

    test('init 锁 chmod 777（proot -0 属主 root，app 才能删释放）', () {
      expect(init, contains(r'chmod 777 "$INIT_LOCK"'));
      expect(init, contains(r'INIT_LOCK=/tmp/shiyi-init.lock'));
      expect(init, contains(r'find "$INIT_LOCK" -mmin +15'));
    });

    test('init 锁被占时等待持有者完成，不绕过并发 apk', () {
      expect(init, contains(r'while [ $i -lt 120 ] && [ -d "$INIT_LOCK" ]'));
      expect(init, contains(r'sleep 5'));
      expect(init, contains(r'rmdir "$INIT_LOCK"'));
    });

    test('init 部署进度日志写 /sdcard（定位卡点）', () {
      expect(init, contains('INIT_LOG=/sdcard/agent/logs/init-debug.log'));
      expect(init, contains(r'echo "[$(date)] init start'));
    });

    test('基础包阶段清华单源（-X），避免多源索引下载卡死', () {
      expect(init, contains(r'APK_SINGLE="-X http://mirrors.tuna.tsinghua.edu.cn/alpine/$branch/main"'));
      expect(init, contains(r'apk $APK_TO $APK_SINGLE update'));
      expect(init, contains(r'apk $APK_TO $APK_SINGLE add bash'));
    });

    test('install 重建 rootfs 前先彻底删除旧目录', () {
      expect(source, contains('Directory(rootfs).delete(recursive: true)'));
    });

    test('apk-tools 自身升级到分支最新补丁', () {
      expect(init, contains(r'apk $APK_TO $APK_SINGLE upgrade apk-tools'));
    });

    test('apkSourcesScript 常量：URL 校验防御 + 清华固定第一 + 全部国内源 + 与 init heredoc 一致', () {
      expect(apkSources, contains('v2-uricheck'));
      expect(apkSources, contains('http://*|https://*)'));
      expect(apkSources, contains('http://mirrors.tuna.tsinghua.edu.cn/alpine'));
      // 清华不依赖探测固定第一（wget 4s 测速对清华不稳，但 apk 实测可用）
      final tunaIdx = apkSources.indexOf('mirrors.tuna.tsinghua.edu.cn');
      final aliyunIdx = apkSources.indexOf('mirrors.aliyun.com');
      expect(tunaIdx, lessThan(aliyunIdx));
      expect(apkSources, contains('http://mirrors.ustc.edu.cn/alpine'));
      expect(apkSources, contains('http://mirrors.cloud.tencent.com/alpine'));
      expect(apkSources, contains('http://mirrors.huaweicloud.com/alpine'));
      expect(apkSources, contains('http://mirrors.163.com/alpine'));
      expect(apkSources, contains('http://mirrors.sjtug.sjtu.edu.cn/alpine'));
      expect(apkSources, contains('http://mirrors.bfsu.edu.cn/alpine'));
      // init heredoc 里的脚本与常量必须一致（同一脚本两个部署通道）
      expect(init, contains(apkSources.trim()));
    });

    test('就绪标记幂等：bash 就绪才写 /etc/shiyi-ready', () {
      expect(init, contains('/etc/shiyi-ready'));
      expect(init, contains('touch /etc/shiyi-ready'));
    });

    test('网络失败容忍：不阻塞用户命令', () {
      expect(init, contains('2>/dev/null || true'));
    });
  });

  group('运行时结构', () {
    test('环境版本号语义为 alpine（结构变更时递增）', () {
      expect(
        source,
        contains("static const String _envVersion = 'alpine-v7';"),
      );
    });

    test('waitReady 等待 rootfs 部署与首次 init 完成', () {
      expect(source, contains('static Future<void> waitReady()'));
      expect(source, contains('etc/shiyi-ready'));
    });

    test('资产指向 alpine minirootfs 与 proot 家族', () {
      expect(source, contains('alpine-minirootfs-3.24.1-aarch64.tar.gz'));
      expect(source, contains("_prootAsset = 'assets/termux/proot'"));
      expect(source, contains("_tallocAsset = 'assets/termux/libtalloc.so.2'"));
      expect(source, contains("_shmemAsset = 'assets/termux/libandroid-shmem.so'"));
    });

    test('废弃的 Termux shebang / apt / bin-shim 逻辑已移除', () {
      expect(source, isNot(contains('rewriteShebangHead')));
      expect(source, isNot(contains('_termuxAptScript')));
      expect(source, isNot(contains('bin-shim')));
      expect(source, isNot(contains('androidBashArgs')));
    });
  });
}

/// 提取 `static const String <name> = r'''...''';` 的原始内容。
String _extractRawConst(String source, String name) {
  final marker = "static const String $name = r'''";
  final start = source.indexOf(marker);
  if (start < 0) return '';
  final bodyStart = start + marker.length;
  final end = source.indexOf("'''", bodyStart);
  if (end < 0) return '';
  return source.substring(bodyStart, end);
}





