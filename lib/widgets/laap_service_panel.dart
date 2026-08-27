import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../services/laap_service.dart';

/// 引擎页上的 LAAP 皮层服务卡。不进拾忆/DSH 引擎切换。
class LaapServicePanel extends StatefulWidget {
  const LaapServicePanel({
    super.key,
    required this.enablePresence,
    required this.onPresenceChanged,
  });

  final bool enablePresence;
  final ValueChanged<bool> onPresenceChanged;

  @override
  State<LaapServicePanel> createState() => _LaapServicePanelState();
}

class _LaapServicePanelState extends State<LaapServicePanel> {
  final _laap = LaapService.instance;
  bool _working = false;
  bool _showOutput = false;
  String? _error;
  String? _localVersion;
  bool _installed = false;
  final _outputScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _laap.status.addListener(_tick);
    _laap.progress.addListener(_tick);
    _laap.statusMessage.addListener(_tick);
    _laap.installOutput.addListener(_tick);
    unawaited(_refreshInstalled());
  }

  @override
  void dispose() {
    _laap.status.removeListener(_tick);
    _laap.progress.removeListener(_tick);
    _laap.statusMessage.removeListener(_tick);
    _laap.installOutput.removeListener(_tick);
    _outputScroll.dispose();
    super.dispose();
  }

  void _tick() {
    if (!mounted) return;
    setState(() {});
    if (_showOutput && _outputScroll.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_outputScroll.hasClients) return;
        _outputScroll.jumpTo(_outputScroll.position.maxScrollExtent);
      });
    }
    final s = _laap.status.value;
    if (s == LaapStatus.idle || s == LaapStatus.running) {
      unawaited(_refreshInstalled());
    }
  }

  Future<void> _refreshInstalled() async {
    final installed = await _laap.isInstalled();
    final ver = await _laap.localVersion();
    if (!mounted) return;
    setState(() {
      _installed = installed;
      _localVersion = ver;
    });
  }

  String get _statusLabel {
    switch (_laap.status.value) {
      case LaapStatus.installing:
        return '安装中…';
      case LaapStatus.starting:
        return '启动中…';
      case LaapStatus.running:
        return '运行中';
      case LaapStatus.stopping:
        return '停止中…';
      case LaapStatus.uninstalling:
        return '卸载中…';
      case LaapStatus.error:
        return '出错';
      case LaapStatus.idle:
        return _installed ? '已停止' : '未安装';
    }
  }

  bool get _busy {
    final s = _laap.status.value;
    return _working ||
        s == LaapStatus.installing ||
        s == LaapStatus.starting ||
        s == LaapStatus.stopping ||
        s == LaapStatus.uninstalling;
  }

  Future<void> _run(Future<void> Function() job) async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await job();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _working = false);
      await _refreshInstalled();
    }
  }

  Future<void> _confirmUninstall() async {
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('卸载 LAAP'),
        content: const Text('将删除源码，状态目录 .laap/state 会保留。确定继续吗？'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('卸载'),
          ),
        ],
      ),
    );
    if (ok == true) await _run(_laap.uninstall);
  }

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final s = _laap.status.value;
    final card = dark ? const Color(0xFF1C1C1E) : const Color(0xFFFFFFFF);
    final bg = dark ? const Color(0xFF000000) : const Color(0xFFF2F2F7);
    final deco = BoxDecoration(
      color: card,
      borderRadius: BorderRadius.circular(10),
    );
    return Column(
      children: [
        CupertinoListSection.insetGrouped(
          decoration: deco,
          backgroundColor: bg,
          header: const Text('LAAP 认知皮层'),
          footer: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Text(
              '给拾忆活人感供 PSI 认知状态，不是第三套聊天引擎。打开活人感且皮层就绪才把 preamble 注入动尾，没有本地替身。',
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: dark
                    ? CupertinoColors.white.withValues(alpha: .55)
                    : CupertinoColors.black.withValues(alpha: .5),
              ),
            ),
          ),
          children: [
            _row('本地版本', _localVersion ?? '未安装'),
            _row('服务状态', _statusLabel),
            _row('接口', '127.0.0.1:${LaapService.port}'),
            CupertinoListTile(
              title: const Text('活人感'),
              subtitle: const Text('按 Hermes 官方接法注入 PSI preamble。关掉或皮层挂了就不注入'),
              trailing: CupertinoSwitch(
                value: widget.enablePresence,
                onChanged: _busy
                    ? null
                    : (v) {
                        widget.onPresenceChanged(v);
                        if (v) {
                          unawaited(
                            _run(() async {
                              final ok = await _laap.start();
                              if (!ok) {
                                throw LaapStartException(
                                  _laap.statusMessage.value,
                                );
                              }
                            }),
                          );
                        }
                      },
              ),
            ),
            if (_busy || _error != null || _showOutput)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_busy) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: _laap.progress.value > 0
                              ? _laap.progress.value.clamp(0.0, 1.0)
                              : null,
                          minHeight: 6,
                          backgroundColor: dark
                              ? const Color(0xFF3A3A3C)
                              : const Color(0xFFE5E5EA),
                          color: const Color(0xFF0A84FF),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _laap.statusMessage.value.isEmpty
                            ? '准备中…'
                            : _laap.statusMessage.value,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.3,
                          color: dark
                              ? CupertinoColors.white.withValues(alpha: .65)
                              : CupertinoColors.black.withValues(alpha: .55),
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() => _showOutput = !_showOutput),
                      child: Row(
                        children: [
                          Icon(
                            _showOutput
                                ? CupertinoIcons.chevron_down
                                : CupertinoIcons.chevron_right,
                            size: 13,
                            color: CupertinoColors.systemGrey,
                          ),
                          const SizedBox(width: 6),
                          const Text(
                            '显示终端输出',
                            style: TextStyle(
                              fontSize: 13,
                              color: CupertinoColors.systemGrey,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_showOutput) ...[
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        constraints: const BoxConstraints(maxHeight: 240),
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                        decoration: BoxDecoration(
                          color: dark
                              ? const Color(0xFF1C1C1E)
                              : const Color(0xFFF2F2F7),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: SingleChildScrollView(
                          controller: _outputScroll,
                          child: Text(
                            _laap.installOutput.value.isEmpty
                                ? '等待终端输出…'
                                : _laap.installOutput.value,
                            style: TextStyle(
                              fontFamily: 'Menlo',
                              fontFamilyFallback: const [
                                'Courier',
                                'monospace',
                              ],
                              fontSize: 11,
                              height: 1.45,
                              color: dark
                                  ? const Color(0xFFD1D1D6)
                                  : const Color(0xFF3A3A3C),
                            ),
                          ),
                        ),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _error!,
                        style: const TextStyle(
                          fontSize: 13,
                          color: CupertinoColors.systemRed,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
        CupertinoListSection.insetGrouped(
          decoration: deco,
          backgroundColor: bg,
          children: [
            CupertinoListTile(
              title: Text(_installed ? '卸载 LAAP' : '立即安装'),
              subtitle: Text(
                _installed
                    ? '删除源码，保留 .laap/state'
                    : Platform.isAndroid
                    ? 'Alpine 内装 Python，再拉 laap-MAX'
                    : '本机 Python 3.11+ 拉 laap-MAX',
              ),
              onTap: _busy
                  ? null
                  : _installed
                  ? _confirmUninstall
                  : () => _run(_laap.install),
            ),
            CupertinoListTile(
              title: Text(s == LaapStatus.running ? '停止皮层' : '启动皮层'),
              subtitle: Text(
                _installed
                    ? 'python -m laap_brain.api（127.0.0.1:${LaapService.port}）'
                    : '未安装 LAAP，请先安装',
              ),
              onTap: _busy || !_installed
                  ? null
                  : s == LaapStatus.running
                  ? () => _run(_laap.stop)
                  : () => _run(() async {
                      final ok = await _laap.start();
                      if (!ok) {
                        throw LaapStartException(_laap.statusMessage.value);
                      }
                    }),
            ),
          ],
        ),
      ],
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Text(label, style: const TextStyle(fontSize: 15)),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(
              fontSize: 15,
              color: CupertinoColors.systemGrey,
            ),
          ),
        ],
      ),
    );
  }
}

class LaapStartException implements Exception {
  final String message;
  LaapStartException(this.message);
  @override
  String toString() => message;
}
