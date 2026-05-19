import 'dart:io';
import 'cmd_utils.dart';
import 'task_config.dart';

/// 功能 5：Git 同步本地源码到 Windows 编译机，再 SSH 执行 flutter build windows。
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

  final localIp = cfg.localIp;
  if (localIp.isEmpty) {
    addLog('本机 IP 未配置，git clone 需要本机 IP 以便 Windows 机器回连\n');
    return;
  }

  // 1. SSH 到 Windows 编译机，确保父目录存在
  final prepareCmd = 'cmd /c "IF NOT EXIST $remoteDir md $remoteDir 2>nul"';
  final prepared =
      await sshRunCmd(winHost, sshUser, prepareCmd, 'Windows 准备目录', addLog);
  if (!prepared) return;

  // 2. git clone（首次）或 git fetch + reset（已有仓库）
  // Windows 通过 SSH 回连 Linux：git clone ubuntu@<localIp>:<localPath>
  final gitUrl = '$sshUser@$localIp:$localPath';
  final gitCmd = 'cmd /c "IF EXIST $remoteProjectPath\\.git '
      '(cd /d $remoteProjectPath && git fetch --all && git reset --hard origin/HEAD) '
      'ELSE (git clone $gitUrl $remoteProjectPath)"';
  final synced = await sshRunCmd(winHost, sshUser, gitCmd, 'Git 同步源码', addLog,
      connectTimeout: 60);
  if (!synced) return;

  // 3. SSH 到 Windows 编译机执行构建
  final remoteCmd =
      'cmd /c "cd /d $remoteProjectPath\\example && flutter build windows"';
  final buildOk = await sshRunCmd(
      winHost, sshUser, remoteCmd, 'Windows 编译', addLog,
      connectTimeout: 30);
  if (buildOk) addLog('Windows 编译完成！\n');
}
