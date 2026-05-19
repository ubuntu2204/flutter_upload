import 'dart:io';

/// 在本地 [workingDir] 执行 [cmd] + [args]，记录日志到 [addLog]。
Future<bool> runCmd(
  String cmd,
  List<String> args,
  String workingDir,
  String desc,
  void Function(String) addLog,
) async {
  final fullCommand = '$cmd ${args.join(' ')}';
  final startTime = DateTime.now().toString().split('.').first;
  addLog('----------------------------------------\n'
      '开始: $startTime\n'
      '任务: $desc\n'
      '目录: $workingDir\n'
      '命令: $fullCommand\n');
  try {
    final result = await Process.run(cmd, args,
        workingDirectory: workingDir, runInShell: true);
    String log =
        '结果: ${result.exitCode == 0 ? '成功' : '失败'} (退出码: ${result.exitCode})\n';
    if (result.stdout.toString().trim().isNotEmpty) {
      log += '标准输出:\n${result.stdout}\n';
    }
    if (result.stderr.toString().trim().isNotEmpty) {
      log += '标准错误:\n${result.stderr}\n';
    }
    addLog(log);
    return result.exitCode == 0;
  } catch (e) {
    addLog('异常发生: $e\n');
    return false;
  }
}

/// 通过 SSH 在 [host] 上以 [user] 身份执行 [remoteCmd]。
/// [connectTimeout] 单位秒，默认 10。
Future<bool> sshRunCmd(
  String host,
  String user,
  String remoteCmd,
  String desc,
  void Function(String) addLog, {
  int connectTimeout = 10,
}) async {
  final startTime = DateTime.now().toString().split('.').first;
  addLog('----------------------------------------\n'
      '开始: $startTime\n'
      '任务: $desc\n'
      '命令: ssh $user@$host \'$remoteCmd\'\n');
  try {
    final result = await Process.run('ssh', [
      '-o',
      'StrictHostKeyChecking=no',
      '-o',
      'BatchMode=yes',
      '-o',
      'ConnectTimeout=$connectTimeout',
      '$user@$host',
      remoteCmd,
    ]);
    String log =
        '结果: ${result.exitCode == 0 ? '成功' : '失败'} (退出码: ${result.exitCode})\n';
    if (result.stdout.toString().trim().isNotEmpty) {
      log += '标准输出:\n${result.stdout}\n';
    }
    if (result.stderr.toString().trim().isNotEmpty) {
      log += '标准错误:\n${result.stderr}\n';
    }
    addLog(log);
    return result.exitCode == 0;
  } catch (e) {
    addLog('异常发生: $e\n');
    return false;
  }
}
