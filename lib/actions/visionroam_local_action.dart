import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'cmd_utils.dart';
import 'task_config.dart';

/// VisionRoam 本地开发一键：并行构建 + 重启 Jaspr SSR 本地服务。
///
/// 与远程部署 [runVisionroam] 不同：全程本地，不连 FTP/SSH，每次点击都跑最新代码。
/// 覆盖 README「前台改动重启服务 / 后台改动构建并复制到 web/admin」两条开发约定。
///
/// 并行策略（16 核实测：冷启动 ~45s、二次点击 ~2s；原串行 ~57s）：
///   后台 Flutter Web 构建 ‖ 主项目 dart pub get ‖ build_runner ‖ dart compile exe
///   两条支路互不依赖；服务就绪不等待后台构建，后台完成后自动更新 web/admin。
///
/// 增量跳过（源码指纹 = 文件内容 sha256 + 工具链版本，记录于 .build-logs/）：
///   - 后台源码（含 packages/shared）未变且 web/admin 在 → 跳过 flutter build web；
///   - lib/ 与 packages/shared 未变且 build/server 在 → 跳过 AOT 编译，直接跑二进制；
///   - lib/ 未变且 main.server.options.dart 在 → 跳过 build_runner。
///
/// 约定：
/// - 后台源码 = 设置项 visionroamAdminPath，留空则取主项目下 packages/admin_web；
///   目录不存在时跳过构建/复制，仅重启服务（前台改动场景）。
/// - 服务启动优先用 AOT 二进制（build/server，就绪 <1s）；编译不可用回退 dart run。
/// - 服务重启先杀旧进程再启动，确保端口释放、加载最新代码。
///
/// 返回跟踪中的本地服务进程；失败时原样返回 [existing]（不改状态）。
const _localServerMatch = 'lib/main.server.dart';
const _localServerPort = 8080; // main.server.dart 默认端口（PORT 环境变量可覆盖）
const _adminWebRelDir = 'packages/admin_web';
const _serverExeRel = 'build/server'; // AOT 产物（与远程部署同路径，可互相复用）
const _serverExeNewRel = 'build/server.new'; // 编译中转：避开运行中二进制的 ETXTBSY
const _optionsFileRel = 'lib/main.server.options.dart';
const _hashDirRel = '.build-logs'; // 源码指纹记录目录（visionroam 侧已 gitignore）
const _hashAdminFile = 'local-admin.sha256';
const _hashServerFile = 'local-server.sha256';
const _hashBuildRunnerFile = 'local-buildrunner.sha256';

