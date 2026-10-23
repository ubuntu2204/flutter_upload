import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_upload/actions/floor_action.dart';
import 'package:flutter_upload/actions/floor_tree_cache.dart';

void main() {
  List<FloorNode> sampleTree() => parseFloorTree([
        {
          'id': 'campus-1',
          'name': '南湖校区',
          'children': [
            {
              'id': 'building-1',
              'name': '主楼',
              'baseCampusId': 'campus-1',
              'children': [
                {
                  'id': 'floor-1',
                  'name': '一层',
                  'parentId': 'building-1',
                  'baseCampusId': 'campus-1',
                  'children': <dynamic>[],
                },
                {
                  'id': 'floor-2',
                  'name': '二层',
                  'parentId': 'building-1',
                  'baseCampusId': 'campus-1',
                  'children': <dynamic>[],
                },
              ],
            },
          ],
        },
      ]);

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('floor_tree_cache_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('FloorTreeCache', () {
    test('保存后可离线读取完整层级', () async {
      final path = await FloorTreeCache.save(tempDir.path, sampleTree());
      expect(path, '${tempDir.path}/${FloorTreeCache.fileName}');
      expect(await File(path).exists(), isTrue);

      final cached = await FloorTreeCache.load(tempDir.path);
      expect(cached, isNotNull);
      expect(cached!.path, path);
      expect(cached.tree, hasLength(1));
      expect(cached.tree.single.name, '南湖校区');
      final building = cached.tree.single.children.single;
      expect(building.name, '主楼');
      expect(building.campusId, 'campus-1');
      expect(building.children.map((f) => f.name), ['一层', '二层']);
    });

    test('没有 tree.json 时从 floors.json 的 tree 字段恢复', () async {
      final buildingDir = Directory('${tempDir.path}/主楼_building-1');
      await buildingDir.create(recursive: true);
      await File('${buildingDir.path}/floors.json').writeAsString(jsonEncode({
        'crawledAt': '2026-10-21T10:00:00.000',
        'tree': sampleTree().map((c) => c.toJson()).toList(),
      }));

      final cached = await FloorTreeCache.load(tempDir.path);
      expect(cached, isNotNull);
      expect(cached!.tree.single.children.single.name, '主楼');
      expect(cached.savedAt, DateTime(2026, 10, 21, 10));
    });

    test('缓存损坏或不存在时返回 null', () async {
      expect(await FloorTreeCache.load(tempDir.path), isNull);

      await File('${tempDir.path}/${FloorTreeCache.fileName}')
          .writeAsString('{ not json');
      expect(await FloorTreeCache.load(tempDir.path), isNull);
    });

    test('输出目录为空时使用默认目录，不写坏数据', () {
      expect(
        FloorTreeCache.filePath('  '),
        '${defaultFloorOutputDir()}/${FloorTreeCache.fileName}',
      );
    });
  });
}
