import 'dart:convert';
import 'dart:io';

import 'cmd_utils.dart';
import 'ftp_utils.dart';
import 'task_config.dart';

/// 远程后端进程的标准输出/错误落盘位置（健康检查失败时用于定位启动问题）。
const String remoteServerLog = '/tmp/maintenance_backend.log';

/// 从 [serverStartCmd] 解析出后端二进制所在目录，用于备份旧版本。
///
/// 配置约定启动命令形如 `cd /srv/api/bin && ./server`，这里取第一个 `cd`
/// 的目标目录；解析不到时返回 null（跳过备份，不阻断部署）。
String? parseBackendBinDir(String serverStartCmd) {
  final m = RegExp("cd\\s+['\"]?([^'\"&;]+)").firstMatch(serverStartCmd);
  final dir = m?.group(1)?.trim();
  if (dir == null || dir.isEmpty) return null;
  return dir;
}

/// 构造「停止旧后端进程」的远程脚本，并确认其真正退出。
///
/// 必须放在上传之前：Linux 下覆盖正在执行的二进制会报 Text file busy，
/// 且旧进程不重启就永远跑旧代码。
/// 必须确认死透：否则新进程报 Address in use，表面上"启动了"、实际服务的
/// 仍是旧进程——2026-10-14 技防列表搜索失效事故的根因。
///
/// 【进程匹配的两个坑，都已处理】
/// 1. **不能用 `pgrep -x server`**：Dart AOT 二进制的 comm 是 `dart:server`
///    （实测生产进程如此），按进程名精确匹配必然失配——脚本会误判"已停止"
///    却什么也没杀。改为按完整命令行匹配：整行等于 `./server`（相对路径启动）
///    或以 `/server` 结尾（绝对路径启动）。
/// 2. **pkill -f 模式不能匹配到脚本自身**：执行脚本的 bash 命令行里包含
///    模式文本，`pkill -f 'setsid nohup ./server'` 会把执行者自己杀掉。
///    清理包装进程处用 `./[s]erver` 的经典自排除写法。
/// 另外"是否死透"以端口是否释放为最终判据，比进程名更可靠。
String buildStopScript(int port) => <String>[
      "pat='(^\\./server\$)|(^/[^ ]*/server\$)'",
      // 清理历史遗留的 ssh 包装进程（手工部署留下的 bash -c ... ./server）
      r"pkill -f 'setsid nohup ./[s]erver' 2>/dev/null || true",
      r'pkill -f "$pat" 2>/dev/null || true',
      'sleep 2',
      'if pgrep -f "\$pat" >/dev/null 2>&1 || ss -ltn 2>/dev/null | grep -q ":$port "; '
          'then pkill -9 -f "\$pat" 2>/dev/null || true; sleep 1; fi',
      'if pgrep -f "\$pat" >/dev/null 2>&1 || ss -ltn 2>/dev/null | grep -q ":$port "; '
          'then echo "旧进程未停止（端口 $port 仍被占用），中止部署"; exit 1; fi',
      'echo "旧后端进程已停止（端口 $port 已释放）"',
      'exit 0',
    ].join('; ');

/// 构造「备份旧二进制」的远程脚本，供启动失败时回滚。
String buildBackupScript(String binDir) => <String>[
      'cd $binDir',
      r'if [ -f server ]; then cp -f server server.bak.$(date +%Y%m%d-%H%M%S) && echo "已备份旧版本: $(ls -t server.bak.* 2>/dev/null | head -1)"; else echo "未找到旧 server，跳过备份"; fi',
      'exit 0',
    ].join('; ');

/// 构造「启动后端 + 健康检查」的远程脚本。
///
/// 启动命令经 base64 编码传递，避开多层 shell 引号嵌套问题；
/// setsid + nohup + 重定向让进程脱离 ssh 会话，否则 ssh 会一直挂住不返回。
/// 健康检查先等 2 秒，再最多 20 次每秒探测端口（ss 为主，curl 兜底）。
String buildStartScript(String startCmd, int port) {
  final encoded = base64Encode(utf8.encode(startCmd.trim()));
  return <String>[
    'setsid nohup bash -c "\$(echo \'$encoded\' | base64 -d)" '
        '>>$remoteServerLog 2>&1 </dev/null & sleep 2',
    'for i in \$(seq 1 20); do '
        'if ss -ltn 2>/dev/null | grep -q ":$port " '
        '|| curl -s -o /dev/null --max-time 2 http://127.0.0.1:$port/; then '
        'echo "健康检查通过: 端口 $port 已监听（第 \${i} 次检查）"; '
        'echo "进程 PID: \$(pgrep -f \'(^\\./server\$)|(^/[^ ]*/server\$)\' | tr \'\\n\' \' \')"; '
        'exit 0; fi; sleep 1; done',
    'echo "健康检查失败: 端口 $port 在 22 秒内未监听"',
    'echo "--- 启动日志尾部 ($remoteServerLog) ---"',
    'tail -20 $remoteServerLog 2>/dev/null || true',
    'exit 1',
  ].join('; ');
}

