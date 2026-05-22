import 'dart:convert';
import 'dart:io';
import 'cmd_utils.dart';
import 'task_config.dart';

/// 功能 4：flutter build apk --release，同步版本号到 pubspec.yaml、
/// build_info.dart、后端 config.json，然后将 APK 复制到
/// ~/音乐（副本）和后端 downloads/app-latest.apk（自动升级）。
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

  // ── 更新 lib/core/build_info.dart ─────────────────────────────────────────
  final buildInfoDir = Directory('${cfg.mobilePath}/lib/core');
  if (!await buildInfoDir.exists()) await buildInfoDir.create(recursive: true);
  final buildInfoFile = File('${buildInfoDir.path}/build_info.dart');
  await buildInfoFile.writeAsString('// 由打包脚本自动生成，请勿手动修改。\n'
      '// ignore_for_file: constant_identifier_names\n'
      '\n'
      '/// 最后一次构建日期，格式 "YYYY-MM-DD"。\n'
      "const String kBuildDate = '$dateDash';\n"
      '\n'
      '/// 当前 App build number（对应 pubspec.yaml 中 version 的 +N 部分）。\n'
      '/// 用于与后端 /app-version 返回值比较，判断是否需要更新。\n'
      'const int kAppBuildNumber = $buildNumber;\n');
  addLog('已更新 build_info.dart');

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

  // ── 复制到后端 downloads（供自动升级）────────────────────────────────────
  final downloadsDir = Directory('${cfg.backendPath}/downloads');
  if (!await downloadsDir.exists()) await downloadsDir.create(recursive: true);
  final latestPath = '${downloadsDir.path}/app-latest.apk';
  try {
    await File(apkPath).copy(latestPath);
    addLog('APK 已复制到: $latestPath（供自动升级）');
  } catch (e) {
    addLog('复制到后端 downloads 失败: $e');
  }

  addLog('打包重命名完成！\n');
}
