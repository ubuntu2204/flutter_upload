import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ftpconnect/ftpconnect.dart';
import 'config.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter 打包上传助手',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const UploadHomePage(),
    );
  }
}

class UploadHomePage extends StatefulWidget {
  const UploadHomePage({super.key});

  @override
  State<UploadHomePage> createState() => _UploadHomePageState();
}

class _UploadHomePageState extends State<UploadHomePage> {
  bool _isConnected = false;
  bool _isProcessing = false;
  String _log = "等待操作...";
  Timer? _timer;
  late final TextEditingController _ftpHostController;
  late final TextEditingController _ftpPortController;
  late final TextEditingController _ftpUserController;
  late final TextEditingController _ftpPassController;
  late final TextEditingController _ftpFrontendDirController;
  late final TextEditingController _ftpBackendDirController;
  late final TextEditingController _frontendPathController;
  late final TextEditingController _backendPathController;

  String get _ftpHost => _ftpHostController.text.trim();
  int get _ftpPort => int.tryParse(_ftpPortController.text.trim()) ?? 21;
  String get _ftpUser => _ftpUserController.text.trim();
  String get _ftpPass => _ftpPassController.text;
  String get _ftpFrontendDir =>
      _ftpFrontendDirController.text.trim().replaceAll('\\', '/');
  String get _ftpBackendDir =>
      _ftpBackendDirController.text.trim().replaceAll('\\', '/');
  String get _frontendPath => _expandHome(_frontendPathController.text.trim());
  String get _backendPath => _expandHome(_backendPathController.text.trim());

  String _expandHome(String path) {
    if (path.startsWith('~/')) {
      return '${Platform.environment['HOME'] ?? ''}${path.substring(1)}';
    }
    return path;
  }

  @override
  void initState() {
    super.initState();
    _ftpHostController = TextEditingController();
    _ftpPortController = TextEditingController();
    _ftpUserController = TextEditingController();
    _ftpPassController = TextEditingController();
    _ftpFrontendDirController = TextEditingController();
    _ftpBackendDirController = TextEditingController();
    _frontendPathController = TextEditingController();
    _backendPathController = TextEditingController();
    _loadFtpConfig();
    _checkConnectivity();
    // 每 5 秒自动检测一次联通性
    _timer =
        Timer.periodic(const Duration(seconds: 5), (_) => _checkConnectivity());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ftpHostController.dispose();
    _ftpPortController.dispose();
    _ftpUserController.dispose();
    _ftpPassController.dispose();
    _ftpFrontendDirController.dispose();
    _ftpBackendDirController.dispose();
    _frontendPathController.dispose();
    _backendPathController.dispose();
    super.dispose();
  }

  // 检测服务器联通性 (ping 192.168.77.2)
  Future<void> _checkConnectivity() async {
    try {
      final result =
          await Process.run('ping', ['-c', '1', '-W', '1', _ftpHost]);
      if (mounted) {
        setState(() {
          _isConnected = (result.exitCode == 0);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isConnected = false);
      }
    }
  }

  void _addLog(String message) {
    if (mounted) {
      setState(() {
        _log = "${DateTime.now().toString().split('.').first}: $message\n$_log";
      });
    }
  }

  // 通用的执行命令函数
  Future<bool> _runCmd(
      String cmd, List<String> args, String workingDir, String desc) async {
    final fullCommand = "$cmd ${args.join(' ')}";
    final startTime = DateTime.now().toString().split('.').first;

    String cmdLog = "----------------------------------------\n"
        "开始: $startTime\n"
        "任务: $desc\n"
        "目录: $workingDir\n"
        "命令: $fullCommand\n";
    _addLog(cmdLog);

    try {
      final result = await Process.run(cmd, args,
          workingDirectory: workingDir, runInShell: true);

      String resultLog =
          "结果: ${result.exitCode == 0 ? '成功' : '失败'} (退出码: ${result.exitCode})\n";

      if (result.stdout.toString().trim().isNotEmpty) {
        resultLog += "标准输出:\n${result.stdout}\n";
      }
      if (result.stderr.toString().trim().isNotEmpty) {
        resultLog += "标准错误:\n${result.stderr}\n";
      }

      _addLog(resultLog);
      return result.exitCode == 0;
    } catch (e) {
      _addLog("异常发生: $e\n");
      return false;
    }
  }

  Future<void> _loadFtpConfig() async {
    final file = File(AppConfig.ftpConfigPath);
    if (!await file.exists()) {
      _addLog("未找到配置文件: ${file.path}\n");
      return;
    }

    try {
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        _addLog("配置文件格式错误：必须是 JSON 对象\n");
        return;
      }

      final host = (decoded['host'] ?? '').toString().trim();
      final port = int.tryParse((decoded['port'] ?? '').toString().trim());
      final user = (decoded['user'] ?? '').toString();
      final pass = (decoded['pass'] ?? '').toString();
      final frontendDir = (decoded['frontendDir'] ?? '').toString();
      final backendDir = (decoded['backendDir'] ?? '').toString();
      final frontendPath = (decoded['frontendPath'] ?? '').toString();
      final backendPath = (decoded['backendPath'] ?? '').toString();

      if (host.isNotEmpty) _ftpHostController.text = host;
      if (port != null) _ftpPortController.text = port.toString();
      if (user.isNotEmpty) _ftpUserController.text = user;
      if (pass.isNotEmpty) _ftpPassController.text = pass;
      if (frontendDir.isNotEmpty) _ftpFrontendDirController.text = frontendDir;
      if (backendDir.isNotEmpty) _ftpBackendDirController.text = backendDir;
      if (frontendPath.isNotEmpty) _frontendPathController.text = frontendPath;
      if (backendPath.isNotEmpty) _backendPathController.text = backendPath;

      _addLog(
        "已加载配置文件: ${file.path}\n"
        "FTP: ${_ftpHostController.text.trim()}:${_ftpPortController.text.trim()}\n"
        "前端路径: ${_frontendPathController.text.trim()}\n"
        "前端目录: ${_ftpFrontendDirController.text.trim()}\n"
        "后端路径: ${_backendPathController.text.trim()}\n"
        "后端目录: ${_ftpBackendDirController.text.trim()}\n",
      );
    } catch (e) {
      _addLog("读取配置文件失败: $e\n");
    }
  }

