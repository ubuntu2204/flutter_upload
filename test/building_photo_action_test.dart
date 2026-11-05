import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_upload/actions/building_photo_action.dart';

const List<int> _png = [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3
];
const List<int> _jpg = [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3];
const List<int> _webp = [
  0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50, 1, 2
];

Future<Directory> _tempDir() async {
  final dir = await Directory.systemTemp.createTemp('building_photo_test_');
  addTearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  return dir;
}

Map<String, dynamic> _manifest(String buildingDir) => Map<String, dynamic>.from(
    jsonDecode(File('$buildingDir/floors.json').readAsStringSync()) as Map);

void main() {
  group('平台楼栋信息解析', () {
    test('解析 sign 精简响应，取第一张照片与三项简介', () {
      final infos = parseBuildingInfoList({
        'list': [
          {
            'id': '1294698352269594624',
            'name': '国际学术交流中心',
            'attachImg': 'CC81845FDFA44724A65C5B8B58B0CD4A,'
                'C13BC86E164649619341E8BE8DA54AAB',
            'deptNum': 1,
            'floorArea': 28750,
            'useArea': 19262.5,
            'address': '沈阳市和平区文化路3巷11号',
            'description': '国际学术交流中心简介…',
          },
          {
            'id': '1002',
            'name': '无照片楼',
            'attachImg': '',
            'deptNum': '2',
            'floorArea': '100.5',
            'useArea': '80',
          },
          {'name': '缺 ID 的脏数据'},
        ],
      });

      expect(infos, hasLength(2));
      expect(infos.first.photoIds, hasLength(2));
      expect(infos.first.firstPhotoId,
          'CC81845FDFA44724A65C5B8B58B0CD4A');
      expect(infos.first.statsLine,
          '使用单位数：1 家 · 建筑面积：28750m² · 使用面积：19262.5m²');
      expect(infos.first.description, '国际学术交流中心简介…');
      expect(infos.last.firstPhotoId, isEmpty);
      expect(infos.last.deptNum, 2);
      expect(infos.last.floorArea, 100.5);
    });

    test('兼容平台原始字段 backup3 与 data 外壳', () {
      final raw = parseBuildingInfoList({
        'data': {
          'list': [
            {
              'id': '1',
              'name': '主楼',
              'attachImg': 'AAA,BBB',
              'deptNum': 5,
              'floorArea': 1000,
              'useArea': 900,
              'backup3': '平台原始简介',
            },
          ],
        },
      });
      expect(raw.single.description, '平台原始简介');
      expect(parseBuildingInfoList([
        {'id': '1', 'name': '主楼'}
      ]).single.name, '主楼');
      expect(parseBuildingInfoList(null), isEmpty);
    });

    test('面积显示不带多余小数', () {
      expect(formatArea(28750), '28750');
      expect(formatArea(19262.5), '19262.5');
    });
  });

  group('照片与简介落盘', () {
    test('saveBytes 按文件头命名并写 floors.json', () async {
      final root = await _tempDir();
      final buildingDir = '${root.path}/主楼_1';
      await File('$buildingDir/floors.json').create(recursive: true);
      await File('$buildingDir/floors.json')
          .writeAsString(jsonEncode({'buildingId': '1'}));

      final path = await BuildingPhotoStore.saveBytes(buildingDir, _jpg);

      expect(path, '$buildingDir/building_photo.jpg');
      expect(File(path).readAsBytesSync(), _jpg);
      expect(_manifest(buildingDir)['buildingPhoto'], 'building_photo.jpg');
      expect(await BuildingPhotoStore.resolve(buildingDir), path);
      expect(
          await BuildingPhotoStore.relative(buildingDir), 'building_photo.jpg');
    });

    test('重新采集不同格式时删除旧扩展名照片', () async {
      final root = await _tempDir();
      final buildingDir = '${root.path}/主楼_1';
      await File('$buildingDir/floors.json').create(recursive: true);
      await File('$buildingDir/floors.json')
          .writeAsString(jsonEncode({'buildingId': '1'}));

      await BuildingPhotoStore.saveBytes(buildingDir, _png);
      final replaced = await BuildingPhotoStore.saveBytes(buildingDir, _webp);

      expect(replaced, '$buildingDir/building_photo.webp');
      expect(File('$buildingDir/building_photo.png').existsSync(), isFalse);
      expect(_manifest(buildingDir)['buildingPhoto'], 'building_photo.webp');
      expect(await BuildingPhotoStore.resolve(buildingDir), replaced);
    });

    test('未爬取过的楼只写照片与简介，扫描仍能找到', () async {
      final root = await _tempDir();
      final buildingDir = '${root.path}/新楼_2';
      await BuildingPhotoStore.saveBytes(buildingDir, _png);

      expect(File('$buildingDir/floors.json').existsSync(), isFalse);
      expect(await BuildingPhotoStore.resolve(buildingDir),
          '$buildingDir/building_photo.png');
    });

    test('简介写入 building.json 并可回读', () async {
      final root = await _tempDir();
      final buildingDir = '${root.path}/主楼_1';
      final info = BuildingInfo.fromJson({
        'id': '1',
        'name': '主楼',
        'attachImg': 'AAA',
        'deptNum': 1,
        'floorArea': 28750,
        'useArea': 19262.5,
        'address': '文化路',
        'description': '简介',
      });

      expect(await BuildingPhotoStore.hasInfo(buildingDir), isFalse);
      await BuildingPhotoStore.saveInfo(buildingDir, info);
      expect(await BuildingPhotoStore.hasInfo(buildingDir), isTrue);
      final read = await BuildingPhotoStore.readInfo(buildingDir);
      expect(read?.statsLine, info.statsLine);
      expect(read?.firstPhotoId, 'AAA');
      expect(read?.collectedAt, isNotNull);
    });

    test('删除照片会清清单字段，但保留简介', () async {
      final root = await _tempDir();
      final buildingDir = '${root.path}/主楼_1';
      await BuildingPhotoStore.saveBytes(buildingDir, _png);
      await BuildingPhotoStore.saveInfo(
          buildingDir,
          BuildingInfo.fromJson({
            'id': '1',
            'name': '主楼',
            'attachImg': 'AAA',
            'deptNum': 1,
            'floorArea': 1,
            'useArea': 1,
          }));
      await File('$buildingDir/floors.json').writeAsString(jsonEncode({
        'buildingId': '1',
        'buildingPhoto': await BuildingPhotoStore.relative(buildingDir),
        'floors': [],
      }));

      await BuildingPhotoStore.remove(buildingDir);

      expect(File('$buildingDir/building_photo.png').existsSync(), isFalse);
      expect(_manifest(buildingDir).containsKey('buildingPhoto'), isFalse);
      expect(await BuildingPhotoStore.resolve(buildingDir), isNull);
      expect(await BuildingPhotoStore.hasInfo(buildingDir), isTrue);
    });

    test('重新爬取楼层时保留已有楼照片字段', () async {
      final root = await _tempDir();
      final buildingDir = '${root.path}/主楼_1';
      await BuildingPhotoStore.saveBytes(buildingDir, _jpg);
      await File('$buildingDir/floors.json').writeAsString(jsonEncode({
        'buildingId': '1',
        'buildingPhoto': await BuildingPhotoStore.relative(buildingDir),
      }));
      // 模拟爬虫重写清单时带上 relative() 结果
      final manifest =
          Map<String, dynamic>.from(jsonDecode(
                  File('$buildingDir/floors.json').readAsStringSync()) as Map)
            ..['floors'] = []
            ..['buildingPhoto'] =
                await BuildingPhotoStore.relative(buildingDir);
      await File('$buildingDir/floors.json')
          .writeAsString(jsonEncode(manifest));

      expect(manifest['buildingPhoto'], 'building_photo.jpg');
      expect(await BuildingPhotoStore.resolve(buildingDir),
          '$buildingDir/building_photo.jpg');
    });

    test('不支持的图片字节抛异常', () async {
      final root = await _tempDir();
      expect(
        () => BuildingPhotoStore.saveBytes(
            '${root.path}/主楼_1', [1, 2, 3, 4]),
        throwsA(isA<BuildingPhotoException>()),
      );
    });
  });
}
