/// 各按钮操作所需的配置快照，由 State 在调用时构建并传入。
class TaskConfig {
  final String ftpHost;
  final int ftpPort;
  final String ftpUser;
  final String ftpPass;
  final String ftpFrontendDir;
  final String ftpBackendDir;
  final String frontendPath;
  final String backendPath;
  final String sshUser;
  final String serverStartCmd;
  final String mobilePath;

  /// Windows 推送相关配置
  final String maintenancePath; // 本地 maintenance 项目路径
  final String windowsSshHost; // Windows SSH 主机地址
  final String windowsSshUser; // Windows SSH 用户名
  final String windowsRemotePath; // Windows 远程项目路径

  const TaskConfig({
    required this.ftpHost,
    required this.ftpPort,
    required this.ftpUser,
    required this.ftpPass,
    required this.ftpFrontendDir,
    required this.ftpBackendDir,
    required this.frontendPath,
    required this.backendPath,
    required this.sshUser,
    required this.serverStartCmd,
    required this.mobilePath,
    required this.maintenancePath,
    required this.windowsSshHost,
    required this.windowsSshUser,
    required this.windowsRemotePath,
  });
}
