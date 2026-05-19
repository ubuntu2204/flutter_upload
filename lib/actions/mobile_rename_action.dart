import 'dart:io';
import 'cmd_utils.dart';
import 'task_config.dart';

/// 功能 4：flutter build apk，将产物重命名（带日期）后复制到 ~/音乐。
Future<void> runMobileRename(
    TaskConfig cfg, void Function(String) addLog) async {
  addLog('--- 开始打包重命名流程 ---');

  final built = await runCmd(
      'flutter', ['build', 'apk'], cfg.mobilePath, 'Flutter APK 构建', addLog);
  if (!built) return;

  final apkPath =
      '${cfg.mobilePath}/build/app/outputs/flutter-apk/app-release.apk';
  if (!await File(apkPath).exists()) {
    addLog('APK 文件未找到: $apkPath\n');
    return;
  }

  final now = DateTime.now();
  final dateStr =
      '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
  final home = Platform.environment['HOME'] ?? '';
  final destDir = Directory('$home/音乐');
  if (!await destDir.exists()) await destDir.create(recursive: true);
  final destPath = '${destDir.path}/app-release-$dateStr.apk';

  try {
    await File(apkPath).copy(destPath);
    addLog('APK 已复制到: $destPath\n');
    addLog('打包重命名完成！\n');
  } catch (e) {
    addLog('复制文件失败: $e\n');
  }
}
