import 'dart:convert';
import 'dart:io';

/// 每栋楼唯一一张「楼照片」的固定基名，扩展名跟随来源图片。
///
/// 保存位置：`<输出目录>/<楼名>_<楼ID>/building_photo.png|jpg|...`，
/// 同时在 `floors.json` 写入 `buildingPhoto` 相对路径，重新爬取楼层时不会丢。
const String buildingPhotoBaseName = 'building_photo';
const String buildingPhotoManifestKey = 'buildingPhoto';

const Set<String> _supportedExtensions = {'png', 'jpg', 'jpeg', 'gif', 'webp'};

/// 批量导入时的一栋楼。与 FloorNode 解耦，避免动作层互相依赖。
class BuildingPhotoBuilding {
  final String id;
  final String name;

  const BuildingPhotoBuilding({required this.id, required this.name});
}

/// 一栋楼及其本地数据目录。
class BuildingPhotoEntry {
  final BuildingPhotoBuilding building;
  final String dir;

  const BuildingPhotoEntry({required this.building, required this.dir});
}

class BuildingPhotoBatchResult {
  int imported = 0;
  int skippedExisting = 0;
  final List<String> ambiguousBuildings = [];
  final List<String> unmatchedBuildings = [];
  final List<String> unmatchedFiles = [];

  String get summary => '导入 $imported 张，已有照片跳过 $skippedExisting 栋，'
      '未匹配楼 ${unmatchedBuildings.length} 栋，重名待确认 ${ambiguousBuildings.length} 栋，'
      '未使用照片 ${unmatchedFiles.length} 张';
}

class BuildingPhotoException implements Exception {
  final String message;

  const BuildingPhotoException(this.message);

  @override
  String toString() => message;
}

/// 规范化照片文件名 / 楼名，用于匹配。
///
/// 统一大小写、空白、全半角括号，并去掉拍摄命名里常见的分隔符与 `#`。
String normalizeBuildingPhotoKey(String text) => text
    .toLowerCase()
    .replaceAll('（', '(')
    .replaceAll('）', ')')
    .replaceAll(RegExp(r'\s+'), '')
    .replaceAll(RegExp(r'[_\-#.]'), '')
    .trim();

/// 去掉楼名里的括号说明（如「主楼（南湖校区）」→「主楼」）。
String stripBuildingPhotoParentheses(String text) =>
    text.replaceAll(RegExp(r'\([^)]*\)'), '');

/// 照片文件名（不含扩展名）是否明确指向某栋楼。
///
/// 支持三种命名：含楼 ID、与楼名完全相同、与去掉括号说明后的楼名相同。
bool buildingPhotoNameMatches(String photoName, BuildingPhotoBuilding building) {
  final key = normalizeBuildingPhotoKey(photoName);
  if (key.isEmpty) return false;
  if (building.id.isNotEmpty && key.contains(building.id)) return true;
  final name = normalizeBuildingPhotoKey(building.name);
  if (name.isNotEmpty && key == name) return true;
  final shortName = normalizeBuildingPhotoKey(
      stripBuildingPhotoParentheses(building.name.replaceAll('（', '(').replaceAll('）', ')')));
  return shortName.length >= 2 && key == shortName;
}

/// 宽松匹配：照片名包含楼名，或楼名包含照片名（至少 3 个字）。
bool buildingPhotoNameLooselyMatches(
    String photoName, BuildingPhotoBuilding building) {
  final key = normalizeBuildingPhotoKey(photoName);
  final name = normalizeBuildingPhotoKey(
      stripBuildingPhotoParentheses(building.name.replaceAll('（', '(').replaceAll('）', ')')));
  if (key.length < 3 || name.length < 3) return false;
  return key.contains(name) || name.contains(key);
}

class BuildingPhotoStore {
  const BuildingPhotoStore._();

  /// 允许的图片扩展名；`jpeg` 统一保存为 `jpg`。
  static String? normalizedExtension(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return null;
    var ext = path.substring(dot + 1).toLowerCase();
    if (ext == 'jpeg') ext = 'jpg';
    return _supportedExtensions.contains(ext) ? ext : null;
  }

