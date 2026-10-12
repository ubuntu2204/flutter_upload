import 'dart:convert';
import 'dart:io';
import 'cmd_utils.dart';
import 'ftp_utils.dart';
import 'task_config.dart';

/// 功能 4：flutter build apk --release，同步版本号到 pubspec.yaml、
/// build_config.yaml、后端 config.json，然后将 APK 上传至远程
/// uploads/app-latest.apk（自动升级），config.json 上传至远程 bin/，
/// 同时在 ~/音乐 保留本地副本。
/// 注：前端代码不写死版本号，运行时统一从 build_config.yaml 读取。
Future<void> runMobileRename(
    TaskConfig cfg, void Function(String) addLog) async {
  addLog('--- 开始打包重命名流程 ---');

  // ── 生成版本号（格式同 build_android.sh）──────────────────────────────────
  final now = DateTime.now();
  final dateNum =
      '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
  final dateDash =
      '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  final version = '1.0.$dateNum';
  final buildNumber = int.parse(dateNum);
  addLog('版本号: $version+$buildNumber  ($dateDash)');

  // ── 更新 pubspec.yaml ──────────────────────────────────────────────────────
  final pubspecFile = File('${cfg.mobilePath}/pubspec.yaml');
  if (!await pubspecFile.exists()) {
    addLog('未找到 pubspec.yaml: ${pubspecFile.path}\n');
    return;
  }
  final pubspecContent = await pubspecFile.readAsString();
  final updatedPubspec = pubspecContent.replaceAll(
      RegExp(r'^version: .*$', multiLine: true),
      'version: $version+$buildNumber');
  await pubspecFile.writeAsString(updatedPubspec);
  addLog('已更新 pubspec.yaml → version: $version+$buildNumber');

  // ── 同步 build_config.yaml 的 build_date（前端运行时唯一日期来源）─────────
  // 保证 build_config.yaml / pubspec.yaml / 后端 config.json 三处一致，
  // 前端 getBuildNumber() 从 yaml 算出的 build number 与服务端一致。
  final buildConfigFile = File('${cfg.mobilePath}/build_config.yaml');
  if (await buildConfigFile.exists()) {
    try {
      var yamlContent = await buildConfigFile.readAsString();
      yamlContent = yamlContent.replaceAll(
          RegExp(r'(build_date:\s*")[^"]*(")'), 'build_date: "$dateDash"');
      await buildConfigFile.writeAsString(yamlContent);
      addLog('已更新 build_config.yaml → build_date: "$dateDash"');
    } catch (e) {
      addLog('更新 build_config.yaml 失败: $e');
    }
  }

  // ── 更新后端 config.json 中 app 字段 ──────────────────────────────────────
  final configFile = File('${cfg.backendPath}/config.json');
  if (await configFile.exists()) {
    try {
      final raw = await configFile.readAsString();
      final Map<String, dynamic> config =
          jsonDecode(raw) as Map<String, dynamic>;
      config['app'] ??= <String, dynamic>{};
      (config['app'] as Map<String, dynamic>)['version'] = version;
      (config['app'] as Map<String, dynamic>)['buildNumber'] = buildNumber;
      const encoder = JsonEncoder.withIndent('  ');
      await configFile.writeAsString('${encoder.convert(config)}\n');
      addLog('已更新 config.json → version=$version buildNumber=$buildNumber');
    } catch (e) {
      addLog('更新 config.json 失败: $e');
    }
  } else {
    addLog('后端 config.json 不存在，跳过: ${configFile.path}');
  }

  // ── Flutter 构建 ───────────────────────────────────────────────────────────
  final built = await runCmd('flutter', ['build', 'apk', '--release'],
      cfg.mobilePath, 'Flutter APK 构建', addLog);
  if (!built) return;

  final apkPath =
      '${cfg.mobilePath}/build/app/outputs/flutter-apk/app-release.apk';
  if (!await File(apkPath).exists()) {
    addLog('APK 文件未找到: $apkPath\n');
    return;
  }

  // ── 复制到 ~/音乐（保留音乐文件夹副本）──────────────────────────────────
  final home = Platform.environment['HOME'] ?? '';
  final musicDir = Directory('$home/音乐');
  if (!await musicDir.exists()) await musicDir.create(recursive: true);
  final musicPath = '${musicDir.path}/app-release-$dateNum.apk';
  try {
    await File(apkPath).copy(musicPath);
    addLog('APK 副本已复制到: $musicPath');
  } catch (e) {
    addLog('复制到音乐文件夹失败: $e');
  }

  // ── FTP 上传 APK + config.json ─────────────────────────────────────────
  final ftp = await connectFtp(cfg, addLog);
  if (ftp != null) {
    try {
      // 计算 uploads 目录（同级于 bin，例如 api.flutter.gold/uploads）
      final binDir =
          cfg.ftpBackendDir.replaceAll('\\', '/').replaceAll(RegExp(r'/$'), '');
      final lastSlash = binDir.lastIndexOf('/');
      final appBaseDir =
          lastSlash >= 0 ? binDir.substring(0, lastSlash) : binDir;
      final ftpUploadsDir = '$appBaseDir/uploads';

      // 上传 APK → uploads/app-latest.apk
      await ftpUploadSingleFile(
          cfg, ftp, File(apkPath), ftpUploadsDir, 'app-latest.apk', addLog);

      // 上传 config.json → bin/config.json
      if (await configFile.exists()) {
        await ftpUploadSingleFile(
            cfg, ftp, configFile, cfg.ftpBackendDir, 'config.json', addLog);
      }
    } finally {
      try {
        await ftp.disconnect();
      } catch (_) {}
    }
  }

  addLog('打包重命名部署服务器完成！\n');
}