Future<bool> _stopRemoteServer(
  TaskConfig cfg,
  String sshUser,
  void Function(String) addLog,
) {
  return sshRunCmd(cfg.ftpHost, sshUser, buildStopScript(cfg.serverPort),
      'SSH 停止旧后端进程', addLog);
}

Future<bool> _backupRemoteBinary(
  TaskConfig cfg,
  String sshUser,
  void Function(String) addLog,
) {
  final binDir = parseBackendBinDir(cfg.serverStartCmd);
  if (binDir == null) {
    addLog('无法从启动命令解析后端目录，跳过旧版本备份\n');
    return Future.value(true);
  }
  return sshRunCmd(cfg.ftpHost, sshUser, buildBackupScript(binDir),
      'SSH 备份旧后端二进制', addLog);
}

Future<bool> _startRemoteServer(
  TaskConfig cfg,
  String sshUser,
  void Function(String) addLog,
) {
  return sshRunCmd(
    cfg.ftpHost,
    sshUser,
    buildStartScript(cfg.serverStartCmd, cfg.serverPort),
    'SSH 启动新后端并健康检查',
    addLog,
  );
}

/// 功能 2：dart compile exe 并通过 FTP 上传到远程后端目录，再 SSH 重启服务。
///
/// 流程：编译 → 停止旧进程 → 备份 → 上传 → 赋权 → 启动 → 健康检查。
/// 只有配置了 [TaskConfig.serverStartCmd] 才会执行远程启停；未配置时退化为
/// 仅上传文件（并在日志中提示服务不会被重启）。
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

  final sshUser = cfg.sshUser.isNotEmpty ? cfg.sshUser : cfg.ftpUser;
  final startCmd = cfg.serverStartCmd.trim();
  final canRestart = startCmd.isNotEmpty;
  if (!canRestart) {
    addLog(
      '未配置后端启动命令（serverStartCmd），将只上传文件、不重启服务。\n'
      '注意：远程进程会继续运行旧代码，新功能不会生效。\n',
    );
  }

  // ── 1. 停止旧进程并备份（上传前，避免覆盖正在执行的文件）──────────────
  if (canRestart) {
    if (!await _stopRemoteServer(cfg, sshUser, addLog)) {
      addLog(
        '后端部署中止：旧进程未能停止，未上传新文件（服务仍在运行旧版本）。\n'
        '请登录服务器手动排查残留进程后重试。\n',
      );
      return;
    }
    await _backupRemoteBinary(cfg, sshUser, addLog);
  }

  // ── 2. 上传二进制与配置 ────────────────────────────────────────────────
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
    if (!ok) {
      addLog('二进制上传失败，服务当前处于停止状态，请检查后重新部署！\n');
      return;
    }

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
  } finally {
    try {
      await ftp.disconnect();
    } catch (_) {}
  }

  // ── 3. 启动并健康检查 ──────────────────────────────────────────────────
  if (canRestart) {
    if (!await _startRemoteServer(cfg, sshUser, addLog)) {
      final binDir = parseBackendBinDir(startCmd) ?? '<后端目录>';
      addLog(
        '新后端启动失败！服务当前不可用，请立即处理：\n'
        '  1) 查看启动日志：ssh $sshUser@${cfg.ftpHost} "tail -50 $remoteServerLog"\n'
        '  2) 回滚到备份版本：cd $binDir && cp -f server.bak.<时间戳> server，再手动启动\n'
        '  常用备份：ssh $sshUser@${cfg.ftpHost} "ls -t $binDir/server.bak.* | head -3"\n',
      );
      return;
    }
    addLog(
      '后端部署完成！（重启会使已登录用户的会话失效，需重新登录一次）\n',
    );
    return;
  }

  addLog('后端部署完成！\n');
}
