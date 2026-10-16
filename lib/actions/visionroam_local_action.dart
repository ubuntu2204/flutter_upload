import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'cmd_utils.dart';
import 'task_config.dart';

/// VisionRoam 本地开发一键：构建 Flutter Web 管理后台 → 复制到主项目
/// `web/admin/` → 重启 Jaspr SSR 本地服务（`dart run lib/main.server.dart`）。
///
/// 与远程部署 [runVisionroam] 不同：全程本地，不连 FTP/SSH，每次点击都跑最新代码。
/// 覆盖 README「前台改动重启服务 / 后台改动构建并复制到 web/admin」两条开发约定。
///
/// 约定：
/// - 后台源码 = 设置项 visionroamAdminPath，留空则取主项目下 packages/admin_web；
///   目录不存在时跳过构建/复制，仅重启服务（前台改动场景）。
/// - 复制前先清空 web/admin，避免旧 hash 资源残留导致后台白屏。
/// - 服务重启先杀旧进程再启动，确保端口释放、加载最新代码。
const _localServerMatch = 'lib/main.server.dart';
const _localServerPort = 8080; // main.server.dart 默认端口（PORT 环境变量可覆盖）
const _adminWebRelDir = 'packages/admin_web';

/// 返回跟踪中的本地服务进程；失败时原样返回 [existing]（不改状态）。
Future<Process?> runVisionroamLocal(
  TaskConfig cfg,
  Process? existing,
  void Function(String) addLog,
) async {
  addLog('--- VisionRoam 本地：构建后台 + 复制 web/admin + 重启服务 ---\n');

  final projectDir = cfg.visionroamPath;
  if (projectDir.isEmpty) {
    addLog('未配置 VisionRoam 项目本地路径（设置中的 visionroamPath）\n');
    return existing;
  }

  // ── 1. 构建 Flutter Web 管理后台 ──
  final adminDirPath = cfg.visionroamAdminPath.isNotEmpty
      ? cfg.visionroamAdminPath
      : '$projectDir/$_adminWebRelDir';
  final adminDir = Directory(adminDirPath);
  if (await adminDir.exists()) {
    final built = await runCmd('flutter', ['pub', 'get'], adminDir.path,
            '后台依赖拉取', addLog, tag: '[后台]') &&
        await runCmd(
          'flutter',
          ['build', 'web', '--release', '--base-href', '/admin/'],
          adminDir.path,
          '后台 Flutter Web 构建',
          addLog,
          tag: '[后台]',
        );
    if (!built) {
      addLog('后台构建失败，中止（未复制、未重启）\n');
      return existing;
    }
    final builtWeb = Directory('${adminDir.path}/build/web');
    if (!await builtWeb.exists()) {
      addLog('后台构建产物缺失：${builtWeb.path}，中止\n');
      return existing;
    }

    // ── 2. 复制到主项目 web/admin（先清后拷）──
    final target = '$projectDir/web/admin';
    await runCmd('rm', ['-rf', target], projectDir, '清理旧 web/admin', addLog,
        tag: '[复制]');
    await runCmd('mkdir', ['-p', target], projectDir, '创建 web/admin', addLog,
        tag: '[复制]');
    final copied = await runCmd(
        'cp',
        ['-r', '${builtWeb.path}/.', target],
        projectDir,
        '复制后台产物到 web/admin',
        addLog,
        tag: '[复制]');
    if (!copied) {
      addLog('复制到 web/admin 失败，中止（未重启）\n');
      return existing;
    }
    addLog('后台产物已更新到 $target\n');
  } else {
    addLog('未找到后台源码 ${adminDir.path}，跳过构建/复制，仅重启服务\n');
  }

  // ── 3. 重启本地服务（先停旧进程，释放端口后跑最新代码）──
  await _killVisionroamServer(existing, addLog);

  // 刷新依赖（失败不阻断：依赖未变时旧解析仍可用）
  await runCmd('dart', ['pub', 'get'], projectDir, '主项目依赖拉取', addLog,
      tag: '[服务]');

  try {
    final process = await Process.start(
      'dart',
      ['run', 'lib/main.server.dart'],
      workingDirectory: projectDir,
    );
    addLog('命令: dart run lib/main.server.dart\n'
        '目录: $projectDir\n'
        '本地服务已启动 (PID: ${process.pid})\n');
    process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) => addLog('[server] $line\n'));
    process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) => addLog('[server][stderr] $line\n'));
    unawaited(
        process.exitCode.then((code) => addLog('本地服务已退出 (退出码: $code)\n')));
    unawaited(_waitLocalPort(addLog));
    return process;
  } catch (e) {
    addLog('启动本地服务失败: $e\n');
    return existing;
  }
}

/// 停止旧的 VisionRoam 本地服务：先终止跟踪进程，再按命令行兜底清理。
/// 匹配串 `lib/main.server.dart` 专属于本项目入口，不会误杀 maintenance 的 bin/server.dart。
Future<void> _killVisionroamServer(
  Process? existing,
  void Function(String) addLog,
) async {
  if (existing != null) {
    try {
      existing.kill();
    } catch (_) {}
  }
  try {
    await Process.run('pkill', ['-f', _localServerMatch]);
  } catch (_) {}
  await Future.delayed(const Duration(milliseconds: 500));
  try {
    await Process.run('pkill', ['-9', '-f', _localServerMatch]);
  } catch (_) {}
  addLog('已停止旧的 VisionRoam 本地服务进程\n');
}

/// 轮询本地端口，确认服务真正开始监听（最多约 30 秒）。
Future<void> _waitLocalPort(void Function(String) addLog) async {
  for (var i = 0; i < 30; i++) {
    await Future.delayed(const Duration(seconds: 1));
    try {
      final s = await Socket.connect('127.0.0.1', _localServerPort,
          timeout: const Duration(milliseconds: 800));
      s.destroy();
      addLog('本地服务已就绪: http://127.0.0.1:$_localServerPort/ '
          '（后台 http://127.0.0.1:$_localServerPort/admin/）\n');
      return;
    } catch (_) {
      // 尚未监听，继续等待
    }
  }
  addLog('警告: 30 秒内未检测到 $_localServerPort 端口监听，'
      '请查看上方 [server] 日志确认启动状态（可能端口被占用或启动报错）。\n');
}
