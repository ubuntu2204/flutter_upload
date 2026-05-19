import 'dart:io';
import 'package:ftpconnect/ftpconnect.dart';
import 'task_config.dart';

/// 建立 FTP 连接并打印日志，失败返回 null。
Future<FTPConnect?> connectFtp(
    TaskConfig cfg, void Function(String) addLog) async {
  if (cfg.ftpUser.isEmpty || cfg.ftpPass.isEmpty) {
    addLog('FTP 用户名或密码为空，请先在 FTP 设置中填写。\n');
    return null;
  }
  final startTime = DateTime.now().toString().split('.').first;
  addLog('----------------------------------------\n'
      '开始: $startTime\n'
      '任务: FTP 连接\n'
      '主机: ${cfg.ftpHost}:${cfg.ftpPort}\n'
      '用户: ${cfg.ftpUser}\n');
  final ftp = FTPConnect(cfg.ftpHost,
      port: cfg.ftpPort, user: cfg.ftpUser, pass: cfg.ftpPass, timeout: 30);
  try {
    final ok = await ftp.connect();
    addLog('结果: ${ok ? '成功' : '失败'}\n');
    if (!ok) return null;
    await ftp.setTransferType(TransferType.binary);
    return ftp;
  } catch (e) {
    addLog('异常发生: $e\n');
    return null;
  }
}

/// 静默建立 FTP 连接（供并行上传使用）。
Future<FTPConnect?> connectFtpQuiet(TaskConfig cfg) async {
  if (cfg.ftpUser.isEmpty || cfg.ftpPass.isEmpty) return null;
  final ftp = FTPConnect(cfg.ftpHost,
      port: cfg.ftpPort, user: cfg.ftpUser, pass: cfg.ftpPass, timeout: 30);
  try {
    final ok = await ftp.connect();
    if (!ok) return null;
    await ftp.setTransferType(TransferType.binary);
    return ftp;
  } catch (_) {
    return null;
  }
}

/// 逐级进入/创建远程目录 [remoteDir]。
Future<bool> ftpCwdCreate(
  FTPConnect ftp,
  String remoteDir, {
  bool silent = false,
  void Function(String)? addLog,
}) async {
  final normalized = remoteDir.trim().replaceAll('\\', '/');
  final segments = normalized.split('/').where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) return true;
  for (final seg in segments) {
    try {
      bool changed = await ftp.changeDirectory(seg);
      if (!changed) {
        try {
          await ftp.makeDirectory(seg);
        } catch (_) {}
        changed = await ftp.changeDirectory(seg);
        if (!changed) {
          if (!silent) addLog?.call('FTP 进入目录失败: $seg\n');
          return false;
        }
      }
      if (!silent) addLog?.call('FTP 进入目录: $seg\n');
    } catch (e) {
      if (!silent) addLog?.call('FTP 处理目录失败 ($seg): $e\n');
      return false;
    }
  }
  return true;
}

/// 并行上传 [localDir] 下所有文件到远程 [remoteBaseDir]。
Future<bool> ftpUploadDirectoryParallel(
  TaskConfig cfg,
  Directory localDir,
  String remoteBaseDir,
  void Function(String) addLog, {
  int concurrency = 4,
}) async {
  if (!await localDir.exists()) {
    addLog('本地目录不存在: ${localDir.path}\n');
    return false;
  }
  final startTime = DateTime.now().toString().split('.').first;
  addLog('----------------------------------------\n'
      '开始: $startTime\n'
      '任务: FTP 并行上传目录 (并发数: $concurrency)\n'
      '本地: ${localDir.path}\n'
      '远程: $remoteBaseDir\n');

  final basePath = localDir.path;
  final allFiles = <File>[];
  await for (final entity
      in localDir.list(recursive: true, followLinks: false)) {
    if (entity is File) allFiles.add(entity);
  }
  addLog('共 ${allFiles.length} 个文件，开始并行上传...\n');

  final groups = List.generate(concurrency, (_) => <File>[]);
  for (int i = 0; i < allFiles.length; i++) {
    groups[i % concurrency].add(allFiles[i]);
  }

  final futures = groups.where((g) => g.isNotEmpty).map((group) async {
    final ftp = await connectFtpQuiet(cfg);
    if (ftp == null) {
      addLog('并行连接失败，${group.length} 个文件跳过\n');
      return (ok: 0, fail: group.length);
    }
    int ok = 0;
    int fail = 0;
    try {
      for (final file in group) {
        final absolute = file.path;
        String relative = absolute.startsWith(basePath)
            ? absolute.substring(basePath.length)
            : absolute;
        while (relative.startsWith(Platform.pathSeparator) ||
            relative.startsWith('/')) {
          relative = relative.substring(1);
        }
        final relNormalized = relative.replaceAll('\\', '/');
        final lastSlash = relNormalized.lastIndexOf('/');
        final parentRel =
            lastSlash == -1 ? '' : relNormalized.substring(0, lastSlash);
        final fileName = lastSlash == -1
            ? relNormalized
            : relNormalized.substring(lastSlash + 1);

        try {
          await ftp.changeDirectory('/');
        } catch (_) {}
        bool navOk = await ftpCwdCreate(ftp, remoteBaseDir, silent: true);
        if (navOk && parentRel.isNotEmpty) {
          navOk = await ftpCwdCreate(ftp, parentRel, silent: true);
        }
        if (!navOk) {
          addLog('导航失败: $relNormalized\n');
          fail++;
          continue;
        }
        try {
          await ftp.deleteFile(fileName);
        } catch (_) {}
        bool uploaded = false;
        try {
          uploaded = await ftp.uploadFileWithRetry(file,
              pRemoteName: fileName, pRetryCount: 2);
        } catch (e) {
          addLog('上传异常: $relNormalized - $e\n');
        }
        if (uploaded) {
          ok++;
        } else {
          fail++;
          addLog('上传失败: $relNormalized\n');
        }
      }
    } finally {
      try {
        await ftp.disconnect();
      } catch (_) {}
    }
    return (ok: ok, fail: fail);
  }).toList();

  final results = await Future.wait(futures);
  final totalOk = results.fold(0, (s, r) => s + r.ok);
  final totalFail = results.fold(0, (s, r) => s + r.fail);
  addLog('目录上传完成: 成功 $totalOk, 失败 $totalFail\n');
  return totalFail == 0;
}

/// 上传单个文件 [localFile] 到远程 [remoteDir]/[remoteName]。
Future<bool> ftpUploadSingleFile(
  TaskConfig cfg,
  FTPConnect ftp,
  File localFile,
  String remoteDir,
  String remoteName,
  void Function(String) addLog,
) async {
  if (!await localFile.exists()) {
    addLog('本地文件不存在: ${localFile.path}\n');
    return false;
  }
  final startTime = DateTime.now().toString().split('.').first;
  addLog('----------------------------------------\n'
      '开始: $startTime\n'
      '任务: FTP 上传文件\n'
      '本地: ${localFile.path}\n'
      '远程目录: $remoteDir\n'
      '远程文件名: $remoteName\n');
  try {
    await ftp.changeDirectory('/');
  } catch (_) {}
  final entered = await ftpCwdCreate(ftp, remoteDir, addLog: addLog);
  if (!entered) return false;
  try {
    try {
      await ftp.deleteFile(remoteName);
    } catch (_) {}
    final ok = await ftp.uploadFileWithRetry(localFile,
        pRemoteName: remoteName, pRetryCount: 2);
    addLog('结果: ${ok ? '成功' : '失败'}\n');
    return ok;
  } catch (e) {
    addLog('异常发生: $e\n');
    return false;
  }
}
