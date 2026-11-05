import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_upload/actions/building_photo_action.dart';

const List<int> _png = [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3
];
const List<int> _jpg = [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3];

Future<Directory> _tempDir() async {
  final dir = await Directory.systemTemp.createTemp('building_photo_test_');
  addTearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  return dir;
}

Future<File> _image(Directory dir, String name, [List<int> bytes = _png]) async {
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(bytes);
  return file;
}

Map<String, dynamic> _manifest(String buildingDir) => Map<String, dynamic>.from(
    jsonDecode(File('$buildingDir/floors.json').readAsStringSync()) as Map);

void main() {
  group('照片名与楼名匹配', () {
    test('精确楼名、去括号说明与楼 ID 都能命中', () {
      const building = BuildingPhotoBuilding(
        id: '1294698345147666432',
        name: '主楼（南湖校区）',
      );
      expect(buildingPhotoNameMatches('主楼（南湖校区）', building), isTrue);
      expect(buildingPhotoNameMatches('主楼', building), isTrue);
      expect(
        buildingPhotoNameMatches('主楼_1294698345147666432', building),
        isTrue,
      );
      expect(buildingPhotoNameMatches('图书馆', building), isFalse);
    });

    test('扩展名归一化与非法扩展名', () {
      expect(BuildingPhotoStore.normalizedExtension('a.PNG'), 'png');
      expect(BuildingPhotoStore.normalizedExtension('a.JPEG'), 'jpg');
      expect(BuildingPhotoStore.normalizedExtension('a.avif'), isNull);
      expect(BuildingPhotoStore.normalizedExtension('a'), isNull);
    });
  });

  group('单栋采集', () {
    test('导入写入固定文件名与 floors.json 字段', () async {
      final root = await _tempDir();
      final buildingDir = '${root.path}/主楼_1';
      final source = await _image(root, '主楼外观.png');
      await File('$buildingDir/floors.json').create(recursive: true);
      await File('$buildingDir/floors.json')
          .writeAsString(jsonEncode({'buildingId': '1'}));

      final path = await BuildingPhotoStore.importFile(
        buildingDir: buildingDir,
        sourcePath: source.path,
      );

      expect(path, '$buildingDir/building_photo.png');
      expect(File(path).existsSync(), isTrue);
      expect(_manifest(buildingDir)['buildingPhoto'], 'building_photo.png');
      expect(await BuildingPhotoStore.resolve(buildingDir), path);
      expect(await BuildingPhotoStore.relative(buildingDir),
          'building_photo.png');
    });

    test('替换时删除旧扩展名照片并更新清单', () async {
      final root = await _tempDir();
      final buildingDir = '${root.path}/主楼_1';
      final png = await _image(root, 'a.png');
      final jpg = await _image(root, 'b.jpeg', _jpg);
      await File('$buildingDir/floors.json').create(recursive: true);
      await File('$buildingDir/floors.json')
          .writeAsString(jsonEncode({'buildingId': '1'}));

      await BuildingPhotoStore.importFile(
          buildingDir: buildingDir, sourcePath: png.path);
      final replaced = await BuildingPhotoStore.importFile(
          buildingDir: buildingDir, sourcePath: jpg.path);

      expect(replaced, '$buildingDir/building_photo.jpg');
      expect(File('$buildingDir/building_photo.png').existsSync(), isFalse);
      expect(_manifest(buildingDir)['buildingPhoto'], 'building_photo.jpg');
      expect(await BuildingPhotoStore.resolve(buildingDir), replaced);
    });

    test('未爬取过的楼只写照片文件，扫描仍能找到', () async {
      final root = await _tempDir();
      final buildingDir = '${root.path}/新楼_2';
      final source = await _image(root, '新楼.png');

      await BuildingPhotoStore.importFile(
          buildingDir: buildingDir, sourcePath: source.path);

      expect(File('$buildingDir/floors.json').existsSync(), isFalse);
      expect(await BuildingPhotoStore.resolve(buildingDir),
          '$buildingDir/building_photo.png');
    });

    test('删除照片会清掉清单字段', () async {
      final root = await _tempDir();
      final buildingDir = '${root.path}/主楼_1';
      final source = await _image(root, '主楼.png');
      await BuildingPhotoStore.importFile(
          buildingDir: buildingDir, sourcePath: source.path);
      // 模拟爬取写过清单
      await File('$buildingDir/floors.json').writeAsString(jsonEncode({
        'buildingId': '1',
        'buildingPhoto': await BuildingPhotoStore.relative(buildingDir),
        'floors': [],
      }));

      await BuildingPhotoStore.remove(buildingDir);

      expect(File('$buildingDir/building_photo.png').existsSync(), isFalse);
      expect(_manifest(buildingDir).containsKey('buildingPhoto'), isFalse);
      expect(await BuildingPhotoStore.resolve(buildingDir), isNull);
    });

    test('不支持的格式抛异常', () async {
      final root = await _tempDir();
      final source = await _image(root, '主楼.avif');
      expect(
        () => BuildingPhotoStore.importFile(
            buildingDir: '${root.path}/主楼_1', sourcePath: source.path),
        throwsA(isA<BuildingPhotoException>()),
      );
    });
  });

  group('批量按楼名采集', () {
    test('匹配楼名 / 楼 ID，跳过已有，报告未使用照片', () async {
      final root = await _tempDir();
      final sourceDir = await Directory('${root.path}/photos').create();
      await _image(sourceDir, '主楼（南湖校区）.png');
      await _image(sourceDir, '图书馆_1294698350235357184.jpg', _jpg);
      await _image(sourceDir, '无关照片.png');

      final entries = [
        BuildingPhotoEntry(
          building: const BuildingPhotoBuilding(
              id: '1294698345147666432', name: '主楼（南湖校区）'),
          dir: '${root.path}/主楼_1294698345147666432',
        ),
        BuildingPhotoEntry(
          building: const BuildingPhotoBuilding(
              id: '1294698350235357184', name: '图书馆（南湖校区）'),
          dir: '${root.path}/图书馆_1294698350235357184',
        ),
      ];

      final first = await BuildingPhotoStore.importBatch(
          entries: entries, sourceDir: sourceDir.path);
      expect(first.imported, 2);
      expect(first.unmatchedFiles, ['无关照片.png']);
      expect(
        await BuildingPhotoStore.resolve(entries.first.dir),
        '${entries.first.dir}/building_photo.png',
      );
      expect(
        await BuildingPhotoStore.resolve(entries.last.dir),
        '${entries.last.dir}/building_photo.jpg',
      );

      final second = await BuildingPhotoStore.importBatch(
          entries: entries, sourceDir: sourceDir.path);
      expect(second.imported, 0);
      expect(second.skippedExisting, 2);
    });

    test('重名楼需要带楼 ID 命名，不会被随意匹配', () async {
      final root = await _tempDir();
      final sourceDir = await Directory('${root.path}/photos').create();
      await _image(sourceDir, '三连轧实验室.png');
      final entries = [
        BuildingPhotoEntry(
          building: const BuildingPhotoBuilding(
              id: '1000000000000000001', name: '三连轧实验室'),
          dir: '${root.path}/三连轧实验室_1000000000000000001',
        ),
        BuildingPhotoEntry(
          building: const BuildingPhotoBuilding(
              id: '1000000000000000002', name: '三连轧实验室'),
          dir: '${root.path}/三连轧实验室_1000000000000000002',
        ),
      ];

      final ambiguous = await BuildingPhotoStore.importBatch(
          entries: entries, sourceDir: sourceDir.path);
      expect(ambiguous.imported, 0);
      expect(ambiguous.ambiguousBuildings, hasLength(2));

      await File('${sourceDir.path}/三连轧实验室.png').delete();
      await _image(sourceDir, '三连轧实验室_1000000000000000002.png');
      final resolved = await BuildingPhotoStore.importBatch(
          entries: entries, sourceDir: sourceDir.path);
      expect(resolved.imported, 1);
      expect(
        await BuildingPhotoStore.resolve(entries.last.dir),
        '${entries.last.dir}/building_photo.png',
      );
      expect(await BuildingPhotoStore.resolve(entries.first.dir), isNull);
    });
  });
}