  Future<void> _saveFtpConfig() async {
    final file = File(AppConfig.ftpConfigPath);
    final config = <String, dynamic>{
      'host': _ftpHostController.text.trim(),
      'port': _ftpPort,
      'user': _ftpUserController.text.trim(),
      'pass': _ftpPassController.text,
      'frontendPath': _frontendPathController.text.trim(),
      'frontendDir': _ftpFrontendDirController.text.trim(),
      'backendPath': _backendPathController.text.trim(),
      'backendDir': _ftpBackendDirController.text.trim(),
    };
    try {
      final encoder = const JsonEncoder.withIndent('  ');
      await file.writeAsString('${encoder.convert(config)}\n');
      _addLog("配置已保存: ${file.path}\n");
    } catch (e) {
      _addLog("保存配置失败: $e\n");
    }
  }

  Future<FTPConnect?> _connectFtp() async {
    if (_ftpUser.isEmpty || _ftpPass.isEmpty) {
      _addLog("FTP 用户名或密码为空，请先在 FTP 设置中填写。\n");
      return null;
    }

    final startTime = DateTime.now().toString().split('.').first;
    _addLog("----------------------------------------\n"
        "开始: $startTime\n"
        "任务: FTP 连接\n"
        "主机: $_ftpHost:$_ftpPort\n"
        "用户: $_ftpUser\n");

    final ftp = FTPConnect(
      _ftpHost,
      port: _ftpPort,
      user: _ftpUser,
      pass: _ftpPass,
      timeout: 30,
    );

    try {
      final ok = await ftp.connect();
      _addLog("结果: ${ok ? '成功' : '失败'}\n");
      if (!ok) return null;
      await ftp.setTransferType(TransferType.binary);
      return ftp;
    } catch (e) {
      _addLog("异常发生: $e\n");
      return null;
    }
  }

