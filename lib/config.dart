import 'dart:io';

class AppConfig {
  static const String ftpConfigFileName = 'ftp_config.json';
  static String ftpConfigPath = '${Directory.current.path}/$ftpConfigFileName';
}
