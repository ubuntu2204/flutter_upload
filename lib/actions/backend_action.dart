import 'dart:io';
import 'cmd_utils.dart';
import 'ftp_utils.dart';
import 'task_config.dart';

/// 功能 2：dart compile exe 并通过 FTP 上传到远程后端目录，再 SSH 重启服务。
Future<void> runBackend(TaskConfig cfg, void Function(String) addLog) async {
  addLog('--- 开始后端流程 ---');
  final built = await runCmd(
    'dart',
    [
      'compile',
      'exe',
      'bin/server.dart',
      '-o',
      'build/cli/linux_x64/bundle/bin/server',
    ],
    cfg.backendPath,
    'Dart 后端构建',
    addLog,
  );
  if (!built) return;

  // SSH 先杀掉旧进程，再上传新文件
  // sudo kill -9 $(sudo lsof -t -i:18080) 2>/dev/null
  // 'pkill -x server; true'
  final sshUser = cfg.sshUser.isNotEmpty ? cfg.sshUser : cfg.ftpUser;

  // await sshRunCmd(cfg.ftpHost, sshUser,
  //     r"kill -9 $(lsof -t -i:18080) 2>/dev/null", 'SSH 关闭旧 server 进程', addLog);

  final ftp = await connectFtp(cfg, addLog);
  if (ftp == null) return;
  try {
    final ok = await ftpUploadSingleFile(
      cfg,
      ftp,
      File('${cfg.backendPath}/build/cli/linux_x64/bundle/bin/server'),
      cfg.ftpBackendDir,
      'server',
      addLog,
    );
    if (!ok) return;

    // 上传 config.json 到 server 同目录
    final configFile = File('${cfg.backendPath}/config.json');
    if (await configFile.exists()) {
      await ftpUploadSingleFile(
        cfg,
        ftp,
        configFile,
        cfg.ftpBackendDir,
        'config.json',
        addLog,
      );
    } else {
      addLog('未找到 config.json，跳过配置文件上传\n');
    }

    // 赋可执行权限
    try {
      await ftp.changeDirectory('/');
      await ftpCwdCreate(ftp, cfg.ftpBackendDir, addLog: addLog);
      final reply = await ftp.sendCustomCommand('SITE CHMOD 755 server');
      addLog('设置可执行权限: ${reply.message}\n');
    } catch (e) {
      addLog('设置可执行权限失败: $e\n');
    }

    // SSH 启动新 server
    if (cfg.serverStartCmd.isNotEmpty) {
      await sshRunCmd(
        cfg.ftpHost,
        sshUser,
        'sudo systemctl restart dart-backend',
        'SSH 启动新 server',
        addLog,
      );
    }
    addLog('后端部署完成！\n');
  } finally {
    try {
      await ftp.disconnect();
    } catch (_) {}
  }
}
