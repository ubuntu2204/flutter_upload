import 'dart:convert';
import 'dart:io';
import 'task_config.dart';

/// 构建前更新日期：
///  1. frontend/build_config.yaml 的 build_date 字段
///  2. backend/config.json 的 app.version / app.buildNumber 字段
Future<bool> updateBuildDate(
    TaskConfig cfg, void Function(String) addLog) async {
  final now = DateTime.now();
  final dateStr = '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
  final dateCompact = '${now.year.toString().padLeft(4, '0')}'
      '${now.month.toString().padLeft(2, '0')}'
      '${now.day.toString().padLeft(2, '0')}';

  // ── 1. frontend/build_config.yaml ──
  final yamlFile = File('${cfg.frontendPath}/build_config.yaml');
  if (!await yamlFile.exists()) {
    addLog('找不到 ${yamlFile.path}，跳过日期更新\n');
    return false;
  }
  try {
    var content = await yamlFile.readAsString();
    final oldMatch = RegExp(r'(build_date:\s*")[^"]*(")', multiLine: true)
        .firstMatch(content);
    final oldDate = oldMatch != null ? oldMatch.group(0) : '(未知)';
    content = content.replaceFirstMapped(
      RegExp(r'(build_date:\s*")[^"]*(")', multiLine: true),
      (m) => '${m.group(1)}$dateStr${m.group(2)}',
    );
    await yamlFile.writeAsString(content);
    addLog('build_config.yaml: $oldDate → build_date: "$dateStr"\n');
  } catch (e) {
    addLog('更新 build_config.yaml 失败: $e\n');
    return false;
  }

  // ── 2. backend/config.json ──
  final jsonFile = File('${cfg.backendPath}/config.json');
  if (!await jsonFile.exists()) {
    addLog('找不到 ${jsonFile.path}，跳过日期更新\n');
    return false;
  }
  try {
    final raw = await jsonFile.readAsString();
    final Map<String, dynamic> decoded = jsonDecode(raw);
    final app = decoded['app'] as Map<String, dynamic>? ?? {};

    // 保留版本前缀，只替换末尾的日期部分（8位数字）
    final oldVersion = app['version']?.toString() ?? '';
    final newVersion =
        oldVersion.replaceFirstMapped(RegExp(r'\d{8}$'), (_) => dateCompact);
    app['version'] = newVersion.isNotEmpty ? newVersion : '1.0.$dateCompact';
    app['buildNumber'] = int.parse(dateCompact);
    decoded['app'] = app;

    final encoder = const JsonEncoder.withIndent('  ');
    await jsonFile.writeAsString('${encoder.convert(decoded)}\n');
    addLog(
        'config.json: version: "$oldVersion" → "$newVersion", buildNumber: $dateCompact\n');
  } catch (e) {
    addLog('更新 config.json 失败: $e\n');
    return false;
  }

  return true;
}
