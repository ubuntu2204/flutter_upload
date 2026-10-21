import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_upload/floor_page.dart';

void main() {
  testWidgets('楼层管理页渲染 Chrome MCP 控制区', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FloorPage(
          initialOutputDir: '/tmp/floor_data',
          onOutputDirSaved: (_) async {},
        ),
      ),
    );

    expect(find.text('楼层管理'), findsOneWidget);
    expect(find.text('启动登录 Chrome'), findsOneWidget);
    expect(find.text('加载楼栋'), findsOneWidget);
    expect(find.text('爬取当前楼栋'), findsOneWidget);
    expect(find.text('本地输出目录'), findsOneWidget);
    expect(find.text('启动 Chrome 登录后，点击「加载楼栋」'), findsOneWidget);
  });
}
