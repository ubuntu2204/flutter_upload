import 'package:flutter/material.dart';

class SettingsPage extends StatefulWidget {
  final TextEditingController ftpHostController;
  final TextEditingController ftpPortController;
  final TextEditingController ftpUserController;
  final TextEditingController ftpPassController;
  final TextEditingController ftpFrontendDirController;
  final TextEditingController ftpBackendDirController;
  final TextEditingController frontendPathController;
  final TextEditingController backendPathController;
  final TextEditingController sshUserController;
  final TextEditingController serverStartCmdController;
  final TextEditingController mobilePathController;

  final Future<void> Function() onSave;
  final VoidCallback onHostChanged;

  const SettingsPage({
    super.key,
    required this.ftpHostController,
    required this.ftpPortController,
    required this.ftpUserController,
    required this.ftpPassController,
    required this.ftpFrontendDirController,
    required this.ftpBackendDirController,
    required this.frontendPathController,
    required this.backendPathController,
    required this.sshUserController,
    required this.serverStartCmdController,
    required this.mobilePathController,
    required this.onSave,
    required this.onHostChanged,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: widget.ftpHostController,
                    decoration: const InputDecoration(labelText: 'FTP 主机'),
                    onChanged: (_) => widget.onHostChanged(),
                  ),
                  TextField(
                    controller: widget.ftpPortController,
                    decoration: const InputDecoration(labelText: 'FTP 端口'),
                    keyboardType: TextInputType.number,
                  ),
                  TextField(
                    controller: widget.ftpUserController,
                    decoration: const InputDecoration(labelText: 'FTP 用户名'),
                  ),
                  TextField(
                    controller: widget.ftpPassController,
                    decoration: const InputDecoration(labelText: 'FTP 密码'),
                    obscureText: true,
                  ),
                  TextField(
                    controller: widget.frontendPathController,
                    decoration: const InputDecoration(labelText: '前端本地路径'),
                  ),
                  TextField(
                    controller: widget.ftpFrontendDirController,
                    decoration: const InputDecoration(labelText: '前端远程目录'),
                  ),
                  TextField(
                    controller: widget.backendPathController,
                    decoration: const InputDecoration(labelText: '后端本地路径'),
                  ),
                  TextField(
                    controller: widget.ftpBackendDirController,
                    decoration: const InputDecoration(labelText: '后端远程目录'),
                  ),
                  TextField(
                    controller: widget.sshUserController,
                    decoration: const InputDecoration(labelText: 'SSH 用户名'),
                  ),
                  TextField(
                    controller: widget.serverStartCmdController,
                    decoration: const InputDecoration(labelText: '后端启动命令（远程）'),
                  ),
                  TextField(
                    controller: widget.mobilePathController,
                    decoration: const InputDecoration(labelText: '移动端本地路径'),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      const Spacer(),
                      ElevatedButton.icon(
                        onPressed: () async => widget.onSave(),
                        icon: const Icon(Icons.save),
                        label: const Text('保存配置'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
