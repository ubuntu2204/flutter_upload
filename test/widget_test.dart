import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_upload/floor_page.dart';

void main() {
  testWidgets('楼层管理页渲染输入区与爬取按钮', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FloorPage(
          initialToken: '',
          initialOutputDir: '/tmp/floor_data',
          onAuthSaved: (_, __) async {},
        ),
      ),
    );

    expect(find.text('楼层管理'), findsOneWidget);
    expect(find.text('楼栋页面链接'), findsOneWidget);
    expect(find.text('登录 Token（Authorization）'), findsOneWidget);
    expect(find.text('爬取楼层'), findsOneWidget);
    expect(find.text('填写链接与 Token 后点击「爬取楼层」'), findsOneWidget);
  });
}
