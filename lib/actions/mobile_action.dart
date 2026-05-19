import 'dart:io';
import 'cmd_utils.dart';
import 'task_config.dart';

/// 功能 3：flutter build apk 并通过 adb 安装到已连接设备。
Future<void> runMobile(TaskConfig cfg, void Function(String) addLog) async {
  addLog('--- 开始移动端部署流程 ---');

  final adbCheck = await Process.run('adb', ['devices'], runInShell: true);
  if (adbCheck.exitCode != 0) {
    addLog('adb 不可用，请确保已安装 Android SDK 并配置好 PATH\n');
    return;
  }
  final deviceLines = adbCheck.stdout
      .toString()
      .split('\n')
      .skip(1)
      .where((l) => l.trim().isNotEmpty && !l.startsWith('*'))
      .toList();
  if (deviceLines.isEmpty) {
    addLog('未检测到已连接的 USB 调试设备，请确保设备已连接并开启 USB 调试\n');
    return;
  }
  addLog('检测到设备:\n${deviceLines.join('\n')}\n');

  final built = await runCmd(
      'flutter', ['build', 'apk'], cfg.mobilePath, 'Flutter APK 构建', addLog);
  if (!built) return;

  final apkPath =
      '${cfg.mobilePath}/build/app/outputs/flutter-apk/app-release.apk';
  if (!await File(apkPath).exists()) {
    addLog('APK 文件未找到: $apkPath\n');
    return;
  }
  final installed = await runCmd(
      'adb', ['install', '-r', apkPath], cfg.mobilePath, 'ADB 安装 APK', addLog);
  if (installed) addLog('移动端部署完成！\n');
}
