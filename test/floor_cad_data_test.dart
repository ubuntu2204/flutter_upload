import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_upload/actions/floor_cad_data.dart';

Map<String, dynamic> _detailWithCad(Map<String, dynamic> cad, {String key = 'cadIdentifyData'}) {
  return {
    'statisticsRoomVo': {key: jsonEncode(cad)},
  };
}

void main() {
  group('parseFloorCadFromDetail', () {
    test('解析 size、字段映射与顶点，过滤点数不足的房间', () {
      final detail = _detailWithCad({
        'size': {'width': 1436, 'height': 552},
        'rooms': [
          {
            'type': 'room',
            'roomNo': '118',
            'roomId': '1',
            'vertex': [
              {'x': 55, 'y': 169},
              {'x': 55, 'y': 85},
              {'x': 178, 'y': 85},
              {'x': 178, 'y': 169},
            ],
            'room': {
              'roomNo': '118',
              'useArea': 92,
              'roomTypeName': '教室',
              'baseDepName': '教务处',
            },
          },
          {
            'type': 'room',
            'roomNo': '119',
            'vertex': [
              {'x': 200, 'y': 85},
              {'x': 300, 'y': 85},
              {'x': 300, 'y': 169},
            ],
            'room': {'useArea': 50.5, 'roomTypeName': '办公室', 'baseDepName': '后勤'},
          },
          {
            'type': 'room',
            'roomNo': 'BAD',
            'vertex': [
              {'x': 1, 'y': 1},
              {'x': 2, 'y': 2},
            ],
            'room': {},
          },
        ],
      });

      final cad = parseFloorCadFromDetail(detail);
      expect(cad, isNotNull);
      expect(cad!.width, 1436);
      expect(cad.height, 552);
      expect(cad.hasRooms, isTrue);
      // BAD 房间只有 2 个顶点被过滤，剩 2 个。
      expect(cad.rooms.length, 2);

      final first = cad.rooms.first;
      expect(first.no, '118');
      expect(first.area, 92);
      expect(first.type, '教室');
      expect(first.dept, '教务处');
      expect(first.points.length, 4);

      final second = cad.rooms[1];
      expect(second.no, '119');
      expect(second.name, isEmpty);
      expect(second.area, 50.5);

      // 质心 = 顶点均值：((55+55+178+178)/4, (169+85+85+169)/4)。
      expect(first.centroid.dx, closeTo(116.5, 1e-6));
      expect(first.centroid.dy, closeTo(127.0, 1e-6));

      // 射线法命中/未命中。
      expect(first.contains(const Offset(100, 120)), isTrue);
      expect(first.contains(const Offset(0, 0)), isFalse);
    });

    test('去除相邻重复点与闭合重复点', () {
      final detail = _detailWithCad({
        'size': {'width': 100, 'height': 100},
        'rooms': [
          {
            'roomNo': 'A',
            'vertex': [
              {'x': 0, 'y': 0},
              {'x': 0, 'y': 0},
              {'x': 10, 'y': 0},
              {'x': 10, 'y': 10},
              {'x': 0, 'y': 0},
            ],
            'room': {},
          },
        ],
      });

      final cad = parseFloorCadFromDetail(detail)!;
      // 相邻重复点合并、末尾回到起点被去除 → 3 个顶点。
      expect(cad.rooms.single.points.length, 3);
    });

    test('无 cadIdentifyData 时回退 rawData', () {
      final detail = _detailWithCad(
        {
          'size': {'width': 500, 'height': 400},
          'rooms': [
            {
              'roomNo': 'R1',
              'vertex': [
                {'x': 0, 'y': 0},
                {'x': 50, 'y': 0},
                {'x': 50, 'y': 50},
              ],
              'room': {'roomTypeName': '仓库'},
            },
          ],
        },
        key: 'rawData',
      );

      final cad = parseFloorCadFromDetail(detail);
      expect(cad, isNotNull);
      expect(cad!.rooms.single.no, 'R1');
      expect(cad.rooms.single.type, '仓库');
    });

    test('size 缺失时用顶点包围盒兜底', () {
      final detail = _detailWithCad({
        'rooms': [
          {
            'roomNo': 'R2',
            'vertex': [
              {'x': 0, 'y': 0},
              {'x': 220, 'y': 0},
              {'x': 220, 'y': 130},
              {'x': 0, 'y': 130},
            ],
            'room': {},
          },
        ],
      });

      final cad = parseFloorCadFromDetail(detail)!;
      expect(cad.width, 220);
      expect(cad.height, 130);
    });

    test('无有效房间矢量返回 null', () {
      expect(parseFloorCadFromDetail({}), isNull);
      expect(
        parseFloorCadFromDetail({
          'statisticsRoomVo': {'cadIdentifyData': jsonEncode({'size': {'width': 10, 'height': 10}})},
        }),
        isNull,
      );
    });
  });
}