  static String _baseName(String path) => path.split(Platform.pathSeparator).last;

  static String _baseNameWithoutExtension(String path) {
    final name = _baseName(path);
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// 目录下所有固定基名的楼照片文件。
  static Future<List<File>> _photoFiles(String buildingDir) async {
    final dir = Directory(buildingDir);
    if (!await dir.exists()) return const [];
    final files = <File>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = _baseName(entity.path);
      if (!name.startsWith('$buildingPhotoBaseName.')) continue;
      if (normalizedExtension(name) == null) continue;
      files.add(entity);
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  /// 找到该楼已有的照片绝对路径；没有返回 null。
  ///
  /// 优先读 `floors.json` 的 `buildingPhoto`（兼容手工放到别处的照片），
  /// 再回退扫描固定基名文件。
  static Future<String?> resolve(String buildingDir) async {
    final manifest = File('$buildingDir/floors.json');
    if (await manifest.exists()) {
      try {
        final decoded = jsonDecode(await manifest.readAsString());
        if (decoded is Map) {
          final value = decoded[buildingPhotoManifestKey];
          if (value is String && value.trim().isNotEmpty) {
            final path = value.startsWith('/')
                ? value
                : '$buildingDir/${value.trim()}';
            if (await File(path).exists()) return path;
          }
        }
      } catch (_) {
        // 清单损坏时继续用目录扫描兜底。
      }
    }
    final files = await _photoFiles(buildingDir);
    return files.isEmpty ? null : files.first.path;
  }

  /// 供写入 `floors.json` 的相对路径；没有照片返回 null。
  /// 照片文件名里带了别的楼 ID 时，不允许被当前楼的名称宽松匹配抢走。
  static bool _belongsToOtherBuilding(
    String photoName,
    BuildingPhotoBuilding current,
    List<BuildingPhotoEntry> entries,
  ) {
    final key = normalizeBuildingPhotoKey(photoName);
    for (final entry in entries) {
      final id = entry.building.id;
      if (id == current.id || id.isEmpty) continue;
      if (key.contains(id)) return true;
    }
    return false;
  }

  static Future<String?> relative(String buildingDir) async {
    final path = await resolve(buildingDir);
    if (path == null) return null;
    final prefix = buildingDir.endsWith('/')
        ? buildingDir
        : '$buildingDir${Platform.pathSeparator}';
    return path.startsWith(prefix) ? path.substring(prefix.length) : _baseName(path);
  }

  /// 采集一张照片：复制到固定文件名、清掉旧扩展名的照片、更新清单。
  static Future<String> importFile({
    required String buildingDir,
    required String sourcePath,
  }) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw const BuildingPhotoException('所选图片不存在');
    }
    final ext = normalizedExtension(sourcePath);
    if (ext == null) {
      throw const BuildingPhotoException('仅支持 PNG / JPEG / GIF / WebP 图片');
    }
    final dir = Directory(buildingDir);
    await dir.create(recursive: true);
    final target = File('${dir.path}/$buildingPhotoBaseName.$ext');
    for (final old in await _photoFiles(dir.path)) {
      if (old.path != target.path) await old.delete();
    }
    if (source.absolute.path != target.absolute.path) {
      await source.copy(target.path);
    }
    await _writeManifest(dir.path, _baseName(target.path));
    return target.path;
  }

  /// 删除该楼照片并清掉清单字段。
  static Future<void> remove(String buildingDir) async {
    for (final file in await _photoFiles(buildingDir)) {
      await file.delete();
    }
    await _writeManifest(buildingDir, null);
  }

