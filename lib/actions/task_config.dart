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
  final int serverPort;
  final String mobilePath;
  final String visionroamPath;
  final String visionroamBinDir;
  final String visionroamService;
  /// Flutter Web 管理后台源码目录；留空 = 主项目下 packages/admin_web
  final String visionroamAdminPath;

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
    required this.serverPort,
    required this.mobilePath,
    required this.visionroamPath,
    required this.visionroamBinDir,
    required this.visionroamService,
    required this.visionroamAdminPath,
  });
}
