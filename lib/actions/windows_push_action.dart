import 'cmd_utils.dart';
import 'task_config.dart';

/// 推送 maintenance 项目到 Windows 服务器：
/// 1. 本地 git add + commit 保存当前版本
/// 2. SSH 到 Windows 服务器，执行 git reset --hard HEAD + git pull
Future<void> runWindowsPush(
    TaskConfig cfg, void Function(String) addLog) async {
  addLog('--- 开始推送至 Windows ---\n');

  final maintenancePath = cfg.maintenancePath;
  if (maintenancePath.isEmpty) {
    addLog('错误: 未配置本地 maintenance 项目路径，请在设置中填写。\n');
    return;
  }
  if (cfg.windowsSshHost.isEmpty || cfg.windowsSshUser.isEmpty) {
    addLog('错误: 未配置 Windows SSH 连接信息，请在设置中填写。\n');
    return;
  }
  if (cfg.windowsRemotePath.isEmpty) {
    addLog('错误: 未配置 Windows 远程项目路径，请在设置中填写。\n');
    return;
  }

  // 步骤 1: 本地 git add . && git commit
  addLog('步骤 1/3: 在本地 maintenance 项目中执行 git commit...\n');
  final commitOk = await runCmd(
    'git',
    ['add', '.'],
    maintenancePath,
    'git add .',
    addLog,
  );
  if (!commitOk) {
    addLog('git add 失败，流程终止。\n');
    return;
  }

  final timestamp = DateTime.now().toString().split('.').first;
  final commitMsg = 'auto-save: $timestamp';
  final commitResult = await runCmd(
    'git',
    ['commit', '-m', commitMsg],
    maintenancePath,
    'git commit -m "$commitMsg"',
    addLog,
  );
  // commit 可能因为没有变更而失败（退出码 1），这不是致命错误，继续执行
  if (!commitResult) {
    addLog('提示: git commit 未产生新提交（可能没有变更），继续推送流程...\n');
  }

  // 步骤 2: SSH 到 Windows，执行 git reset --hard HEAD
  addLog('步骤 2/3: SSH 到 Windows 服务器，执行 git reset --hard HEAD...\n');
  final remoteCmdReset =
      'cd "${cfg.windowsRemotePath}" && git reset --hard HEAD';
  final resetOk = await sshStreamCmd(
    cfg.windowsSshHost,
    cfg.windowsSshUser,
    remoteCmdReset,
    '远程 git reset --hard HEAD',
    addLog,
  );
  if (!resetOk) {
    addLog('远程 git reset 失败，流程终止。\n');
    return;
  }

  // 步骤 3: SSH 到 Windows，执行 git pull
  addLog('步骤 3/3: SSH 到 Windows 服务器，执行 git pull...\n');
  final remoteCmdPull = 'cd "${cfg.windowsRemotePath}" && git pull';
  final pullOk = await sshStreamCmd(
    cfg.windowsSshHost,
    cfg.windowsSshUser,
    remoteCmdPull,
    '远程 git pull',
    addLog,
  );
  if (!pullOk) {
    addLog('远程 git pull 失败。\n');
    return;
  }

  addLog('--- 推送至 Windows 完成 ---\n');
}