Future<Process?> runVisionroamLocal(
  TaskConfig cfg,
  Process? existing,
  void Function(String) addLog,
) async {
  addLog('--- VisionRoam 本地：并行构建 + 重启服务 ---\n');

  final projectDir = cfg.visionroamPath.replaceAll(RegExp(r'/+$'), '');
  if (projectDir.isEmpty) {
    addLog('未配置 VisionRoam 项目本地路径（设置中的 visionroamPath）\n');
    return existing;
  }

  // ── 0. 解析路径与源码指纹（决定哪些构建可跳过）─────────────────────────
  final adminDirPath = cfg.visionroamAdminPath.isNotEmpty
      ? cfg.visionroamAdminPath.replaceAll(RegExp(r'/+$'), '')
      : '$projectDir/$_adminWebRelDir';
  final hasAdmin = await Directory(adminDirPath).exists();
  if (!hasAdmin) {
    addLog('未找到后台源码 $adminDirPath，跳过构建/复制，仅重启服务\n');
  }

  final hashDir = Directory('$projectDir/$_hashDirRel');
  try {
    if (!await hashDir.exists()) await hashDir.create(recursive: true);
  } catch (_) {}

  final flutterTool = await _toolComponent('flutter');
  final dartTool = await _toolComponent('dart');

  // 后台指纹：后台包 lib/web + 双方 pubspec + shared（相对后台包目录）+ Flutter 工具链
  String? adminHash;
  var skipAdmin = false;
  if (hasAdmin) {
    adminHash = await _fingerprint(adminDirPath, [
      'lib',
      'web',
      'pubspec.yaml',
      'pubspec.lock',
      '../shared/lib',
      '../shared/pubspec.yaml',
      '../shared/pubspec.lock',
    ], flutterTool);
    if (adminHash != null &&
        await Directory('$projectDir/web/admin').exists() &&
        await _hashMatches(hashDir, _hashAdminFile, adminHash)) {
      skipAdmin = true;
    }
  }

  // build_runner 指纹：lib + shared + 双方 pubspec + dart 工具链
  // （lib/ 下的 *.options.dart 是生成物，不计入输入）
  final buildRunnerHash = await _fingerprint(projectDir, [
    'lib',
    'packages/shared/lib',
    'pubspec.yaml',
    'pubspec.lock',
  ], dartTool);
  var skipBuildRunner = buildRunnerHash != null &&
      await File('$projectDir/$_optionsFileRel').exists() &&
      await _hashMatches(hashDir, _hashBuildRunnerFile, buildRunnerHash);

  // ── 1. 并行阶段：后台构建 ‖ 主项目依赖/代码生成/服务编译 ─────────────────
  addLog('========================================\n'
      '并行开始：后台 Flutter Web 构建 ‖ 主项目依赖拉取 ‖ @css 生成 ‖ 服务 AOT 编译\n'
      '服务就绪不等待后台构建；后台完成后自动更新 web/admin\n'
      '========================================\n');

  // 后台支路（长棒 ~44s）：依赖拉取 + flutter build web
  final adminFuture = (!hasAdmin || skipAdmin)
      ? Future<bool>.value(true)
      : _buildAdminWeb(adminDirPath, addLog);

  // 主项目支路：依赖拉取（总是执行，保证解析最新；失败不阻断，沿用旧解析）
  final rootPubOk = await runCmd('dart', ['pub', 'get'], projectDir, '主项目依赖拉取',
      addLog, tag: '[服务]');
  if (!rootPubOk) {
    addLog('[服务] 主项目依赖拉取失败，沿用旧解析继续\n');
  }

  // @css 聚合入口（Jaspr CSS-in-Dart 必需；在 pub get 之后跑，避免并发写 .dart_tool）
  var buildRunnerOk = true;
  if (skipBuildRunner) {
    addLog('[服务] @css 源码无改动，跳过 build_runner\n');
  } else {
    buildRunnerOk = await runCmd('dart', ['run', 'build_runner', 'build'], projectDir,
        '生成 @css 聚合入口（main.server.options.dart）', addLog, tag: '[服务]');
    if (buildRunnerOk) {
      await _writeHash(hashDir, _hashBuildRunnerFile, buildRunnerHash);
    } else {
      addLog('[服务] build_runner 失败，沿用旧 @css 聚合入口继续\n');
    }
  }

  // ── 2. 服务编译（AOT；指纹在 build_runner 之后算，纳入新生成的 .options.dart）──
  final serverHash = await _fingerprint(projectDir, [
    'lib',
    'packages/shared/lib',
    'pubspec.yaml',
    'pubspec.lock',
  ], dartTool);
  final serverExe = File('$projectDir/$_serverExeRel');
  var skipCompile = serverHash != null &&
      await serverExe.exists() &&
      await _hashMatches(hashDir, _hashServerFile, serverHash);

  var pendingSwap = false; // 编译已产出 .new，待杀旧进程后改名替换
  var useExe = false;
  if (skipCompile) {
    useExe = true;
    addLog('[服务] 服务源码无改动，跳过 AOT 编译（复用 $_serverExeRel）\n');
  } else {
    try {
      final buildOutDir = Directory('$projectDir/build');
      if (!await buildOutDir.exists()) await buildOutDir.create(recursive: true);
    } catch (_) {}
    // 编译到 .new：正在运行的旧二进制占用 build/server 会报 ETXTBSY；
    // 杀旧进程后rename 原子替换（rename 不受影响，旧进程保留原 inode）。
    final compiled = await runCmd(
      'dart',
      ['compile', 'exe', 'lib/main.server.dart', '-o', _serverExeNewRel],
      projectDir,
      '服务 AOT 编译（下次启动 <1s）',
      addLog,
      tag: '[服务]',
    );
    if (compiled && await File('$projectDir/$_serverExeNewRel').exists()) {
      pendingSwap = true;
    } else {
      addLog('[服务] AOT 编译不可用，回退 dart run 启动\n');
    }
  }

  // ── 3. 重启服务（先停旧进程，释放端口后跑最新代码）──────────────────────
  await _killVisionroamServer(existing, projectDir, addLog);

  // 旧进程已退出，此时替换 AOT 产物才安全；替换成功才记录指纹，
  // 失败则 build/server 仍是旧二进制，不能记（否则下次点击会误跳过编译）。
  if (pendingSwap) {
    try {
      await File('$projectDir/$_serverExeNewRel')
          .rename('$projectDir/$_serverExeRel');
      useExe = true;
      await _writeHash(hashDir, _hashServerFile, serverHash);
    } catch (e) {
      addLog('[服务] AOT 产物替换失败: $e，回退 dart run 启动\n');
    }
  }

  final Process? process = useExe
      ? await _startServer(serverExe.path, const [], projectDir, addLog,
          'AOT 二进制（$_serverExeRel）')
      : await _startServer('dart', ['run', 'lib/main.server.dart'], projectDir,
          addLog, 'dart run');

  // ── 4. 等待后台构建收尾并更新 web/admin ────────────────────────────────
  if (hasAdmin && !skipAdmin) {
    final adminOk = await adminFuture;
    if (adminOk) {
      final builtWeb = Directory('$adminDirPath/build/web');
      if (await builtWeb.exists()) {
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
        if (copied) {
          addLog('后台产物已更新到 $target\n');
          if (adminHash != null) {
            await _writeHash(hashDir, _hashAdminFile, adminHash);
          }
        } else {
          addLog('复制到 web/admin 失败（/admin/ 仍为旧产物，前台不受影响）\n');
        }
      } else {
        addLog('后台构建产物缺失：${builtWeb.path}\n');
      }
    } else {
      addLog('后台构建失败：服务已按最新前台代码重启，/admin/ 仍为旧产物\n');
    }
  } else if (skipAdmin) {
    addLog('后台源码无改动，跳过 Flutter Web 构建（沿用现有 web/admin）\n');
  }

  return process ?? existing;
}

