import 'dart:convert';
import 'dart:io';

import 'floor_action.dart';

/// 校区 / 楼栋 / 楼层树的本地缓存。
///
/// 登录状态下成功加载树后写入 `<输出目录>/tree.json`；应用启动时直接读取，
/// 因此未登录、未启动 Chrome 也能浏览校区与楼宇列表。
class FloorTreeCache {
  static const String fileName = 'tree.json';

  /// 缓存文件路径：与 floors.json 同放在输出目录根下。
  static String filePath(String outputDir) {
    final base =
        outputDir.trim().isEmpty ? defaultFloorOutputDir() : outputDir.trim();
    return '$base/$fileName';
  }

  /// 读取树缓存。
  ///
  /// 优先读 `tree.json`；旧版本只留下楼层清单时，从任一
  /// `<楼栋目录>/floors.json` 的 tree 字段恢复。
  static Future<CachedFloorTree?> load(String outputDir) async {
    final base =
        outputDir.trim().isEmpty ? defaultFloorOutputDir() : outputDir.trim();
    final fromTree = await _readTreeFile('$base/$fileName');
    if (fromTree != null) return fromTree;
    return _recoverFromManifest(base);
  }

  /// 保存树到 `tree.json`，返回文件路径。
  static Future<String> save(String outputDir, List<FloorNode> tree) async {
    final path = filePath(outputDir);
    final file = File(path);
    await file.parent.create(recursive: true);
    final payload = <String, dynamic>{
      'savedAt': DateTime.now().toIso8601String(),
      'tree': tree.map((node) => node.toJson()).toList(),
    };
    await file
        .writeAsString(const JsonEncoder.withIndent('  ').convert(payload));
    return path;
  }

  static Future<CachedFloorTree?> _readTreeFile(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      final tree = parseFloorTree(decoded['tree']);
      if (tree.isEmpty) return null;
      return CachedFloorTree(
        tree: tree,
        path: path,
        savedAt: DateTime.tryParse('${decoded['savedAt'] ?? ''}'),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<CachedFloorTree?> _recoverFromManifest(String base) async {
    final dir = Directory(base);
    if (!await dir.exists()) return null;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final manifest = File('${entity.path}/floors.json');
      if (!await manifest.exists()) continue;
      try {
        final decoded = jsonDecode(await manifest.readAsString());
        if (decoded is! Map) continue;
        final tree = parseFloorTree(decoded['tree']);
        if (tree.isEmpty) continue;
        return CachedFloorTree(
          tree: tree,
          path: manifest.path,
          savedAt: DateTime.tryParse('${decoded['crawledAt'] ?? ''}'),
        );
      } catch (_) {
        continue;
      }
    }
    return null;
  }
}

/// 读取到的本地树缓存。
class CachedFloorTree {
  final List<FloorNode> tree;
  final String path;
  final DateTime? savedAt;

  const CachedFloorTree({
    required this.tree,
    required this.path,
    this.savedAt,
  });
}
