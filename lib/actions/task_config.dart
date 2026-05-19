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
  final String winBuildHost;
  final String winBuildSshUser;
  final String winLocalProjectPath;
  final String winRemoteProjectDir;
  final String localIp;

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
    required this.winBuildHost,
    required this.winBuildSshUser,
    required this.winLocalProjectPath,
    required this.winRemoteProjectDir,
    this.localIp = '',
  });
}