/// 后台支路：依赖拉取 + Flutter Web 发布构建（base-href 与主项目 /admin/ 约定一致）。
Future<bool> _buildAdminWeb(
  String adminDirPath,
  void Function(String) addLog,
) async {
  final pubOk = await runCmd('flutter', ['pub', 'get'], adminDirPath, '后台依赖拉取',
      addLog, tag: '[后台]');
  if (!pubOk) return false;
  return runCmd(
    'flutter',
    ['build', 'web', '--release', '--base-href', '/admin/'],
    adminDirPath,
    '后台 Flutter Web 构建',
    addLog,
    tag: '[后台]',
  );
}

/// 停止旧的 VisionRoam 本地服务：先终止跟踪进程，再按命令行兜底清理。
/// 匹配两种启动方式：`dart run lib/main.server.dart` 与 AOT 产物绝对路径。
/// 匹配串专属于本项目入口，不会误杀 maintenance 的 bin/server.dart。
Future<void> _killVisionroamServer(
  Process? existing,
  String projectDir,
  void Function(String) addLog,
) async {
  if (existing != null) {
    try {
      existing.kill();
    } catch (_) {}
  }
  final patterns = [
    _localServerMatch,
    RegExp.escape('$projectDir/$_serverExeRel'),
  ];
  for (final pattern in patterns) {
    try {
      await Process.run('pkill', ['-f', pattern]);
    } catch (_) {}
  }
  // 第一轮 SIGTERM 后等待端口释放，再补一轮 SIGKILL 兜底
  await Future.delayed(const Duration(milliseconds: 500));
  for (final pattern in patterns) {
    try {
      await Process.run('pkill', ['-9', '-f', pattern]);
    } catch (_) {}
  }
  addLog('已停止旧的 VisionRoam 本地服务进程\n');
}

