import 'dart:io';
import 'cmd_utils.dart';
import 'task_config.dart';

/// VisionRoam 部署的固定约定：
/// - 二进制经 /tmp 中转后替换 `visionroamBinDir/server`，旧版自动备份为 server.bak.时间戳
/// - web/ 静态资源打包上传后解压到 `visionroamBinDir/../web`
///   （后端代码 _resolveWebDir 以 WorkingDirectory=bin 出发探测 ../web）
/// - 替换后 chown 给 www-data 并重启 systemd 服务
const _remoteWebOwner = 'www-data:www-data';
const _defaultVisionroamService = 'visionroam.service';
const _healthCheckUrl = 'http://127.0.0.1:8080/';

/// 功能 6：VisionRoam Jaspr SSR 后端部署。
///
/// 流程：准备 build 目录 → dart pub get → dart compile exe（lib/main.server.dart）
/// → tar 打包 web/ → scp 上传二进制与 web 包到远程 /tmp
/// → SSH 备份旧版、替换二进制、解压 web 资源、赋权、重启服务 → 健康检查。
Future<void> runVisionroam(TaskConfig cfg, void Function(String) addLog) async {
  addLog('--- 开始 VisionRoam 后端部署流程 ---');

  final projectDir = cfg.visionroamPath;
  if (projectDir.isEmpty) {
    addLog('未配置 VisionRoam 项目本地路径（设置中的 visionroamPath）\n');
    return;
  }
  if (cfg.visionroamBinDir.isEmpty) {
    addLog('未配置 VisionRoam 远程部署目录（设置中的 visionroamBinDir）\n');
    return;
  }

  // ── 1. 准备本地 build 目录（AOT 编译要求输出目录已存在，否则报
  //       PathNotFoundException）──────────────────────────────────────────────
  final buildDir = Directory('$projectDir/build');
  if (!await buildDir.exists()) await buildDir.create(recursive: true);

  // ── 2. 拉取依赖并编译 ─────────────────────────────────────────────────────
  if (!await runCmd(
      'dart', ['pub', 'get'], projectDir, 'VisionRoam 依赖拉取', addLog)) {
    return;
  }
  if (!await runCmd(
    'dart',
    ['compile', 'exe', 'lib/main.server.dart', '-o', 'build/server'],
    projectDir,
    'VisionRoam AOT 编译',
    addLog,
  )) {
    return;
  }
  final binFile = File('$projectDir/build/server');
  if (!await binFile.exists()) {
    addLog('编译产物未找到: ${binFile.path}\n');
    return;
  }

  // ── 3. 打包 web 静态资源 ──────────────────────────────────────────────────
  final webDir = Directory('$projectDir/web');
  if (!await webDir.exists()) {
    addLog('未找到 web 目录: ${webDir.path}\n');
    return;
  }
  if (!await runCmd('tar', ['czf', 'build/web.tgz', 'web'], projectDir,
      'VisionRoam web 资源打包', addLog)) {
    return;
  }

  // ── 4. 上传二进制与 web 包到远程 /tmp ────────────────────────────────────
  final host = cfg.ftpHost;
  final sshUser = cfg.sshUser.isNotEmpty ? cfg.sshUser : cfg.ftpUser;
  if (!await scpUploadFile(host, sshUser, binFile.path,
      '/tmp/visionroam-server.new', 'VisionRoam 二进制上传', addLog)) {
    return;
  }
  if (!await scpUploadFile(host, sshUser, '$projectDir/build/web.tgz',
      '/tmp/visionroam-web.tgz', 'VisionRoam web 资源上传', addLog)) {
    return;
  }

  // ── 5. 远程：备份旧版、替换、解压、赋权、重启、健康检查 ────────────────────
  final binDir = cfg.visionroamBinDir.replaceAll(RegExp(r'/$'), '');
  final lastSlash = binDir.lastIndexOf('/');
  final backendDir = lastSlash > 0 ? binDir.substring(0, lastSlash) : binDir;
  final service = cfg.visionroamService.isNotEmpty
      ? cfg.visionroamService
      : _defaultVisionroamService;
  final remoteScript = [
    'set -e',
    'sudo cp "$binDir/server" "$binDir/server.bak.\$(date +%Y%m%d-%H%M%S)"',
    'sudo mv /tmp/visionroam-server.new "$binDir/server"',
    'sudo tar xzf /tmp/visionroam-web.tgz -C "$backendDir"',
    'sudo chown -R $_remoteWebOwner "$binDir" "$backendDir/web"',
    'sudo chmod +x "$binDir/server"',
    'sudo systemctl restart $service',
    'rm -f /tmp/visionroam-web.tgz',
    'sleep 2',
    'echo "服务状态: \$(systemctl is-active $service)"',
    'code=\$(curl -s -o /dev/null -w \'%{http_code}\' $_healthCheckUrl)',
    'echo "健康检查($_healthCheckUrl): \$code"',
    'test "\$code" = "200"',
  ].join('; ');
  if (!await sshRunCmd(
      host, sshUser, remoteScript, 'VisionRoam 远程替换并重启服务', addLog)) {
    addLog('远程部署失败！旧版本备份保留在 $binDir/server.bak.*，可手动恢复后重启服务\n');
    return;
  }

  addLog('VisionRoam 后端部署完成！\n');
}
