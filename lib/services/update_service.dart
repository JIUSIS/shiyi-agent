import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../widgets/markdown_text.dart';

enum UpdateCheckStatus { failed, upToDate, updateAvailable }

/// 版本检查、更新提示与 APK 下载安装，关于页与启动自动检查共用。
class UpdateService {
  UpdateService._();

  static const String appVersion = '1.1.7';
  static const String repoUrl = 'https://github.com/JIUSIS/shiyi-agent';
  static const String apiReleaseUrl =
      'https://api.github.com/repos/JIUSIS/shiyi-agent/releases/latest';

  /// 本次启动里用户点过「稍后」后，自动检查不再重复弹窗。
  static bool _autoCheckDismissed = false;

  /// 数字分段比较版本号：a > b 返回 1，相等 0，a < b 返回 -1。
  static int compareVersion(String a, String b) {
    final pa = a
        .replaceFirst(RegExp('^v', caseSensitive: false), '')
        .split(RegExp(r'[.\-]'))
        .map(int.tryParse)
        .whereType<int>()
        .toList();
    final pb = b
        .replaceFirst(RegExp('^v', caseSensitive: false), '')
        .split(RegExp(r'[.\-]'))
        .map(int.tryParse)
        .whereType<int>()
        .toList();
    final len = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < len; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x > y ? 1 : -1;
    }
    return 0;
  }

  /// 获取最新版本：优先 GitHub Releases API，403/网络失败时回退 jsDelivr 镜像。
  /// 返回 null 表示两种来源都不可用。
  static Future<({String tag, String notes})?> fetchLatest() async {
    // ① GitHub Releases API（公开仓库无需鉴权；403 多为区域网络受限/限流）
    try {
      final res = await http
          .get(Uri.parse(apiReleaseUrl), headers: const {'User-Agent': 'ShiYi'})
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final d = jsonDecode(res.body) as Map<String, dynamic>;
        return (
          tag: (d['tag_name'] ?? '') as String,
          notes: (d['body'] as String? ?? '').trim(),
        );
      }
      if (res.statusCode == 404) {
        // 仓库没有任何 Release：视为当前版本即最新。
        return (tag: 'v$appVersion', notes: '');
      }
    } catch (_) {}
    // ② jsDelivr 镜像（国内可达，不受 GitHub API 限流影响）
    try {
      final res = await http
          .get(
            Uri.parse(
              'https://data.jsdelivr.com/v1/packages/gh/JIUSIS/shiyi-agent',
            ),
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final d = jsonDecode(res.body) as Map<String, dynamic>;
        final versions = (d['versions'] as List? ?? []);
        String? best;
        for (final v in versions) {
          final s = (v is Map ? v['version'] : v)?.toString() ?? '';
          final tag = s.replaceFirst(RegExp('^v'), '');
          if (tag.isEmpty || int.tryParse(tag.split('.').first) == null) {
            continue;
          }
          if (best == null || compareVersion(tag, best) > 0) best = tag;
        }
        if (best != null) return (tag: 'v$best', notes: '');
      }
    } catch (_) {}
    return null;
  }

  /// 检查当前版本与远端最新版本的差异，供手动检查和启动自动检查共用。
  static Future<({UpdateCheckStatus status, String tag, String notes})>
  check() async {
    final latest = await fetchLatest();
    if (latest == null) {
      return (status: UpdateCheckStatus.failed, tag: '', notes: '');
    }
    final remoteVer = latest.tag.replaceFirst(RegExp('^v'), '');
    if (compareVersion(remoteVer, appVersion) > 0) {
      return (
        status: UpdateCheckStatus.updateAvailable,
        tag: remoteVer,
        notes: latest.notes,
      );
    }
    return (status: UpdateCheckStatus.upToDate, tag: appVersion, notes: '');
  }

  /// 启动自动检查：只有发现新版本才提示；点「稍后」本次启动不再弹。
  static Future<void> checkOnLaunch(BuildContext context) async {
    if (_autoCheckDismissed) return;
    final result = await check();
    if (!context.mounted) return;
    if (result.status == UpdateCheckStatus.updateAvailable) {
      await showUpdateAvailable(
        context,
        result.tag,
        result.notes,
        suppressOnLater: true,
      );
    }
  }

  static Future<void> showPlainDialog(
    BuildContext context,
    String title,
    String message,
  ) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  /// 发现新版本弹窗：更新说明固定高度内可滚动，长日志不再截断。
  static Future<void> showUpdateAvailable(
    BuildContext context,
    String ver,
    String notes, {
    bool suppressOnLater = false,
  }) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('发现新版本 v$ver'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: SingleChildScrollView(
            child: notes.isEmpty
                ? const Text('有新版本可以更新。')
                : AdaptiveMarkdownText(notes),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              if (suppressOnLater) _autoCheckDismissed = true;
            },
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              downloadAndInstall(context, ver);
            },
            child: const Text('下载更新'),
          ),
        ],
      ),
    );
  }

  /// 下载并安装新版本 APK。
  /// 优先 GitHub 官方直链，首字节无响应或下载过慢时自动切换国内镜像源。
  static Future<void> downloadAndInstall(
    BuildContext context,
    String ver,
  ) async {
    final direct =
        'https://github.com/JIUSIS/shiyi-agent/releases/download/'
        'v$ver/shiyi-agent-v$ver.apk';
    const mirrors = ['https://gh-proxy.com/', 'https://ghfast.top/'];
    final progress = ValueNotifier<double>(0);
    var cancelled = false;
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/shiyi-agent-v$ver.apk');

    if (!context.mounted) return;
    final dialogCtx = context;
    if (!dialogCtx.mounted) return;
    showDialog<void>(
      context: dialogCtx,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('正在下载更新…'),
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (_, p, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: p > 0 ? p.clamp(0.0, 1.0) : null),
              const SizedBox(height: 10),
              Text(
                p > 0 ? '${(p * 100).toStringAsFixed(0)}%' : '连接中…',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              cancelled = true;
              Navigator.pop(ctx);
            },
            child: const Text('取消'),
          ),
        ],
      ),
    );

    var ok = false;
    for (final base in ['', ...mirrors]) {
      if (cancelled) break;
      final url = '$base$direct';
      try {
        final req = http.Request('GET', Uri.parse(url));
        final res = await http.Client()
            .send(req)
            .timeout(const Duration(seconds: 15));
        if (res.statusCode != 200) continue;
        final total = res.contentLength ?? 0;
        final sink = file.openWrite();
        var received = 0;
        var lastChunk = DateTime.now();
        var slow = false;
        try {
          await for (final chunk in res.stream) {
            if (cancelled) break;
            sink.add(chunk);
            received += chunk.length;
            final now = DateTime.now();
            if (now.difference(lastChunk) > const Duration(seconds: 30)) {
              slow = true; // 30 秒无进度：判定源太慢，换镜像
              break;
            }
            lastChunk = now;
            if (total > 0) progress.value = received / total;
          }
        } finally {
          await sink.close();
        }
        if (slow || received == 0) continue;
        if (total == 0 || received >= total) {
          ok = true;
          progress.value = 1;
          break;
        }
      } catch (_) {
        continue;
      }
    }

    if (!context.mounted) return;
    if (!dialogCtx.mounted) return;
    Navigator.of(dialogCtx, rootNavigator: true).pop();
    if (cancelled) return;
    if (!ok) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('下载失败：所有下载源均不可用，请稍后再试')));
      return;
    }
    // 交给系统安装器
    try {
      const channel = MethodChannel('shiyi/skillpack');
      await channel.invokeMethod('installApk', {'path': file.path});
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('打开安装器失败：$e')));
      }
    }
  }
}
