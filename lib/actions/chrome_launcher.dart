import 'dart:io';

/// 专用 Chrome 的调试端口。使用独立端口，避免影响用户日常 Chrome。
const int chromeDebugPort = 9222;

/// 房产平台登录页 / 可视化页面。
const String platformLoginUrl = 'http://210.30.202.99/house/auth/login';
const String platformCampusUrl =
    'http://210.30.202.99/house/house-base-decision/personal/visual/campus';

/// 专用 Chrome 的配置目录（登录态会保留在这里）。
String chromeProfileDir() {
  final home = Platform.environment['HOME'] ?? Directory.current.path;
  return '$home/.config/flutter_upload/chrome-profile';
}

/// 检查 Chrome 调试端口是否已经可用。
Future<bool> isChromeDebugReady({int port = chromeDebugPort}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  try {
    final request =
        await client.getUrl(Uri.parse('http://127.0.0.1:$port/json/version'));
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode == 200;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}

/// 查找本机 Chrome 可执行文件。
Future<String?> findChromeExecutable() async {
  final configured = Platform.environment['CHROME_EXECUTABLE'];
  if (configured != null && configured.trim().isNotEmpty) {
    if (await File(configured).exists()) return configured;
  }
  for (final candidate in const [
    '/usr/bin/google-chrome',
    '/usr/bin/google-chrome-stable',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser',
    '/snap/bin/chromium',
  ]) {
    if (await File(candidate).exists()) return candidate;
  }
  for (final name in const [
    'google-chrome',
    'google-chrome-stable',
    'chromium',
    'chromium-browser',
  ]) {
    try {
      final result = await Process.run(
        'which',
        [name],
        workingDirectory: _safeWorkingDirectory(),
      );
      if (result.exitCode == 0) {
        final path = result.stdout.toString().trim();
        if (path.isNotEmpty) return path;
      }
    } catch (_) {}
  }
  return null;
}

String _safeWorkingDirectory() {
  final home = Platform.environment['HOME'];
  if (home != null && Directory(home).existsSync()) return home;
  return Directory.systemTemp.path;
}

/// 确保专用 Chrome 正在运行且开启了调试端口；首次调用会打开登录页。
///
/// 返回 true 表示复用了已有实例，false 表示本次新启动。
Future<bool> ensureChromeRunning({
  int port = chromeDebugPort,
  String initialUrl = platformLoginUrl,
  void Function(String) addLog = _noopLog,
}) async {
  if (await isChromeDebugReady(port: port)) {
    addLog('已连接 Chrome 调试端口 $port\n');
    return true;
  }

  final executable = await findChromeExecutable();
  if (executable == null) {
    throw ChromeLaunchException(
        '未找到 Chrome。请安装 google-chrome，或设置 CHROME_EXECUTABLE 环境变量。');
  }

  final profile = chromeProfileDir();
  await Directory(profile).create(recursive: true);

  addLog('启动专用 Chrome: $executable\n');
  addLog('配置目录: $profile\n');
  try {
    await Process.start(
      executable,
      [
        '--remote-debugging-port=$port',
        '--user-data-dir=$profile',
        '--no-first-run',
        '--no-default-browser-check',
        '--remote-allow-origins=*',
        '--new-window',
        initialUrl,
      ],
      mode: ProcessStartMode.detached,
      workingDirectory: _safeWorkingDirectory(),
    );
  } catch (e) {
    throw ChromeLaunchException('启动 Chrome 失败: $e');
  }

  for (var i = 0; i < 40; i++) {
    await Future.delayed(const Duration(milliseconds: 500));
    if (await isChromeDebugReady(port: port)) {
      addLog('Chrome 调试端口已就绪: $port\n');
      return false;
    }
  }

  throw ChromeLaunchException('Chrome 调试端口 $port 未就绪。若专用 Chrome 已经打开但没有调试端口，'
      '请先关闭它再重试；也可以检查是否被其他 Chrome 实例占用。');
}

void _noopLog(String _) {}

class ChromeLaunchException implements Exception {
  final String message;

  const ChromeLaunchException(this.message);

  @override
  String toString() => message;
}
