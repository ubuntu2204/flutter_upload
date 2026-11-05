import 'dart:convert';
import 'dart:io';

/// 每栋楼唯一一张「楼照片」的固定基名，扩展名按平台返回的图片格式决定。
///
/// 保存位置：`<输出目录>/<楼名>_<楼ID>/building_photo.png|jpg|...`，
/// 同时在 `floors.json` 写入 `buildingPhoto` 相对路径，重新爬取楼层时不会丢。
const String buildingPhotoBaseName = 'building_photo';
const String buildingPhotoManifestKey = 'buildingPhoto';

/// 平台楼栋简介（`personal/visual/map/<campusId>/sign` 的精简结果）。
const String buildingInfoFileName = 'building.json';

class BuildingInfo {
  final String id;
  final String name;

  /// `attachImg` 逗号分隔的多张照片 ID；采集时取第一张。
  final List<String> photoIds;
  final int deptNum;
  final double floorArea;
  final double useArea;
  final String address;

  /// 平台 `backup3` 里的楼栋文字简介，可能为空。
  final String description;
  final DateTime? collectedAt;

  const BuildingInfo({
    required this.id,
    required this.name,
    required this.photoIds,
    required this.deptNum,
    required this.floorArea,
    required this.useArea,
    required this.address,
    required this.description,
    this.collectedAt,
  });

  String get firstPhotoId => photoIds.isEmpty ? '' : photoIds.first;

  /// 页面与 maintenance 侧共用的简介口径。
  String get statsLine => '使用单位数：$deptNum 家 · '
      '建筑面积：${formatArea(floorArea)}m² · '
      '使用面积：${formatArea(useArea)}m²';

  factory BuildingInfo.fromJson(Map<String, dynamic> json) {
    final rawPhotos = json['photoIds'] ?? json['attachImg'] ?? '';
    final photos = rawPhotos is List
        ? rawPhotos.map((e) => e.toString().trim()).where((e) => e.isNotEmpty)
        : rawPhotos
            .toString()
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty);
    return BuildingInfo(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      photoIds: photos.toList(growable: false),
      deptNum: _toInt(json['deptNum']),
      floorArea: _toDouble(json['floorArea']),
      useArea: _toDouble(json['useArea']),
      address: (json['address'] ?? '').toString(),
      description: (json['description'] ?? json['backup3'] ?? '').toString(),
      collectedAt: DateTime.tryParse((json['collectedAt'] ?? '').toString()),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'photoIds': photoIds,
        'deptNum': deptNum,
        'floorArea': floorArea,
        'useArea': useArea,
        'address': address,
        'description': description,
        if (collectedAt != null) 'collectedAt': collectedAt!.toIso8601String(),
      };

  BuildingInfo withCollectedAt(DateTime time) => BuildingInfo(
        id: id,
        name: name,
        photoIds: photoIds,
        deptNum: deptNum,
        floorArea: floorArea,
        useArea: useArea,
        address: address,
        description: description,
        collectedAt: time,
      );
}

/// 面积显示：整数不带小数，其它保留平台原值。
String formatArea(double value) =>
    value == value.roundToDouble() ? value.toStringAsFixed(0) : '$value';

/// 解析平台返回的楼栋信息列表。
///
/// 兼容精简后的 `{list: [...]}`、平台原始响应外壳 `{data: {list: [...]}}`
/// 与直接数组三种形态，去掉没有 ID 的脏数据。
List<BuildingInfo> parseBuildingInfoList(dynamic payload) {
  dynamic data = payload;
  if (data is Map) {
    if (data['list'] is List) {
      data = data['list'];
    } else {
      final inner = data['data'];
      if (inner is Map && inner['list'] is List) {
        data = inner['list'];
      } else if (inner is List) {
        data = inner;
      }
    }
  }
  if (data is! List) return const [];
  return data
      .whereType<Map>()
      .map((e) => BuildingInfo.fromJson(Map<String, dynamic>.from(e)))
      .where((info) => info.id.isNotEmpty)
      .toList(growable: false);
}

