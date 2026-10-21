import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_upload/actions/floor_action.dart';

void main() {
  const sampleUrl =
      'http://210.30.202.99/house/house-base-decision/personal/view/'
      '1294698345147666432?id=1294698345147666432&name=%E4%B8%BB%E6%A5%BC';

  group('parseBuildingId', () {
    test('从完整页面链接的 id 参数解析', () {
      expect(parseBuildingId(sampleUrl), '1294698345147666432');
    });

    test('无 id 参数时从 /view/<id> 路径解析', () {
      expect(
        parseBuildingId(
            'http://210.30.202.99/house/house-base-decision/personal/view/123456789'),
        '123456789',
      );
    });

    test('支持直接填写楼栋 ID', () {
      expect(parseBuildingId(' 1294698345147666432 '), '1294698345147666432');
    });

    test('无法解析时返回 null', () {
      expect(parseBuildingId(''), isNull);
      expect(parseBuildingId('http://example.com/'), isNull);
    });
  });

  group('parseSiteOrigin', () {
    test('保留协议、主机与端口', () {
      expect(
        parseSiteOrigin('https://example.com:8443/house/view?id=1').toString(),
        'https://example.com:8443',
      );
    });

    test('非法链接返回 null', () {
      expect(parseSiteOrigin('not a url'), isNull);
      expect(parseSiteOrigin(''), isNull);
    });
  });

  group('normalizeToken', () {
    test('已是 Bearer 前缀时保持不变', () {
      expect(normalizeToken('Bearer abc.def.ghi'), 'Bearer abc.def.ghi');
    });

    test('JWT 本体自动补 Bearer', () {
      expect(normalizeToken('abc.def.ghi'), 'Bearer abc.def.ghi');
    });

    test('空 Token 返回空字符串', () {
      expect(normalizeToken('  '), '');
    });
  });

  group('sanitizeFileName', () {
    test('替换路径分隔符与空白', () {
      expect(sanitizeFileName('1F / 主楼:东'), '1F_主楼_东');
    });

    test('空名称回退为 floor', () {
      expect(sanitizeFileName(''), 'floor');
      expect(sanitizeFileName('///'), 'floor');
    });
  });

  group('parseFloorTree', () {
    test('兼容 {data: [...]} 外壳', () {
      final tree = parseFloorTree({
        'code': '00000',
        'data': [
          {
            'data': {'id': 'campus-1', 'name': '南湖校区'},
            'children': [
              {
                'data': {'id': 'building-1', 'name': '主楼'},
                'children': [
                  {
                    'data': {'id': 'floor-1', 'name': '一层'},
                    'children': [],
                  },
                ],
              },
            ],
          },
        ],
      });

      expect(tree, hasLength(1));
      final campus = tree.single;
      expect(campus.id, 'campus-1');
      expect(campus.name, '南湖校区');
      expect(campus.descendants, hasLength(3));
      expect(campus.children.single.children.single.id, 'floor-1');
    });

    test('兼容直接数组与 key/title 字段', () {
      final tree = parseFloorTree([
        {
          'key': 'b-1',
          'title': '主楼',
          'children': [
            {'key': 'f-1', 'title': '一层', 'children': []},
          ],
        },
      ]);

      expect(tree.single.id, 'b-1');
      expect(tree.single.name, '主楼');
      expect(tree.single.children.single.name, '一层');
    });

    test('空响应返回空列表', () {
      expect(parseFloorTree(null), isEmpty);
      expect(parseFloorTree(<dynamic>[]), isEmpty);
    });
  });

  group('BuildingStatus', () {
    FloorInfo info(String id, {String? image, String? detail}) => FloorInfo(
          id: id,
          name: id,
          buildingId: 'building-1',
          buildingName: '主楼',
          campusId: 'campus-1',
          campusName: '南湖校区',
          cadPath: image == null ? '' : 'cad-$id',
          imagePath: image,
          detailPath: detail,
          roomCount: 1,
          raw: const {},
        );

    FloorCrawlResult result(List<FloorInfo> floors) => FloorCrawlResult(
          sourceUrl: 'http://example.com',
          origin: 'http://example.com',
          buildingId: 'building-1',
          buildingName: '主楼',
          campusId: 'campus-1',
          campusName: '南湖校区',
          floors: floors,
          outputDir: '/tmp',
          manifestPath: '/tmp/floors.json',
          crawledAt: DateTime(2026, 10, 21),
        );

    test('所有楼层都拿到图片才算已完成', () {
      final status = BuildingStatus.fromResult(
        2,
        result([
          info('1', image: '/tmp/1.jpg', detail: '/tmp/1.json'),
          info('2', image: '/tmp/2.png', detail: '/tmp/2.json'),
        ]),
      );
      expect(status.completed, isTrue);
      expect(status.crawledFloors, 2);
      expect(status.imageCount, 2);
      expect(status.label, '已完成');
    });

    test('缺图片或没有本地数据时为未完成', () {
      final missingImage = BuildingStatus.fromResult(
        2,
        result([
          info('1', image: '/tmp/1.jpg', detail: '/tmp/1.json'),
          info('2'),
        ]),
      );
      expect(missingImage.completed, isFalse);
      expect(missingImage.imageCount, 1);
      expect(missingImage.label, '未完成');

      final empty = BuildingStatus.fromResult(3, null);
      expect(empty.completed, isFalse);
      expect(empty.crawledFloors, 0);
    });
  });

  group('defaultFloorSelectionIndex', () {
    FloorInfo floor(String name) => FloorInfo(
          id: name,
          name: name,
          buildingId: 'building-1',
          buildingName: '主楼',
          campusId: 'campus-1',
          campusName: '南湖校区',
          cadPath: '',
          imagePath: null,
          detailPath: null,
          roomCount: 0,
          raw: const {},
        );

    test('列表以 B1 开头时默认选中 F1', () {
      final floors = ['B1', 'F1', 'F2'].map(floor).toList();
      expect(defaultFloorSelectionIndex(floors), 1);
    });

    test('兼容 1F / 01F / 一层 等命名', () {
      expect(defaultFloorSelectionIndex([floor('1F'), floor('2F')]), 0);
      expect(defaultFloorSelectionIndex([floor('B1'), floor('01F')]), 1);
      expect(defaultFloorSelectionIndex([floor('B1'), floor('一层')]), 1);
    });

    test('没有一层时回退到第一层', () {
      final floors = ['B1', 'F2'].map(floor).toList();
      expect(defaultFloorSelectionIndex(floors), 0);
      expect(defaultFloorSelectionIndex(const []), 0);
    });
  });

  test('完整爬取流程（本地 mock 平台）', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final authHeaders = <String?>[];
    final pngBytes = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3];

    server.listen((request) async {
      final path = request.uri.path;
      if (path == '/api/house-base/personal/visual/building/floor/tree') {
        authHeaders.add(request.headers.value(HttpHeaders.authorizationHeader));
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'code': '0',
          'data': [
            {
              'data': {'id': 'campus-1', 'name': '南湖校区'},
              'children': [
                {
                  'data': {'id': 'building-1', 'name': '主楼'},
                  'children': [
                    {
                      'data': {'id': 'floor-1', 'name': '一层'},
                      'children': <dynamic>[],
                    },
                    {
                      'data': {'id': 'floor-2', 'name': '二层'},
                      'children': <dynamic>[],
                    },
                  ],
                },
              ],
            },
          ],
        }));
      } else if (path ==
              '/api/house-base/personal/visual/building/floor/floor-1' ||
          path == '/api/house-base/personal/visual/building/floor/floor-2') {
        final floorId = path.split('/').last;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'code': '0',
          'data': {
            'statisticsRoomVo': {'cadPath': 'floor/$floorId.png'},
            'roomDetailVo': [
              {'roomId': 'room-1'},
              {'roomId': 'room-2'},
            ],
          },
        }));
      } else if (path.startsWith('/api/base/r/floor/')) {
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(pngBytes);
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });

    final tempDir = await Directory.systemTemp.createTemp('floor_crawl_test_');
    addTearDown(() async {
      await server.close(force: true);
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    final logs = <String>[];
    final origin = 'http://127.0.0.1:${server.port}';
    final result = await FloorCrawler(
      pageUrl: '$origin/house/house-base-decision/personal/view/'
          'building-1?id=building-1',
      token: 'abc.def.ghi',
      outputDir: tempDir.path,
      addLog: logs.add,
    ).run();

    expect(authHeaders, everyElement('Bearer abc.def.ghi'));
    expect(result.buildingName, '主楼');
    expect(result.floors, hasLength(2));
    expect(result.floors.first.roomCount, 2);
    expect(result.floors.first.name, '一层');
    expect(result.floors.every((f) => f.hasImage), isTrue);
    expect(File(result.manifestPath).existsSync(), isTrue);
    expect(File(result.floors.first.imagePath!).lengthSync(), pngBytes.length);
    expect(File(result.floors.first.detailPath!).existsSync(), isTrue);

    final manifest =
        jsonDecode(File(result.manifestPath).readAsStringSync()) as Map;
    expect(manifest['buildingId'], 'building-1');
    expect(manifest['floors'], hasLength(2));
  });
}
