import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'config.dart';
import 'actions/task_config.dart';
import 'actions/frontend_action.dart';
import 'actions/backend_action.dart';
import 'actions/mobile_action.dart';
import 'actions/mobile_rename_action.dart';
import 'actions/vpn_action.dart';
import 'actions/windows_push_action.dart';
import 'settings_page.dart';

void main(List<String> args) {
  for (int i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg.startsWith('--config=')) {
      AppConfig.ftpConfigPath = arg.substring('--config='.length);
      break;
    } else if (arg == '--config' && i + 1 < args.length) {
      AppConfig.ftpConfigPath = args[i + 1];
      break;
    }
  }
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
  late final TextEditingController _sshUserController;
  late final TextEditingController _serverStartCmdController;
  late final TextEditingController _mobilePathController;
  late final TextEditingController _maintenancePathController;
  late final TextEditingController _windowsSshHostController;
  late final TextEditingController _windowsSshUserController;
  late final TextEditingController _windowsRemotePathController;

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
  String get _sshUser => _sshUserController.text.trim();
  String get _serverStartCmd => _serverStartCmdController.text.trim();
  String get _mobilePath => _expandHome(_mobilePathController.text.trim());
  String get _maintenancePath =>
      _expandHome(_maintenancePathController.text.trim());
  String get _windowsSshHost => _windowsSshHostController.text.trim();
  String get _windowsSshUser => _windowsSshUserController.text.trim();
  String get _windowsRemotePath => _windowsRemotePathController.text.trim();

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
    _sshUserController = TextEditingController();
    _serverStartCmdController = TextEditingController();
    _mobilePathController = TextEditingController();
    _maintenancePathController = TextEditingController();
    _windowsSshHostController = TextEditingController();
    _windowsSshUserController = TextEditingController();
    _windowsRemotePathController = TextEditingController();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _loadFtpConfig();
      if (!mounted) return;
      if (_ftpHost.isNotEmpty) _checkConnectivity();
      _timer = Timer.periodic(const Duration(seconds: 5), (_) {
        if (_ftpHost.isNotEmpty) _checkConnectivity();
      });
    });
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
    _sshUserController.dispose();
    _serverStartCmdController.dispose();
    _mobilePathController.dispose();
    _maintenancePathController.dispose();
    _windowsSshHostController.dispose();
    _windowsSshUserController.dispose();
    _windowsRemotePathController.dispose();
    super.dispose();
  }

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
      if (mounted) setState(() => _isConnected = false);
    }
  }

  void _addLog(String message) {
    if (mounted) {
      setState(() {
        _log = "${DateTime.now().toString().split('.').first}: $message\n$_log";
      });
    }
  }

  TaskConfig _buildConfig() => TaskConfig(
        ftpHost: _ftpHost,
        ftpPort: _ftpPort,
        ftpUser: _ftpUser,
        ftpPass: _ftpPass,
        ftpFrontendDir: _ftpFrontendDir,
        ftpBackendDir: _ftpBackendDir,
        frontendPath: _frontendPath,
        backendPath: _backendPath,
        sshUser: _sshUser,
        serverStartCmd: _serverStartCmd,
        mobilePath: _mobilePath,
        maintenancePath: _maintenancePath,
        windowsSshHost: _windowsSshHost,
        windowsSshUser: _windowsSshUser,
        windowsRemotePath: _windowsRemotePath,
      );

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
      final sshUser = (decoded['sshUser'] ?? '').toString();
      final serverStartCmd = (decoded['serverStartCmd'] ?? '').toString();
      final mobilePath = (decoded['mobilePath'] ?? '').toString();
      if (sshUser.isNotEmpty) _sshUserController.text = sshUser;
      if (serverStartCmd.isNotEmpty) {
        _serverStartCmdController.text = serverStartCmd;
      }
      if (mobilePath.isNotEmpty) _mobilePathController.text = mobilePath;
      final maintenancePath = (decoded['maintenancePath'] ?? '').toString();
      final windowsSshHost = (decoded['windowsSshHost'] ?? '').toString();
      final windowsSshUser = (decoded['windowsSshUser'] ?? '').toString();
      final windowsRemotePath = (decoded['windowsRemotePath'] ?? '').toString();
      if (maintenancePath.isNotEmpty)
        _maintenancePathController.text = maintenancePath;
      if (windowsSshHost.isNotEmpty)
        _windowsSshHostController.text = windowsSshHost;
      if (windowsSshUser.isNotEmpty)
        _windowsSshUserController.text = windowsSshUser;
      if (windowsRemotePath.isNotEmpty)
        _windowsRemotePathController.text = windowsRemotePath;
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
      'sshUser': _sshUserController.text.trim(),
      'serverStartCmd': _serverStartCmdController.text.trim(),
      'mobilePath': _mobilePathController.text.trim(),
      'maintenancePath': _maintenancePathController.text.trim(),
      'windowsSshHost': _windowsSshHostController.text.trim(),
      'windowsSshUser': _windowsSshUserController.text.trim(),
      'windowsRemotePath': _windowsRemotePathController.text.trim(),
    };
    try {
      final encoder = const JsonEncoder.withIndent('  ');
      await file.writeAsString('${encoder.convert(config)}\n');
      _addLog("配置已保存: ${file.path}\n");
    } catch (e) {
      _addLog("保存配置失败: $e\n");
    }
  }

  // ── 按钮 handler ──

  Future<void> _handleFrontend() async {
    setState(() => _isProcessing = true);
    await runFrontend(_buildConfig(), _addLog);
    setState(() => _isProcessing = false);
  }

  Future<void> _handleBackend() async {
    setState(() => _isProcessing = true);
    await runBackend(_buildConfig(), _addLog);
    setState(() => _isProcessing = false);
  }

  Future<void> _handleMobile() async {
    setState(() => _isProcessing = true);
    await runMobile(_buildConfig(), _addLog);
    setState(() => _isProcessing = false);
  }

  Future<void> _handleMobileRename() async {
    setState(() => _isProcessing = true);
    await runMobileRename(_buildConfig(), _addLog);
    setState(() => _isProcessing = false);
  }

  Future<void> _handleVpn() async {
    setState(() => _isProcessing = true);
    await runVpn(_buildConfig(), _addLog);
    setState(() => _isProcessing = false);
  }

  Future<void> _handleVpnSudoers() async {
    setState(() => _isProcessing = true);
    await setupVpnSudoers(_buildConfig(), _addLog);
    setState(() => _isProcessing = false);
  }

  Future<void> _handleWindowsPush() async {
    setState(() => _isProcessing = true);
    await runWindowsPush(_buildConfig(), _addLog);
    setState(() => _isProcessing = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('打包上传助手'),
        actions: [
          IconButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => SettingsPage(
                  ftpHostController: _ftpHostController,
                  ftpPortController: _ftpPortController,
                  ftpUserController: _ftpUserController,
                  ftpPassController: _ftpPassController,
                  ftpFrontendDirController: _ftpFrontendDirController,
                  ftpBackendDirController: _ftpBackendDirController,
                  frontendPathController: _frontendPathController,
                  backendPathController: _backendPathController,
                  sshUserController: _sshUserController,
                  serverStartCmdController: _serverStartCmdController,
                  mobilePathController: _mobilePathController,
                  maintenancePathController: _maintenancePathController,
                  windowsSshHostController: _windowsSshHostController,
                  windowsSshUserController: _windowsSshUserController,
                  windowsRemotePathController: _windowsRemotePathController,
                  onSave: _saveFtpConfig,
                  onVpnSudoers: _handleVpnSudoers,
                  onHostChanged: _checkConnectivity,
                ),
              ),
            ),
            icon: const Icon(Icons.settings),
            tooltip: "设置",
          ),
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
                          color: Colors.green.withValues(alpha: 0.4),
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
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: !_isProcessing ? _handleMobile : null,
                    icon: const Icon(Icons.phone_android),
                    label: const Text("部署到移动设备"),
                    style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        backgroundColor: Colors.green.shade700,
                        foregroundColor: Colors.white),
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: !_isProcessing ? _handleMobileRename : null,
                    icon: const Icon(Icons.drive_file_rename_outline),
                    label: const Text("打包重命名"),
                    style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        backgroundColor: Colors.orange.shade700,
                        foregroundColor: Colors.white),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: !_isProcessing ? _handleVpn : null,
                    icon: const Icon(Icons.vpn_lock),
                    label: const Text("连接 VPN1 + 路由"),
                    style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        backgroundColor: Colors.indigo.shade700,
                        foregroundColor: Colors.white),
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: !_isProcessing ? _handleWindowsPush : null,
                    icon: const Icon(Icons.desktop_windows),
                    label: const Text("推送至 Windows"),
                    style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        backgroundColor: Colors.blue.shade800,
                        foregroundColor: Colors.white),
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
