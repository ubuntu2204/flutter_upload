import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_upload/floor_page.dart';

void main() {
  testWidgets('楼层管理页渲染 Chrome MCP 控制区', (WidgetTester tester) async {
    // 独立的空目录，避免真实 tree.json 缓存影响空状态断言。
    // testWidgets 运行在 FakeAsync 中，真实异步 IO 不会完成，故用同步版本。
    final tempDir =
        Directory.systemTemp.createTempSync('floor_page_widget_test_');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

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
    expect(find.text('本地输出目录'), findsOneWidget);
    expect(
      find.text('本地暂无楼栋缓存。登录后点击「加载楼栋」，成功加载过一次即可离线浏览'),
      findsOneWidget,
    );
  });
}