  /// 静默连接 FTP（供并行上传使用，不打印日志）
  Future<FTPConnect?> _connectFtpQuiet() async {
    if (_ftpUser.isEmpty || _ftpPass.isEmpty) return null;
    final ftp = FTPConnect(
      _ftpHost,
      port: _ftpPort,
      user: _ftpUser,
      pass: _ftpPass,
      timeout: 30,
    );
    try {
      final ok = await ftp.connect();
      if (!ok) return null;
      await ftp.setTransferType(TransferType.binary);
      return ftp;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _ftpCwdCreate(FTPConnect ftp, String remoteDir,
      {bool silent = false}) async {
    final normalized = remoteDir.trim().replaceAll('\\', '/');
    final segments = normalized.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return true;

    for (final seg in segments) {
      try {
        bool changed = await ftp.changeDirectory(seg);
        if (!changed) {
          try {
            await ftp.makeDirectory(seg);
          } catch (_) {
            // 目录可能已存在，忽略创建失败，继续尝试进入
          }
          changed = await ftp.changeDirectory(seg);
          if (!changed) {
            if (!silent) _addLog("FTP 进入目录失败: $seg\n");
            return false;
          }
        }
        if (!silent) _addLog("FTP 进入目录: $seg\n");
      } catch (e) {
        if (!silent) _addLog("FTP 处理目录失败 ($seg): $e\n");
        return false;
      }
    }
    return true;
  }

  /// 并行上传本地目录到远程（多 FTP 连接加速）
  Future<bool> _ftpUploadDirectoryParallel(
      Directory localDir, String remoteBaseDir,
      {int concurrency = 4}) async {
    if (!await localDir.exists()) {
      _addLog("本地目录不存在: ${localDir.path}\n");
      return false;
    }

    final startTime = DateTime.now().toString().split('.').first;
    _addLog("----------------------------------------\n"
        "开始: $startTime\n"
        "任务: FTP 并行上传目录 (并发数: $concurrency)\n"
        "本地: ${localDir.path}\n"
        "远程: $remoteBaseDir\n");

    // 收集所有文件
    final basePath = localDir.path;
    final allFiles = <File>[];
    await for (final entity
        in localDir.list(recursive: true, followLinks: false)) {
      if (entity is File) allFiles.add(entity);
    }

    _addLog("共 ${allFiles.length} 个文件，开始并行上传...\n");

    // 均分文件给各并行连接
    final groups = List.generate(concurrency, (_) => <File>[]);
    for (int i = 0; i < allFiles.length; i++) {
      groups[i % concurrency].add(allFiles[i]);
    }

    final futures = groups.where((g) => g.isNotEmpty).map((group) async {
      final ftp = await _connectFtpQuiet();
      if (ftp == null) {
        _addLog("并行连接失败，${group.length} 个文件跳过\n");
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

          // 每个文件从根目录重新导航，确保并发安全
          try {
            await ftp.changeDirectory('/');
          } catch (_) {}
          bool navOk = await _ftpCwdCreate(ftp, remoteBaseDir, silent: true);
          if (navOk && parentRel.isNotEmpty) {
            navOk = await _ftpCwdCreate(ftp, parentRel, silent: true);
          }
          if (!navOk) {
            _addLog("导航失败: $relNormalized\n");
            fail++;
            continue;
          }

          try {
            await ftp.deleteFile(fileName);
          } catch (_) {}

          bool uploaded = false;
          try {
            uploaded = await ftp.uploadFileWithRetry(
              file,
              pRemoteName: fileName,
              pRetryCount: 2,
            );
          } catch (e) {
            _addLog("上传异常: $relNormalized - $e\n");
          }

          if (uploaded) {
            ok++;
          } else {
            fail++;
            _addLog("上传失败: $relNormalized\n");
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

    _addLog("目录上传完成: 成功 $totalOk, 失败 $totalFail\n");
    return totalFail == 0;
  }

  Future<bool> _ftpUploadSingleFile(FTPConnect ftp, File localFile,
      String remoteDir, String remoteName) async {
    if (!await localFile.exists()) {
      _addLog("本地文件不存在: ${localFile.path}\n");
      return false;
    }

    final startTime = DateTime.now().toString().split('.').first;
    _addLog("----------------------------------------\n"
        "开始: $startTime\n"
        "任务: FTP 上传文件\n"
        "本地: ${localFile.path}\n"
        "远程目录: $remoteDir\n"
        "远程文件名: $remoteName\n");

    try {
      await ftp.changeDirectory('/');
    } catch (_) {}

    final entered = await _ftpCwdCreate(ftp, remoteDir);
    if (!entered) return false;

    try {
      // 覆盖：先删除远程同名文件（不存在时忽略）
      try {
        await ftp.deleteFile(remoteName);
      } catch (_) {}

      final ok = await ftp.uploadFileWithRetry(
        localFile,
        pRemoteName: remoteName,
        pRetryCount: 2,
      );
      _addLog("结果: ${ok ? '成功' : '失败'}\n");
      return ok;
    } catch (e) {
      _addLog("异常发生: $e\n");
      return false;
    }
  }

  // 功能 1：打包并上传前端
  Future<void> _handleFrontend() async {
    setState(() => _isProcessing = true);
    _addLog("--- 开始前端流程 ---");

    bool built = await _runCmd(
        'flutter', ['build', 'web'], _frontendPath, "Flutter Web 构建");
    if (built) {
      final ok = await _ftpUploadDirectoryParallel(
        Directory("$_frontendPath/build/web"),
        _ftpFrontendDir,
      );
      if (ok) _addLog("前端部署完成！\n");
    }

    setState(() => _isProcessing = false);
  }

  // 功能 2：打包并上传后端
  Future<void> _handleBackend() async {
    setState(() => _isProcessing = true);
    _addLog("--- 开始后端流程 ---");

    // 1. 构建 Dart 可执行文件
    // 将 bin/server.dart 编译为 bin/server 可执行文件
    bool built = await _runCmd(
        'dart',
        ['compile', 'exe', 'bin/server.dart', '-o', 'bin/server'],
        _backendPath,
        "Dart 后端构建");

    if (built) {
      final ftp = await _connectFtp();
      if (ftp == null) {
        setState(() => _isProcessing = false);
        return;
      }

      try {
        final ok = await _ftpUploadSingleFile(
          ftp,
          File("$_backendPath/bin/server"),
          _ftpBackendDir,
          'server',
        );
        if (ok) {
          // 给上传的文件添加可执行权限
          try {
            await ftp.changeDirectory('/');
            await _ftpCwdCreate(ftp, _ftpBackendDir);
            final chmodReply =
                await ftp.sendCustomCommand('SITE CHMOD 755 server');
            _addLog("设置可执行权限: ${chmodReply.message}\n");
          } catch (e) {
            _addLog("设置可执行权限失败: $e\n");
          }
          _addLog("后端部署完成！\n");
        }
      } finally {
        try {
          await ftp.disconnect();
        } catch (_) {}
      }
    }

    setState(() => _isProcessing = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('打包上传助手'),
        actions: [
          IconButton(
            onPressed: () => setState(() => _log = "日志已清空"),
            icon: const Icon(Icons.delete_sweep),
            tooltip: "清空日志",
          ),
          Row(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _isConnected ? Colors.green : Colors.red,
                  boxShadow: [
                    if (_isConnected)
                      BoxShadow(
                          color: Colors.green.withOpacity(0.4),
                          blurRadius: 4,
                          spreadRadius: 2)
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(_isConnected ? "$_ftpHost 在线" : "服务器离线",
                  style: TextStyle(
                      color: _isConnected ? Colors.green : Colors.red,
                      fontSize: 13)),
              const SizedBox(width: 16),
            ],
          )
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          children: [
            ExpansionTile(
              title: const Text('FTP 设置'),
              children: [
                TextField(
                  controller: _ftpHostController,
                  decoration: const InputDecoration(labelText: 'FTP 主机'),
                  onChanged: (_) => _checkConnectivity(),
                ),
                TextField(
                  controller: _ftpPortController,
                  decoration: const InputDecoration(labelText: 'FTP 端口'),
                  keyboardType: TextInputType.number,
                ),
                TextField(
                  controller: _ftpUserController,
                  decoration: const InputDecoration(labelText: 'FTP 用户名'),
                ),
                TextField(
                  controller: _ftpPassController,
                  decoration: const InputDecoration(labelText: 'FTP 密码'),
                  obscureText: true,
                ),
                TextField(
                  controller: _frontendPathController,
                  decoration: const InputDecoration(labelText: '前端本地路径'),
                ),
                TextField(
                  controller: _ftpFrontendDirController,
                  decoration: const InputDecoration(labelText: '前端远程目录'),
                ),
                TextField(
                  controller: _backendPathController,
                  decoration: const InputDecoration(labelText: '后端本地路径'),
                ),
                TextField(
                  controller: _ftpBackendDirController,
                  decoration: const InputDecoration(labelText: '后端远程目录'),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: ElevatedButton.icon(
                    onPressed: _saveFtpConfig,
                    icon: const Icon(Icons.save),
                    label: const Text('保存配置'),
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: (_isConnected && !_isProcessing)
                        ? _handleFrontend
                        : null,
                    icon: const Icon(Icons.cloud_upload),
                    label: const Text("上传前端"),
                    style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 20)),
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: (_isConnected && !_isProcessing)
                        ? _handleBackend
                        : null,
                    icon: const Icon(Icons.storage),
                    label: const Text("上传后端并赋权"),
                    style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 20)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (_isProcessing) const LinearProgressIndicator(),
            const SizedBox(height: 20),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    "运行日志:",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: _log));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('日志已复制到剪贴板')),
                    );
                  },
                  icon: const Icon(Icons.copy),
                  tooltip: "复制全部",
                ),
              ],
            ),
            const SizedBox(height: 10),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectionArea(
                  child: SingleChildScrollView(
                    child: SelectableText(
                      _log,
                      style: const TextStyle(
                        color: Colors.greenAccent,
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
