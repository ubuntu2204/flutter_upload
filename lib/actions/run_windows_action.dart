import 'cmd_utils.dart';
import 'task_config.dart';

/// 功能：SSH 到 Windows 编译机，先清除 ephemeral 目录（解决符号链接已存在错误），
/// 再执行 flutter run -d windows，并实时流式输出日志。
Future<void> runWindowsFlutter(
    TaskConfig cfg, void Function(String) addLog) async {
  addLog('--- 开始 执行 flutter Windows ---');

  final winHost = cfg.winBuildHost;
  if (winHost.isEmpty) {
    addLog('Windows 编译服务器 IP 未配置\n');
    return;
  }
  final sshUser =
      cfg.winBuildSshUser.isNotEmpty ? cfg.winBuildSshUser : 'ubuntu';

  final localPath = cfg.winLocalProjectPath;
  final projectName = localPath
      .split('/')
      .lastWhere((s) => s.isNotEmpty, orElse: () => 'project');
  final remoteDir = cfg.winRemoteProjectDir.isNotEmpty
      ? cfg.winRemoteProjectDir
      : 'c:/project';
  // 统一用反斜杠（Windows CMD 路径）
  final remoteProjectPath = '${remoteDir.replaceAll('/', '\\')}\\$projectName';
  final remoteExamplePath = '$remoteProjectPath\\example';

  // 1. 删除 ephemeral 目录，解决 PathExistsException（符号链接已存在）错误
  final ephemeralPath = '$remoteExamplePath\\windows\\flutter\\ephemeral';
  final cleanCmd =
      'cmd /c "IF EXIST "$ephemeralPath" rmdir /s /q "$ephemeralPath""';
  addLog('清理 ephemeral 目录: $ephemeralPath\n');
  await sshRunCmd(winHost, sshUser, cleanCmd, '清理 ephemeral 目录', addLog);

  // 2. 执行 flutter run -d windows，实时输出日志
  final runCmd = 'cmd /c "cd /d $remoteExamplePath && flutter run -d windows"';
  await sshStreamCmd(winHost, sshUser, runCmd, 'flutter run -d windows', addLog,
      connectTimeout: 30);

  addLog('--- flutter Windows 执行完毕 ---\n');
}
