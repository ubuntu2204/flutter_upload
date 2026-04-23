import 'dart:io';

class AppConfig {
  static const String ftpConfigFileName = 'ftp_config.json';
  static String get ftpConfigPath =>
      '${Directory.current.path}/$ftpConfigFileName';
}
