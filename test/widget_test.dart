import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_upload/floor_page.dart';
import 'package:flutter_upload/widgets/floor_map_view.dart';

void main() {
  group('房间号横竖排判定', () {
    test('主楼 F1 的 109（CAD 49x97 窄长房间）在常见缩放下恒竖排', () {
      for (final fit in [0.25, 0.44, 0.74, 1.0]) {
        expect(
          shouldStackRoomLabel(
            screenWidth: 49 * fit,
            screenHeight: 97 * fit,
            charCount: 3,
          ),
          isTrue,
          reason: 'fit=$fit 时 109 应逐字竖排',
        );
      }
    });

    test('横长房间保持水平', () {
      expect(
        shouldStackRoomLabel(
          screenWidth: 97,
          screenHeight: 49,
          charCount: 3,
        ),
        isFalse,
      );
    });

    test('高度放不下逐字排列的窄房间不竖排', () {
      expect(
        shouldStackRoomLabel(
          screenWidth: 12,
          screenHeight: 20,
          charCount: 6,
        ),
        isFalse,
      );
    });
  });

  testWidgets('楼层管理页渲染 Chrome MCP 控制区', (WidgetTester tester) async {
    // 独立的空目录，避免真实 tree.json 缓存影响空状态断言。
    // testWidgets 运行在 FakeAsync 中，真实异步 IO 不会完成，故用同步版本。
    final tempDir =
        Directory.systemTemp.createTempSync('floor_page_widget_test_');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    // 桌面应用窗口远大于测试默认 800x600，放大避免固定日志区挤压内容。
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;

    await tester.pumpWidget(
      MaterialApp(
        home: FloorPage(
          initialOutputDir: tempDir.path,
          onOutputDirSaved: (_) async {},
        ),
      ),
    );

    expect(find.text('楼层管理'), findsOneWidget);
    expect(find.text('启动登录 Chrome'), findsOneWidget);
    expect(find.text('加载楼栋'), findsOneWidget);
    expect(find.text('爬取当前楼栋'), findsOneWidget);
    expect(find.text('采集楼照片与简介'), findsOneWidget);
    expect(find.text('重新采集当前楼'), findsOneWidget);
    // 重构后移除 vtracer「切换矢量」按钮，预览改为「底图 + 房间矢量叠加」。
    expect(find.text('切换矢量'), findsNothing);
    expect(find.byTooltip('打开输出目录'), findsOneWidget);
    expect(find.text('本地输出目录'), findsOneWidget);
    expect(
      find.text('本地暂无楼栋缓存。登录后点击「加载楼栋」，成功加载过一次即可离线浏览'),
      findsOneWidget,
    );
  });
}
