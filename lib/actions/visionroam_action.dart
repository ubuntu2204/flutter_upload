import 'dart:io';
import 'cmd_utils.dart';
import 'task_config.dart';

/// VisionRoam 部署的固定约定：
/// - 前后端并行编译：后端 `dart compile exe`（Jaspr SSR + JSON API），
///   前端 `flutter build web --base-href /admin/`（Flutter Web 管理后台）
/// - 二进制经 /tmp 中转后替换 `visionroamBinDir/server`，旧版自动备份为 server.bak.时间戳
/// - 站点静态资源（web/ 排除 admin）与后台产物（packages/admin_web/build/web）
///   分别打 tar，并行 scp 上传后解压到站点 web/ 目录（admin 落 web/admin/）
/// - 替换后 chown 给 www-data 并重启 systemd 服务，前后端分别健康检查
const _remoteWebOwner = 'www-data:www-data';
const _defaultVisionroamService = 'visionroam.service';
const _healthCheckUrl = 'http://127.0.0.1:8080/';
const _adminHealthUrl = 'http://127.0.0.1:8080/admin/';

/// 后台源码相对主项目根的路径（Jaspr monorepo 约定）
const _adminWebRelDir = 'packages/admin_web';

/// 功能 6：VisionRoam 前后端一体部署
/// （Jaspr SSR + JSON API 后端二进制 + Flutter Web 管理后台产物）。
///
/// 流程：
///   1. 后端 dart pub get
///   2. 并行编译：后端 AOT 二进制 ‖ 前端 flutter build web（若配置了后台源码）
///   3. 并行打包：站点 web 资源（排除 admin/）‖ 后台产物
///   4. 并行上传：二进制 + 两个 tgz → 远程 /tmp
///   5. 远程原子替换：备份旧版 → 替换二进制 → 解压 web/admin → 赋权 → 重启
///   6. 健康检查：/ 与 /admin/ 均须 200
Future<void> runVisionroam(TaskConfig cfg, void Function(String) addLog) async {
  addLog('--- 开始 VisionRoam 前后端部署流程 ---');

  final projectDir = cfg.visionroamPath;
  if (projectDir.isEmpty) {
    addLog('未配置 VisionRoam 项目本地路径（设置中的 visionroamPath）\n');
    return;
  }
  if (cfg.visionroamBinDir.isEmpty) {
    addLog('未配置 VisionRoam 远程部署目录（设置中的 visionroamBinDir）\n');
    return;
  }

  // 后台源码目录：设置项优先，否则约定在主项目根下 packages/admin_web；
  // 不存在则退化为仅后端部署
  final adminDirPath = cfg.visionroamAdminPath.isNotEmpty
      ? cfg.visionroamAdminPath
      : '$projectDir/$_adminWebRelDir';
  final adminSrcDir = Directory(adminDirPath);
  final hasAdmin = await adminSrcDir.exists();
  if (!hasAdmin) {
    addLog('未找到后台源码 $_adminWebRelDir，跳过前端（Flutter Web）构建\n');
  }

  // ── 1. 准备本地 build 目录（AOT 编译要求输出目录已存在，否则报
  //       PathNotFoundException）──────────────────────────────────────────────
  final buildDir = Directory('$projectDir/build');
  if (!await buildDir.exists()) await buildDir.create(recursive: true);

  // ── 2. 拉取依赖 ────────────────────────────────────────────────────────────
  if (!await runCmd('dart', ['pub', 'get'], projectDir, '后端依赖拉取', addLog,
      tag: '[后端]')) {
    return;
  }

  // ── 3. 并行编译：后端 AOT ‖ 前端 Flutter Web ──────────────────────────────
  addLog('========================================\n'
      '并行编译开始：后端 AOT 二进制 ‖ 前端 Flutter Web\n'
      '========================================\n');
  final compileResults = await Future.wait([
    () async {
      final ok = await runCmd(
        'dart',
        ['compile', 'exe', 'lib/main.server.dart', '-o', 'build/server'],
        projectDir,
        '后端 AOT 编译',
        addLog,
        tag: '[后端]',
      );
      if (ok && !await File('$projectDir/build/server').exists()) {
        addLog('[后端] 编译产物未找到: $projectDir/build/server\n');
        return false;
      }
      return ok;
    }(),
    if (hasAdmin)
      () async {
        return await runCmd('flutter', ['pub', 'get'], adminSrcDir.path,
                '前端依赖拉取', addLog, tag: '[前端]') &&
            await runCmd(
              'flutter',
              ['build', 'web', '--release', '--base-href', '/admin/'],
              adminSrcDir.path,
              '前端 Flutter Web 构建',
              addLog,
              tag: '[前端]',
            ) &&
            await Directory('${adminSrcDir.path}/build/web').exists();
      }(),
  ]);
  final backendBuilt = compileResults[0];
  final frontendBuilt = !hasAdmin || compileResults[1];
  if (!backendBuilt || !frontendBuilt) {
    addLog('并行编译存在失败任务（后端${backendBuilt ? '✓' : '✘'} / '
        '前端${frontendBuilt ? '✓' : '✘'}），中止部署\n');
    return;
  }
  addLog('并行编译全部完成 ✓\n');

  // ── 4. 并行打包：站点 web 资源（排除 admin/）‖ 后台产物 ───────────────────
  final webDir = Directory('$projectDir/web');
  if (!await webDir.exists()) {
    addLog('未找到 web 目录: ${webDir.path}\n');
    return;
  }
  addLog('并行打包开始\n');
  final packResults = await Future.wait([
    runCmd(
        'tar',
        [
          'czf',
          'build/web.tgz',
          '--exclude',
          'web/admin',
          'web',
        ],
        projectDir,
        '站点资源打包(不含 admin)',
        addLog,
        tag: '[站点]'),
    if (hasAdmin)
      runCmd(
          'tar',
          [
            'czf',
            'build/admin.tgz',
            '-C',
            '${adminSrcDir.path}/build/web',
            '.',
          ],
          projectDir,
          '后台产物打包',
          addLog,
          tag: '[前端]'),
  ]);
  if (packResults.contains(false)) {
    addLog('打包失败，中止部署\n');
    return;
  }

  // ── 5. 并行上传到远程 /tmp ────────────────────────────────────────────────
  final host = cfg.ftpHost;
  final sshUser = cfg.sshUser.isNotEmpty ? cfg.sshUser : cfg.ftpUser;
  addLog('并行上传开始：二进制 ‖ 站点包 ‖ 后台包\n');
  final uploads = <Future<bool>>[
    scpUploadFile(host, sshUser, '$projectDir/build/server',
        '/tmp/visionroam-server.new', '后端二进制上传', addLog,
        tag: '[后端]'),
    scpUploadFile(host, sshUser, '$projectDir/build/web.tgz',
        '/tmp/visionroam-web.tgz', '站点资源上传', addLog, tag: '[站点]'),
    if (hasAdmin)
      scpUploadFile(host, sshUser, '$projectDir/build/admin.tgz',
          '/tmp/visionroam-admin.tgz', '后台产物上传', addLog, tag: '[前端]'),
  ];
  final uploadResults = await Future.wait(uploads);
  if (uploadResults.contains(false)) {
    addLog('并行上传存在失败任务，中止部署（远程尚未变更）\n');
    return;
  }
  addLog('并行上传全部完成 ✓\n');

  // ── 6. 远程：备份旧版、替换、解压、赋权、重启、健康检查 ────────────────────
  final binDir = cfg.visionroamBinDir.replaceAll(RegExp(r'/$'), '');
  final lastSlash = binDir.lastIndexOf('/');
  final backendDir = lastSlash > 0 ? binDir.substring(0, lastSlash) : binDir;
  final service = cfg.visionroamService.isNotEmpty
      ? cfg.visionroamService
      : _defaultVisionroamService;
  // 布局自适应：
  //   新版扁平布局：binDir 即站点根，server 与 web/ 同级 → WEB=<binDir>/web
  //   旧版 bin/ 布局：server 在 bin/ 内，web 在其上一级 → WEB=<binDir>/../web
  final webTarget = '\$([ -f "$binDir/server" ] && echo "$binDir/web" '
      '|| echo "$backendDir/web")';
  final remoteScript = [
    'set -e',
    'WEB=$webTarget',
    'sudo cp "$binDir/server" "$binDir/server.bak.\$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true',
    'sudo mv /tmp/visionroam-server.new "$binDir/server"',
    'sudo mkdir -p "\$WEB"; '
        'sudo tar xzf /tmp/visionroam-web.tgz -C "\$WEB" --strip-components=1',
    'if [ -f /tmp/visionroam-admin.tgz ]; then '
        'sudo mkdir -p "\$WEB/admin"; '
        'sudo tar xzf /tmp/visionroam-admin.tgz -C "\$WEB/admin"; '
        'fi',
    'sudo chown -R $_remoteWebOwner "\$WEB" "$binDir"',
    'sudo chmod +x "$binDir/server"',
    'sudo systemctl restart $service',
    'rm -f /tmp/visionroam-web.tgz /tmp/visionroam-admin.tgz',
    'sleep 2',
    'echo "服务状态: \$(systemctl is-active $service)"',
    'code=\$(curl -s -o /dev/null -w \'%{http_code}\' $_healthCheckUrl)',
    'echo "后端健康检查($_healthCheckUrl): \$code"',
    'test "\$code" = "200"',
    'if [ -f "\$WEB/admin/index.html" ]; then '
        'acode=\$(curl -s -o /dev/null -w \'%{http_code}\' $_adminHealthUrl); '
        'echo "前端健康检查($_adminHealthUrl): \$acode"; '
        'test "\$acode" = "200"; '
        'fi',
    'true',
  ].join('; ');
  if (!await sshRunCmd(
      host, sshUser, remoteScript, 'VisionRoam 远程替换并重启服务', addLog)) {
    addLog('远程部署失败！旧版本备份保留在 $binDir/server.bak.*，可手动恢复后重启服务\n');
    return;
  }

  addLog('VisionRoam 前后端部署完成！\n');
}
