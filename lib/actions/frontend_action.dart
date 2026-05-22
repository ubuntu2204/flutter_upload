import 'dart:io';
import 'cmd_utils.dart';
import 'ftp_utils.dart';
import 'task_config.dart';
import 'update_build_date_action.dart';

/// 功能 1：flutter build web 并通过 FTP 上传到远程前端目录。
Future<void> runFrontend(TaskConfig cfg, void Function(String) addLog) async {
  addLog('--- 开始前端流程 ---');
  final dateUpdated = await updateBuildDate(cfg, addLog);
  if (!dateUpdated) return;
  final built = await runCmd(
      'flutter', ['build', 'web'], cfg.frontendPath, 'Flutter Web 构建', addLog);
  if (!built) return;
  final ok = await ftpUploadDirectoryParallel(
    cfg,
    Directory('${cfg.frontendPath}/build/web'),
    cfg.ftpFrontendDir,
    addLog,
  );
  if (ok) addLog('前端部署完成！\n');
}