/// 启动本地服务进程并挂日志监听；[label] 说明启动方式。失败返回 null。
Future<Process?> _startServer(
  String executable,
  List<String> args,
  String workingDir,
  void Function(String) addLog,
  String label,
) async {
  try {
    final process = await Process.start(
      executable,
      args,
      workingDirectory: workingDir,
      // 固定端口，与就绪检测（_waitLocalPort）一致，避免继承来的 PORT 干扰
      environment: {...Platform.environment, 'PORT': '$_localServerPort'},
    );
    addLog('命令: ${[executable, ...args].join(' ')}\n'
        '目录: $workingDir\n'
        '本地服务已启动 (PID: ${process.pid}, $label)\n');
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
    return null;
  }
}

/// 轮询本地端口，确认服务真正开始监听（250ms 间隔，总计约 30 秒）。
Future<void> _waitLocalPort(void Function(String) addLog) async {
  for (var i = 0; i < 120; i++) {
    await Future.delayed(const Duration(milliseconds: 250));
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

/// 工具链版本分量：`可执行文件 路径|mtime|size`。
/// SDK 升级（snap 换目录 / git pull 更新文件）会改变该分量，从而触发重建。
Future<String> _toolComponent(String executable) async {
  try {
    final r = await Process.run('which', [executable]);
    final path = r.stdout.toString().trim();
    if (path.isEmpty) return '$executable:unresolved';
    final st = File(path).statSync(); // 跟随软链，snap 升级会改变目标 mtime
    return '$executable:$path:${st.modified.millisecondsSinceEpoch}:${st.size}';
  } catch (_) {
    return '$executable:unknown';
  }
}

/// 源码指纹：[baseDir] 下 [relPaths]（文件或目录递归）内容 sha256 + 工具链分量。
/// 跳过 *.options.dart（build_runner 生成物，由生成步骤自身负责）。
/// 任何异常返回 null（调用方按「无法判断」处理，即不跳过）。
Future<String?> _fingerprint(
  String baseDir,
  List<String> relPaths,
  String toolComponent,
) async {
  try {
    final parts = <String>[];
    for (final rel in relPaths) {
      final root = '$baseDir/$rel';
      final type = await FileSystemEntity.type(root);
      if (type == FileSystemEntityType.notFound) continue;
      if (type == FileSystemEntityType.file) {
        parts.add(await _fileDigest(root, baseDir));
      } else if (type == FileSystemEntityType.directory) {
        final files = <File>[];
        await for (final e in Directory(root).list(recursive: true, followLinks: false)) {
          if (e is File) files.add(e);
        }
        files.sort((a, b) => a.path.compareTo(b.path));
        for (final f in files) {
          if (f.path.endsWith('.options.dart')) continue;
          parts.add(await _fileDigest(f.path, baseDir));
        }
      }
    }
    parts.add('tool:$toolComponent');
    return sha256.convert(utf8.encode(parts.join('\n'))).toString();
  } catch (_) {
    return null;
  }
}

Future<String> _fileDigest(String path, String baseDir) async {
  final rel = path.substring(baseDir.length + 1);
  final bytes = await File(path).readAsBytes();
  return '$rel:${sha256.convert(bytes)}';
}

Future<bool> _hashMatches(Directory hashDir, String name, String value) async {
  try {
    final f = File('${hashDir.path}/$name');
    if (!await f.exists()) return false;
    return (await f.readAsString()).trim() == value;
  } catch (_) {
    return false;
  }
}

Future<void> _writeHash(Directory hashDir, String name, String? value) async {
  if (value == null) return;
  try {
    await File('${hashDir.path}/$name').writeAsString('$value\n');
  } catch (_) {}
}