  static Future<void> _writeManifest(
      String buildingDir, String? relativePath) async {
    final file = File('$buildingDir/floors.json');
    if (!await file.exists()) return; // 未爬取过的楼：只留照片文件，扫描即可找到
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return;
      final map = Map<String, dynamic>.from(decoded);
      if (relativePath == null) {
        map.remove(buildingPhotoManifestKey);
      } else {
        map[buildingPhotoManifestKey] = relativePath;
      }
      await file.writeAsString(
          const JsonEncoder.withIndent('  ').convert(map));
    } catch (_) {
      // 清单不可写不影响照片文件本身。
    }
  }

  /// 从照片目录按楼名 / 楼 ID 批量采集，每栋最多一张。
  ///
  /// 一张照片只会被用一次；重名楼（如多个「三连轧实验室」）不会被随意
  /// 匹配，需在文件名里带楼 ID。已有照片默认跳过，可用 [replaceExisting] 覆盖。
  static Future<BuildingPhotoBatchResult> importBatch({
    required List<BuildingPhotoEntry> entries,
    required String sourceDir,
    bool replaceExisting = false,
  }) async {
    final dir = Directory(sourceDir);
    if (!await dir.exists()) {
      throw const BuildingPhotoException('所选照片目录不存在');
    }
    final photos = <File>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File && normalizedExtension(entity.path) != null) {
        photos.add(entity);
      }
    }
    photos.sort((a, b) => a.path.compareTo(b.path));

    final result = BuildingPhotoBatchResult();
    final assigned = <String, String>{}; // buildingId → 照片路径
    final used = <String>{};
    final ambiguous = <String>{};
    final loosePhotos = <File>[];
    final exactByBuilding = <String, List<File>>{};

    // 阶段 A：先做「楼 ID / 完整楼名 / 去括号楼名」精确匹配。
    // 一张照片命中多栋楼（例如多个同名实验室）时判为歧义，谁也不分配。
    for (final photo in photos) {
      final key = _baseNameWithoutExtension(photo.path);
      final matches = entries
          .where((e) => buildingPhotoNameMatches(key, e.building))
          .toList();
      if (matches.isEmpty) {
        loosePhotos.add(photo);
      } else if (matches.length > 1) {
        for (final entry in matches) {
          ambiguous.add(entry.building.id);
        }
      } else {
        final id = matches.single.building.id;
        exactByBuilding.putIfAbsent(id, () => <File>[]).add(photo);
      }
    }
    for (final entry in entries) {
      final exact = exactByBuilding[entry.building.id] ?? const <File>[];
      if (exact.length > 1) {
        ambiguous.add(entry.building.id);
      } else if (exact.length == 1) {
        assigned[entry.building.id] = exact.single.path;
        used.add(exact.single.path);
      }
    }

    // 阶段 B：剩下的楼用包含关系宽松匹配，明确带别的楼 ID 的照片不参与。
    for (final entry in entries) {
      final id = entry.building.id;
      if (assigned.containsKey(id) || ambiguous.contains(id)) continue;
      final candidates = <File>[];
      for (final photo in loosePhotos) {
        if (used.contains(photo.path)) continue;
        final key = _baseNameWithoutExtension(photo.path);
        if (_belongsToOtherBuilding(key, entry.building, entries)) continue;
        if (buildingPhotoNameLooselyMatches(key, entry.building)) {
          candidates.add(photo);
        }
      }
      if (candidates.length == 1) {
        assigned[id] = candidates.single.path;
        used.add(candidates.single.path);
      } else if (candidates.length > 1) {
        ambiguous.add(id);
      }
    }

    // 阶段 C：落盘。已有照片默认跳过，未匹配到照片的楼写进报告。
    for (final entry in entries) {
      final photoPath = assigned[entry.building.id];
      final existing = await resolve(entry.dir);
      if (photoPath == null) {
        if (existing == null) {
          result.unmatchedBuildings.add(entry.building.name);
        }
        continue;
      }
      if (existing != null && !replaceExisting) {
        result.skippedExisting++;
        continue;
      }
      await importFile(buildingDir: entry.dir, sourcePath: photoPath);
      result.imported++;
    }
    for (final entry in entries) {
      if (ambiguous.contains(entry.building.id)) {
        result.ambiguousBuildings.add(entry.building.name);
      }
    }
    for (final photo in photos) {
      if (!used.contains(photo.path)) {
        result.unmatchedFiles.add(_baseName(photo.path));
      }
    }
    return result;
  }
}