/// 一次「采集楼照片与简介」的结果汇总。
class BuildingInfoCollectionResult {
  int total = 0;
  int platformCount = 0;
  int captured = 0;
  int skipped = 0;
  int missingInfo = 0;
  int noPhoto = 0;
  int failed = 0;
  bool stopped = false;
  final List<String> failures = [];

  String get summary => '平台楼栋 $platformCount 栋，本次采集 $captured 张，'
      '已有跳过 $skipped 栋，无信息 $missingInfo 栋，无照片 $noPhoto 栋，'
      '失败 $failed 栋${stopped ? '（已手动停止）' : ''}';
}

class BuildingPhotoException implements Exception {
  final String message;

  const BuildingPhotoException(this.message);

  @override
  String toString() => message;
}

class BuildingPhotoStore {
  const BuildingPhotoStore._();

  static String _baseName(String path) => path.split(Platform.pathSeparator).last;

  /// 扫描用的扩展名白名单。
  static String? normalizedExtension(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return null;
    var ext = path.substring(dot + 1).toLowerCase();
    if (ext == 'jpeg') ext = 'jpg';
    return const {'png', 'jpg', 'gif', 'webp'}.contains(ext) ? ext : null;
  }

  /// 按文件头判断平台图片真实格式。
  static String extensionFromBytes(List<int> bytes) {
    if (bytes.length >= 4 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'png';
    }
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
      return 'jpg';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46) {
      return 'gif';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'webp';
    }
    throw const BuildingPhotoException('平台返回的不是支持的图片格式');
  }

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
  static Future<String?> relative(String buildingDir) async {
    final path = await resolve(buildingDir);
    if (path == null) return null;
    final prefix = buildingDir.endsWith('/')
        ? buildingDir
        : '$buildingDir${Platform.pathSeparator}';
    return path.startsWith(prefix)
        ? path.substring(prefix.length)
        : _baseName(path);
  }

  /// 保存平台下载的照片字节，清掉旧扩展名的照片并更新清单。
  static Future<String> saveBytes(
      String buildingDir, List<int> bytes) async {
    final ext = extensionFromBytes(bytes);
    final dir = Directory(buildingDir);
    await dir.create(recursive: true);
    final target = File('${dir.path}/$buildingPhotoBaseName.$ext');
    for (final old in await _photoFiles(dir.path)) {
      if (old.path != target.path) await old.delete();
    }
    await target.writeAsBytes(bytes);
    await _writeManifest(dir.path, _baseName(target.path));
    return target.path;
  }

  /// 删除该楼照片并清掉清单字段（保留已采集的简介）。
  static Future<void> remove(String buildingDir) async {
    for (final file in await _photoFiles(buildingDir)) {
      await file.delete();
    }
    await _writeManifest(buildingDir, null);
  }

  static File infoFile(String buildingDir) =>
      File('$buildingDir/$buildingInfoFileName');

  static Future<bool> hasInfo(String buildingDir) async =>
      infoFile(buildingDir).exists();

  static Future<void> saveInfo(
      String buildingDir, BuildingInfo info) async {
    final dir = Directory(buildingDir);
    await dir.create(recursive: true);
    await infoFile(dir.path).writeAsString(
      const JsonEncoder.withIndent('  ').convert(
        info.withCollectedAt(DateTime.now()).toJson(),
      ),
    );
  }

  static Future<BuildingInfo?> readInfo(String buildingDir) async {
    final file = infoFile(buildingDir);
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      return BuildingInfo.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
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
}

double _toDouble(dynamic value) {
  if (value is num) return value.toDouble();
  return double.tryParse('$value') ?? 0;
}

int _toInt(dynamic value) {
  if (value is num) return value.toInt();
  return int.tryParse('$value') ?? 0;
}
