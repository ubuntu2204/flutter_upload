import 'dart:io';
import 'cmd_utils.dart';
import 'task_config.dart';

const _sudoersPath = '/etc/sudoers.d/vpn_nopasswd';
const _nmcliCmd = '/usr/bin/nmcli';
const _ipCmd = '/usr/sbin/ip';
const _vpnName = 'VPN 1';

/// 检查 sudoers NOPASSWD 是否已配置
/// 通过尝试 sudo -n 执行来验证，而非读取文件（440 权限下非 root 无法读取）
Future<bool> _isSudoersConfigured() async {
  final result = await Process.run('sudo', ['-n', _ipCmd, 'route']);
  return result.exitCode == 0;
}

/// 生成 sudoers 配置内容
String _sudoersContent() {
  final user = Platform.environment['USER'] ?? 'your_user';
  return '$user ALL=(ALL) NOPASSWD: $_nmcliCmd, $_ipCmd\n';
}

/// 配置 sudoers NOPASSWD
Future<void> setupVpnSudoers(
    TaskConfig cfg, void Function(String) addLog) async {
  addLog('--- 配置 VPN sudoers NOPASSWD ---');

  // 先检查是否已配置
  if (await _isSudoersConfigured()) {
    addLog('sudoers NOPASSWD 已配置，无需重复操作。\n');
    return;
  }

  final content = _sudoersContent();
  addLog('将写入以下内容到 $_sudoersPath :\n$content');

  // 生成需要执行的命令
  final setupCmd =
      'echo \'$content\' | sudo tee $_sudoersPath && sudo chmod 440 $_sudoersPath && echo 成功 && read -p 按回车关闭';

  // 弹出终端窗口让用户输入 sudo 密码
  addLog('正在打开终端窗口，请在终端中输入 sudo 密码完成配置...\n');
  await Process.run('gnome-terminal', [
    '--',
    'bash',
    '-c',
    setupCmd,
  ]);

  // gnome-terminal 启动后立即返回，等待用户在终端中操作
  // 给用户一些时间完成操作后检查结果
  await Future.delayed(const Duration(seconds: 2));
  bool configured = false;
  for (int i = 0; i < 15; i++) {
    await Future.delayed(const Duration(seconds: 2));
    if (await _isSudoersConfigured()) {
      configured = true;
      break;
    }
  }

  if (configured) {
    addLog('sudoers 配置完成！后续 VPN 连接将无需密码。\n');
  } else {
    addLog('未检测到配置成功，请确认是否在终端中完成了操作。\n'
        '也可手动在终端执行:\n'
        '  echo "${content.trim()}" | sudo tee $_sudoersPath\n'
        '  sudo chmod 440 $_sudoersPath\n');
  }
}

/// 连接 VPN1 并添加路由
Future<void> runVpn(TaskConfig cfg, void Function(String) addLog) async {
  addLog('--- 开始连接 VPN ---');

  // 检查 sudoers 是否已配置
  if (!await _isSudoersConfigured()) {
    addLog('未检测到 sudoers NOPASSWD 配置，请先点击「配置 VPN sudoers」按钮。\n');
    return;
  }

  // 连接 VPN（使用 NetworkManager，匹配 sudoers NOPASSWD 规则）
  final connected = await runCmd(
    'sudo',
    [_nmcliCmd, 'con', 'up', _vpnName],
    '/',
    '连接 $_vpnName',
    addLog,
  );
  if (!connected) {
    addLog('VPN 连接失败！\n');
    return;
  }

  // 等待 VPN 建立
  await Future.delayed(const Duration(seconds: 3));

  // 添加路由（使用完整路径以匹配 sudoers NOPASSWD 规则）
  await runCmd(
    'sudo',
    [_ipCmd, 'route', 'add', '192.168.77.0/24', 'dev', 'ppp0'],
    '/',
    '添加路由 192.168.77.0/24 -> ppp0',
    addLog,
  );

  addLog('VPN 流程完成！\n');
}
