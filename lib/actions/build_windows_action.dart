import 'dart:io';
import 'cmd_utils.dart';
import 'task_config.dart';

/// 功能 5：SCP 将本地源码上传到 Windows 编译机，再 SSH 执行 flutter build windows。
///
/// 修复点：SSH/SCP 全部使用 [cfg.winBuildHost]（100.65.70.35），
/// 不再错误地连接 FTP 主机（192.168.77.2）。
Future<void> runBuildWindows(
    TaskConfig cfg, void Function(String) addLog) async {
  addLog('--- 开始 Windows 编译流程 ---');

  final localPath = cfg.winLocalProjectPath;
  if (localPath.isEmpty) {
    addLog('本地项目路径未配置，请在设置中填写 Windows 编译本地项目路径\n');
    return;
  }
  if (!await Directory(localPath).exists()) {
    addLog('本地项目目录不存在: $localPath\n');
    return;
  }

  final winHost = cfg.winBuildHost;
  if (winHost.isEmpty) {
    addLog('Windows 编译服务器 IP 未配置\n');
    return;
  }
  final sshUser =
      cfg.winBuildSshUser.isNotEmpty ? cfg.winBuildSshUser : 'ubuntu';
  final projectName = localPath
      .split('/')
      .lastWhere((s) => s.isNotEmpty, orElse: () => 'project');
  final remoteDir = cfg.winRemoteProjectDir.isNotEmpty
      ? cfg.winRemoteProjectDir
      : 'c:/project';
  final remoteProjectPath = '${remoteDir.replaceAll('\\', '/')}/$projectName';

  // 1. SSH 到 Windows 编译机准备目录（使用 winBuildHost，而非 ftpHost）
  final prepareCmd = 'cmd /c "'
      'IF NOT EXIST $remoteDir md $remoteDir 2>nul '
      '& IF EXIST $remoteProjectPath rmdir /s /q $remoteProjectPath"';
  final prepared =
      await sshRunCmd(winHost, sshUser, prepareCmd, 'Windows 准备目录', addLog);
  if (!prepared) return;

  // 2. SCP 上传源码到 Windows 编译机
  final uploadStart = DateTime.now().toString().split('.').first;
  addLog('----------------------------------------\n'
      '开始: $uploadStart\n'
      '任务: SCP 上传源码\n'
      '本地目录: $localPath\n'
      '远程: $sshUser@$winHost:$remoteProjectPath\n');
  final scpResult = await Process.run('scp', [
    '-r',
    '-o',
    'StrictHostKeyChecking=no',
    '-o',
    'BatchMode=yes',
    '-o',
    'ConnectTimeout=30',
    localPath,
    '$sshUser@$winHost:$remoteProjectPath',
  ]);
  String scpLog =
      '结果: ${scpResult.exitCode == 0 ? '成功' : '失败'} (退出码: ${scpResult.exitCode})\n';
  if (scpResult.stdout.toString().trim().isNotEmpty) {
    scpLog += '标准输出:\n${scpResult.stdout}\n';
  }
  if (scpResult.stderr.toString().trim().isNotEmpty) {
    scpLog += '标准错误:\n${scpResult.stderr}\n';
  }
  addLog(scpLog);
  if (scpResult.exitCode != 0) return;

  // 3. SSH 到 Windows 编译机执行构建
  final remoteCmd = 'cmd /c "'
      'cd /d $remoteProjectPath\\example '
      '&& flutter build windows"';
  final buildOk = await sshRunCmd(
      winHost, sshUser, remoteCmd, 'Windows 编译', addLog,
      connectTimeout: 30);
  if (buildOk) addLog('Windows 编译完成！\n');
}
