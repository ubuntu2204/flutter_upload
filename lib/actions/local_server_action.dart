import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'task_config.dart';

const String _serverMatch = 'bin/server.dart';

/// 检查 [pid] 进程是否存活。
Future<bool> _isPidAlive(int pid) async {
  try {
    final r = await Process.run('kill', ['-0', '$pid']);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// 查找 server.dart 相关进程，返回 pgrep 输出（无则 null）。
Future<String?> _findServerProcesses() async {
  try {
    final r = await Process.run('pgrep', ['-af', _serverMatch]);
    if (r.exitCode == 0) {
      final out = r.stdout.toString().trim();
      return out.isEmpty ? null : out;
    }
  } catch (_) {}
  return null;
}

/// 启动本地后端服务：在 cfg.backendPath 下执行 dart run bin/server.dart。
/// 返回跟踪中的后端进程；若已在运行则原样返回并在日志中说明。
Future<Process?> startLocalServer(
  TaskConfig cfg,
  Process? existing,
  void Function(String) addLog,
) async {
  addLog('--- 启动本地后端 ---\n');

  if (cfg.backendPath.isEmpty) {
    addLog('错误: 未配置后端本地路径，请在设置中填写。\n');
    return existing;
  }

  // 已跟踪进程仍在运行
  if (existing != null && await _isPidAlive(existing.pid)) {
    addLog('后端已在运行中 (PID: ${existing.pid})，无需重复启动。\n');
    return existing;
  }

  // 兜底：应用重启后进程引用丢失，但旧 server 还在运行
  final running = await _findServerProcesses();
  if (running != null) {
    addLog('检测到后端已在运行:\n$running\n如需重启请先点击「停止后端」。\n');
    return existing;
  }

  try {
    final process = await Process.start(
      'dart',
      ['run', 'bin/server.dart'],
      workingDirectory: cfg.backendPath,
    );
    addLog('命令: dart run bin/server.dart\n'
        '目录: ${cfg.backendPath}\n'
        '后端已启动 (PID: ${process.pid})\n');
    process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) => addLog('[server] $line\n'));
    process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) => addLog('[server][stderr] $line\n'));
    unawaited(process.exitCode.then((code) {
      addLog('后端进程已退出 (退出码: $code)\n');
    }));
    return process;
  } catch (e) {
    addLog('启动失败: $e\n');
    return existing;
  }
}

/// 停止本地后端服务：终止跟踪进程，并按命令行兜底清理 dart run 的子进程。
/// 始终返回 null（表示当前无跟踪中的进程）。
Future<Process?> stopLocalServer(
  Process? existing,
  void Function(String) addLog,
) async {
  addLog('--- 停止本地后端 ---\n');

  // 1) 终止已跟踪进程
  if (existing != null && await _isPidAlive(existing.pid)) {
    try {
      existing.kill();
      addLog('已向跟踪进程发送终止信号 (PID: ${existing.pid})\n');
    } catch (e) {
      addLog('终止跟踪进程失败: $e\n');
    }
  }

  // 2) 兜底清理 dart run 产生的相关进程（bash 包装 + dartvm）
  try {
    final r = await Process.run('pkill', ['-f', _serverMatch]);
    if (r.exitCode == 0) addLog('已清理 server.dart 相关进程\n');
  } catch (e) {
    addLog('执行 pkill 异常: $e\n');
  }

  // 3) 等待退出，必要时强制结束
  await Future.delayed(const Duration(milliseconds: 500));
  if (await _findServerProcesses() != null) {
    addLog('仍有进程未退出，尝试强制结束 (SIGKILL)...\n');
    try {
      await Process.run('pkill', ['-9', '-f', _serverMatch]);
    } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 300));
  }

  final remain = await _findServerProcesses();
  if (remain == null) {
    addLog('后端已停止。\n');
  } else {
    addLog('警告: 后端停止失败，仍有进程:\n$remain\n');
  }
  return null;
}
