import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'file_workspace.dart';
import 'termux_runtime.dart';

/// 一条要拉起的本地 shell。
class ShellSpec {
  final String executable;
  final List<String> arguments;
  final bool usesProot;
  const ShellSpec({
    required this.executable,
    required this.arguments,
    required this.usesProot,
  });
}

/// 把用户终端接到内嵌 Alpine proot（init-host），Windows 走设置里的后端。
class EmbeddedShell {
  EmbeddedShell._();

  static ShellSpec androidInteractive({required String initHostPath}) {
    return ShellSpec(
      executable: '/system/bin/sh',
      arguments: [initHostPath, '/bin/bash', '-i'],
      usesProot: true,
    );
  }

  static ShellSpec androidCommand({
    required String initHostPath,
    required String command,
  }) {
    return ShellSpec(
      executable: '/system/bin/sh',
      arguments: [initHostPath, '-c', command],
      usesProot: true,
    );
  }

  static ShellSpec windowsInteractive({required String backend}) {
    switch (backend) {
      case 'wsl2':
        return const ShellSpec(
          executable: 'wsl.exe',
          arguments: ['-e', 'bash', '-l'],
          usesProot: false,
        );
      case 'cmd':
        return const ShellSpec(
          executable: 'cmd',
          arguments: [],
          usesProot: false,
        );
      default:
        return const ShellSpec(
          executable: 'pwsh',
          arguments: ['-NoLogo'],
          usesProot: false,
        );
    }
  }

  static Future<ShellSpec> resolve({
    required String terminalBackend,
    required String command,
  }) async {
    if (Platform.isWindows) {
      final backend = await TermuxRuntime.resolveWindowsBackend(
        terminalBackend,
      );
      if (command.trim().isEmpty) {
        return windowsInteractive(backend: backend);
      }
      switch (backend) {
        case 'wsl2':
          return ShellSpec(
            executable: 'wsl.exe',
            arguments: ['-e', 'bash', '-lc', command],
            usesProot: false,
          );
        case 'cmd':
          return ShellSpec(
            executable: 'cmd',
            arguments: ['/c', command],
            usesProot: false,
          );
        default:
          return ShellSpec(
            executable: 'pwsh',
            arguments: [
              '-NoProfile',
              '-NoLogo',
              '-NonInteractive',
              '-Command',
              command,
            ],
            usesProot: false,
          );
      }
    }
    final initHost = await TermuxRuntime.shellPath();
    if (command.trim().isEmpty) {
      return androidInteractive(initHostPath: initHost);
    }
    return androidCommand(initHostPath: initHost, command: command);
  }
}

/// 回车时：空闲开新命令，执行中把内容喂进当前进程 stdin。
enum TerminalSubmitTarget { command, stdin }

/// 终端会话：每条命令走一次 proot init-host -c（不依赖 PTY）。
class TerminalSession {
  TerminalSession();

  /// 拾忆 / DSH 共用同一 Alpine，切引擎不新建、不中断。
  static final shared = TerminalSession();

  final StringBuffer log = StringBuffer();
  Process? _running;
  bool busy = false;
  String cwd = FileWorkspace.defaultWorkspacePath;

  Future<void> ensureCwd() async {
    cwd = await FileWorkspace.current();
    try {
      Directory(cwd).createSync(recursive: true);
    } catch (_) {}
  }

  static TerminalSubmitTarget submitTarget({required bool busy}) =>
      busy ? TerminalSubmitTarget.stdin : TerminalSubmitTarget.command;

  Future<int?> submit(
    String text, {
    required String terminalBackend,
    void Function()? onUpdate,
  }) async {
    final cmd = text.trimRight();
    if (cmd.isEmpty && !busy) return null;
    if (submitTarget(busy: busy) == TerminalSubmitTarget.stdin) {
      writeStdin(text);
      onUpdate?.call();
      return null;
    }
    return run(text, terminalBackend: terminalBackend, onUpdate: onUpdate);
  }

  void writeStdin(String text) {
    final proc = _running;
    if (proc == null) return;
    final line = text.endsWith('\n') ? text : '$text\n';
    log.write(line);
    try {
      proc.stdin.add(utf8.encode(line));
      unawaited(proc.stdin.flush());
    } catch (e) {
      log.writeln('写入失败：$e');
    }
  }

  Future<int?> run(
    String command, {
    required String terminalBackend,
    void Function()? onUpdate,
  }) async {
    final cmd = command.trim();
    if (cmd.isEmpty || busy) return null;
    busy = true;
    log.writeln('\$ $cmd');
    onUpdate?.call();
    try {
      final spec = await EmbeddedShell.resolve(
        terminalBackend: terminalBackend,
        command: cmd,
      );
      Map<String, String>? env;
      if (spec.usesProot) {
        env = await TermuxRuntime.environment();
      } else if (Platform.isWindows && spec.executable == 'wsl.exe') {
        env = const {'WSL_UTF8': '1'};
      }
      final proc = await Process.start(
        spec.executable,
        spec.arguments,
        workingDirectory: cwd,
        environment: env,
        runInShell: false,
        mode: ProcessStartMode.normal,
      );
      _running = proc;
      proc.stdout.listen((data) {
        log.write(utf8.decode(data, allowMalformed: true));
        onUpdate?.call();
      });
      proc.stderr.listen((data) {
        log.write(utf8.decode(data, allowMalformed: true));
        onUpdate?.call();
      });
      final code = await proc.exitCode;
      if (!log.toString().endsWith('\n')) log.writeln();
      log.writeln('[exit $code]');
      return code;
    } on ProcessException catch (e) {
      log.writeln('启动失败：${e.message}');
      return -1;
    } finally {
      _running = null;
      busy = false;
      onUpdate?.call();
    }
  }

  /// 停止按钮 / Ctrl+C：先 SIGINT + 0x03，还活着再 SIGKILL。
  static const interruptSignal = ProcessSignal.sigint;
  static const interruptKillSignal = ProcessSignal.sigkill;
  static const int ctrlCByte = 0x03;

  void interrupt() {
    final proc = _running;
    if (proc == null) return;
    final pid = proc.pid;
    try {
      proc.stdin.add([ctrlCByte]);
      unawaited(proc.stdin.flush());
    } catch (_) {}
    try {
      proc.kill(interruptSignal);
    } catch (_) {
      proc.kill();
    }
    unawaited(_forceKillIfAlive(proc, pid));
  }

  Future<void> _forceKillIfAlive(Process proc, int pid) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!identical(_running, proc)) return;
    try {
      proc.kill(interruptKillSignal);
    } catch (_) {
      proc.kill();
    }
    try {
      if (Platform.isWindows) {
        await Process.run('taskkill', ['/F', '/T', '/PID', '$pid']);
      } else {
        await Process.run('/system/bin/kill', ['-9', '$pid']);
      }
    } catch (_) {}
  }

  void clear() {
    log.clear();
  }
}
