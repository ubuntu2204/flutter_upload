import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_upload/actions/floor_vector_action.dart';

void main() {
  test('原图路径对应同楼栋 vectors 目录下的 SVG', () {
    expect(
      floorVectorPathForImage('/tmp/楼栋_1/images/01_F1_100.floor.png'),
      '/tmp/楼栋_1/vectors/01_F1_100.floor.svg',
    );
    expect(
      floorVectorPathForImage('/tmp/a/images/floor.jpg'),
      '/tmp/a/vectors/floor.svg',
    );
  });

  test('转换动作解析进程进度与汇总', () async {
    final temp = Directory.systemTemp.createTempSync('floor_vector_action_');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final project = Directory('${temp.path}/project');
    final tool = Directory('${project.path}/tool')..createSync(recursive: true);
    final output = Directory('${temp.path}/floors')..createSync();
    File('${tool.path}/vectorize_floor_maps.py').writeAsStringSync('''
import json
print(json.dumps({"type":"progress","done":1,"total":2,"converted":1,"skipped":0,"failed":0,"current":"主楼 / F1","error":""}))
print(json.dumps({"type":"progress","done":2,"total":2,"converted":1,"skipped":1,"failed":0,"current":"主楼 / F2","error":""}))
print(json.dumps({"type":"result","total":2,"converted":1,"skipped":1,"failed":0,"svgBytes":2048}))
''');

    final progress = <FloorVectorProgress>[];
    final logs = <String>[];
    final result = await convertFloorMapsToSvg(
      output.path,
      projectDir: project.path,
      onProgress: progress.add,
      addLog: logs.add,
    );

    expect(progress, hasLength(2));
    expect(progress.last.current, '主楼 / F2');
    expect(progress.last.fraction, 1.0);
    expect(result.total, 2);
    expect(result.converted, 1);
    expect(result.skipped, 1);
    expect(result.failed, 0);
    expect(result.svgBytes, 2048);
    expect(logs.join(), contains('已处理 2/2'));
  });

  test('输出目录不存在时给出明确错误', () async {
    expect(
      () => convertFloorMapsToSvg('/tmp/not-existing-floor-vector-root'),
      throwsA(
        isA<FloorVectorException>().having(
          (error) => error.message,
          'message',
          contains('楼层输出目录不存在'),
        ),
      ),
    );
  });
}
