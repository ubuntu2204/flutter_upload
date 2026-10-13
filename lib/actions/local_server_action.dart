import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'task_config.dart';

const String _serverMatch = 'bin/server.dart';

/// 后端默认监听端口（server.dart 的 PORT 环境变量缺省值）。
const int _defaultBackendPort = 18080;

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

/// 终止所有 server.dart 相关进程并等待退出。
///
/// 供「停止后端」按钮与「启动后端」的自动重启共用：
/// 1) 终止跟踪进程；2) pkill 兜底清理 dart run 的 bash 包装 + dartvm；
/// 3) 等待退出，未退出则 SIGKILL 强制结束。
///
/// 必须确保进程真正死透再返回：后端启动时绑定端口，旧进程没死透会导致
/// 新进程报 Address in use，表面上"启动了"实际服务的仍是旧进程。
Future<void> _killAllServerProcesses(
  Process? existing,
  void Function(String) addLog,
) async {
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
    addLog('旧后端进程已全部停止。\n');
  } else {
    addLog('警告: 仍有进程未退出:\n$remain\n');
  }
}

/// 启动本地后端服务：在 cfg.backendPath 下执行 dart run bin/server.dart。
///
/// 每次点击都运行**最新代码**，流程：
/// 1. 自动停止仍在运行的旧后端（跟踪中的或 pgrep 发现的残留进程）——
///    之前的行为是"提示已在运行、跳过启动"，改完代码点启动跑的还是旧进程；
/// 2. `dart pub get` 刷新依赖解析（path 依赖的源码变化由 JIT 每次启动
///    直接生效，但 lock 变化/新增依赖必须 pub get，否则解析的还是旧的）；
/// 3. 启动后异步轮询端口确认真正在服务（防止启动失败却看不出来）。
///
/// 返回跟踪中的新后端进程；停止逻辑见 [stopLocalServer]。
Future<Process?> startLocalServer(
  TaskConfig cfg,
  Process? existing,
  void Function(String) addLog,
) async {
  addLog('--- 启动本地后端（自动重启到最新代码） ---\n');

  if (cfg.backendPath.isEmpty) {
    addLog('错误: 未配置后端本地路径，请在设置中填写。\n');
    return existing;
  }

  // 1) 停掉旧进程（无论是否为本应用跟踪的），保证端口释放、代码最新
  final stale = await _findServerProcesses();
  final trackedAlive = existing != null && await _isPidAlive(existing.pid);
  if (trackedAlive || stale != null) {
    addLog('检测到旧后端进程，先自动停止:\n'
        '${trackedAlive ? '（跟踪进程 PID: ${existing.pid}）\n' : ''}'
        '${stale ?? ''}\n');
    await _killAllServerProcesses(existing, addLog);
  } else {
    addLog('无运行中的后端进程。\n');
  }

  // 2) 刷新依赖解析（失败不阻断：依赖未变化时旧解析仍可用）
  try {
    final pub = await Process.run(
      'dart',
      ['pub', 'get'],
      workingDirectory: cfg.backendPath,
    );
    final out =
        '${pub.stdout}${pub.stderr}'.toString().trim();
    if (pub.exitCode == 0) {
      addLog('dart pub get 完成${out.isEmpty ? '' : '\n$out'}\n');
    } else {
      addLog('警告: dart pub get 失败（退出码 ${pub.exitCode}），'
          '继续用已有依赖启动\n$out\n');
    }
  } catch (e) {
    addLog('警告: dart pub get 执行异常，继续启动: $e\n');
  }

  // 3) 启动新进程
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
    // 4) 异步等待端口就绪（不阻塞按钮）
    unawaited(_waitPortReady(addLog));
    return process;
  } catch (e) {
    addLog('启动失败: $e\n');
    return existing;
  }
}

/// 启动后轮询后端端口，确认新进程真正开始监听（最多约 20 秒）。
///
/// 昨天的实际故障形态：旧进程端口未释放 → 新进程 Address in use 退出 →
/// 界面上"已启动"但服务的一直是旧进程。端口探活能直接暴露这种状态。
Future<void> _waitPortReady(void Function(String) addLog) async {
  for (var i = 0; i < 20; i++) {
    await Future.delayed(const Duration(seconds: 1));
    try {
      final s = await Socket.connect(
        '127.0.0.1',
        _defaultBackendPort,
        timeout: const Duration(milliseconds: 800),
      );
      s.destroy();
      addLog('后端已就绪: http://127.0.0.1:$_defaultBackendPort\n');
      return;
    } catch (_) {
      // 尚未监听，继续等待
    }
  }
  addLog('警告: 20 秒内未检测到 $_defaultBackendPort 端口监听，'
      '请查看上方 [server] 日志确认启动状态（可能端口被占用或启动报错）。\n');
}

/// 停止本地后端服务：终止跟踪进程，并按命令行兜底清理 dart run 的子进程。
/// 始终返回 null（表示当前无跟踪中的进程）。
Future<Process?> stopLocalServer(
  Process? existing,
  void Function(String) addLog,
) async {
  addLog('--- 停止本地后端 ---\n');
  await _killAllServerProcesses(existing, addLog);
  if (await _findServerProcesses() == null) {
    addLog('后端已停止。\n');
  }
  return null;
}
