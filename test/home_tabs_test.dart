import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/home_tabs.dart';
import 'package:shiyi_agent_app/services/embedded_shell.dart';

void main() {
  group('主页底部 Tab', () {
    test('拾忆与 DSH 都是四栏，最后一栏是终端', () {
      expect(HomeTabs.shiyi.map((e) => e.label).toList(), [
        '会话',
        '功能',
        '文件',
        '终端',
      ]);
      expect(HomeTabs.dsh.map((e) => e.label).toList(), [
        '工作数据',
        '功能',
        '文件',
        '终端',
      ]);
      expect(HomeTabs.shiyi, hasLength(4));
      expect(HomeTabs.dsh, hasLength(4));
      expect(HomeTabs.terminalIndex, 3);
      expect(HomeTabs.keepAcrossEngineSwitch, [HomeTabs.terminalIndex]);
    });

    test('拾忆与 DSH 共用同一 Alpine 终端会话', () {
      expect(identical(TerminalSession.shared, TerminalSession.shared), isTrue);
    });
  });

  group('EmbeddedShell 命令组包', () {
    test('Android 交互壳走 init-host 进 proot 里的 bash', () {
      final spec = EmbeddedShell.androidInteractive(
        initHostPath:
            '/data/data/com.shiyi.agent/files/termux/local/bin/init-host',
      );
      expect(spec.executable, '/system/bin/sh');
      expect(spec.arguments.first, endsWith('/init-host'));
      expect(spec.arguments, contains('/bin/bash'));
      expect(spec.usesProot, isTrue);
    });

    test('Android 单条命令走 init-host -c', () {
      final spec = EmbeddedShell.androidCommand(
        initHostPath: '/tmp/init-host',
        command: 'uname -a',
      );
      expect(spec.arguments, contains('-c'));
      expect(spec.arguments, contains('uname -a'));
      expect(spec.usesProot, isTrue);
    });

    test('Windows 交互壳不走 proot', () {
      expect(
        EmbeddedShell.windowsInteractive(backend: 'pwsh').usesProot,
        isFalse,
      );
      expect(
        EmbeddedShell.windowsInteractive(backend: 'wsl2').arguments,
        contains('bash'),
      );
    });

    test('停止按钮注入 Ctrl+C：SIGINT + 0x03', () {
      expect(TerminalSession.interruptSignal, ProcessSignal.sigint);
      expect(TerminalSession.ctrlCByte, 0x03);
    });

    test('停止无效时跟 SIGKILL，busy 时回车喂给正在跑的进程', () {
      expect(TerminalSession.interruptKillSignal, ProcessSignal.sigkill);
      expect(
        TerminalSession.submitTarget(busy: false),
        TerminalSubmitTarget.command,
      );
      expect(
        TerminalSession.submitTarget(busy: true),
        TerminalSubmitTarget.stdin,
      );
    });
  });
}
