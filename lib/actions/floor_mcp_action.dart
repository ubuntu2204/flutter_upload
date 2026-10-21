import 'dart:convert';
import 'dart:io';

import 'chrome_launcher.dart';
import 'floor_action.dart';
import 'mcp_client.dart';

/// 基于 Chrome MCP 的楼层爬取器。
///
/// 前提：用户已在专用 Chrome 中手动登录平台。爬取时通过 MCP 在页面上下文
/// 调用 fetch，复用浏览器里的登录态，不需要在应用里保存 Token。
class ChromeFloorCrawler {
  final McpChromeSession session;
  final String outputDir;
  final void Function(String) addLog;

  ChromeFloorCrawler({
    required this.session,
    required this.outputDir,
    required this.addLog,
  });

  /// 加载校区 → 楼栋 → 楼层树。
  ///
  /// 接口不带 buildingId 时返回全部校区/楼栋；未登录时返回 401。
  Future<List<FloorNode>> loadTree() async {
    addLog('--- 加载校区/楼栋树 ---\n');
    final result = await session.evaluate(_treeScript);
    if (result is Map && result['error'] != null) {
      throw FloorCrawlException(_loginHint(result));
    }
    final tree = parseFloorTree(result);
    if (tree.isEmpty) {
      throw const FloorCrawlException('楼栋树为空，请确认账号有公房管理权限。');
    }
    final buildings = tree.fold<int>(0, (sum, c) => sum + c.children.length);
    final floors = tree.fold<int>(
        0,
        (sum, c) =>
            sum + c.children.fold<int>(0, (s, b) => s + b.children.length));
    addLog('校区 ${tree.length} 个，楼栋 $buildings 栋，楼层 $floors 层\n');
    return tree;
  }

  /// 爬取指定楼栋的楼层详情与户型图，保存到本地。
  Future<FloorCrawlResult> crawlBuilding({
    required List<FloorNode> tree,
    required FloorNode campus,
    required FloorNode building,
    void Function(int completed, int total, FloorInfo? floor)? onProgress,
  }) async {
    final floors = building.children;
    if (floors.isEmpty) {
      throw const FloorCrawlException('该楼栋下没有楼层数据。');
    }

    final dir = Directory(_outputDirFor(building));
    final imageDir = Directory('${dir.path}/images');
    final detailDir = Directory('${dir.path}/details');
    await imageDir.create(recursive: true);
    await detailDir.create(recursive: true);

    addLog('开始爬取：${campus.name} / ${building.name}，共 ${floors.length} 层\n');
    final infos = <FloorInfo>[];
    for (var i = 0; i < floors.length; i++) {
      final node = floors[i];
      final index = i + 1;
      addLog('--- [$index/${floors.length}] ${node.name} ---\n');

      Map<String, dynamic>? detail;
      String cadPath = '';
      var roomCount = 0;
      String? detailPath;
      String? imagePath;

      try {
        final payload = await session.evaluate(_floorScript(node.id));
        if (payload is Map && payload['error'] != null) {
          addLog('  楼层详情失败: ${payload['error']} ${payload['message'] ?? ''}\n');
        } else if (payload is Map) {
          final detailValue = unwrapPayload(payload['detail']);
          if (detailValue is Map) {
            detail = Map<String, dynamic>.from(detailValue);
            final srv = detail['statisticsRoomVo'];
            if (srv is Map) {
              cadPath = (srv['cadPath'] ?? '').toString();
              final rooms = detail['roomDetailVo'];
              if (rooms is List) roomCount = rooms.length;
            }
            cadPath = cadPath.isEmpty
                ? (detail['cadPath'] ?? '').toString()
                : cadPath;
          }

          final image = payload['image'];
          if (image is Map && image['error'] != null) {
            addLog('  图片下载失败: ${image['error']} ${image['body'] ?? ''}\n');
          } else if (image is Map && image['base64'] is String) {
            final base64Text = image['base64'] as String;
            final bytes = base64Decode(base64Text);
            final ext = imageExtensionFromBytes(bytes);
            final file =
                File('${imageDir.path}/${index.toString().padLeft(2, '0')}_'
                    '${sanitizeFileName(node.name)}_${node.id}.$ext');
            await file.writeAsBytes(bytes);
            imagePath = file.path;
            addLog('  已保存: ${file.path} (${formatBytes(bytes.length)})\n');
          }
        }
      } catch (e) {
        addLog('  楼层爬取异常: $e\n');
      }

      if (detail != null) {
        final file = File('${detailDir.path}/${node.id}.json');
        await file
            .writeAsString(const JsonEncoder.withIndent('  ').convert(detail));
        detailPath = file.path;
      }

      final info = FloorInfo(
        id: node.id,
        name: node.name,
        buildingId: building.id,
        buildingName: building.name,
        campusId: campus.id,
        campusName: campus.name,
        cadPath: cadPath,
        imagePath: imagePath,
        detailPath: detailPath,
        roomCount: roomCount,
        raw: node.raw,
      );
      infos.add(info);
      onProgress?.call(index, floors.length, info);
    }

    final manifest = <String, dynamic>{
      'sourceUrl': platformCampusUrl,
      'origin': 'http://210.30.202.99',
      'campusId': campus.id,
      'campusName': campus.name,
      'buildingId': building.id,
      'buildingName': building.name,
      'crawledAt': DateTime.now().toIso8601String(),
      'floors': infos
          .map((f) => {
                'id': f.id,
                'name': f.name,
                'campusId': f.campusId,
                'buildingId': f.buildingId,
                'cadPath': f.cadPath,
                'roomCount': f.roomCount,
                'image': f.imagePath == null
                    ? null
                    : _relativeTo(dir.path, f.imagePath!),
                'detail': f.detailPath == null
                    ? null
                    : _relativeTo(dir.path, f.detailPath!),
                'raw': f.raw,
              })
          .toList(),
      'tree': tree.map(_nodeToJson).toList(),
    };
    final manifestFile = File('${dir.path}/floors.json');
    await manifestFile
        .writeAsString(const JsonEncoder.withIndent('  ').convert(manifest));
    addLog('已保存楼层清单: ${manifestFile.path}\n');

    return FloorCrawlResult(
      sourceUrl: platformCampusUrl,
      origin: 'http://210.30.202.99',
      buildingId: building.id,
      buildingName: building.name,
      campusId: campus.id,
      campusName: campus.name,
      floors: infos,
      outputDir: dir.path,
      manifestPath: manifestFile.path,
      crawledAt: DateTime.now(),
    );
  }

  String _outputDirFor(FloorNode building) {
    final base = outputDir.trim().isEmpty ? defaultFloorOutputDir() : outputDir;
    return '$base/${sanitizeFileName(building.name)}_${building.id}';
  }

  String _loginHint(Map<dynamic, dynamic> result) {
    final error = result['error'];
    final message = result['message'] ?? '';
    if (error == 'HTTP 401' || message.toString().contains('401')) {
      return '未检测到登录态（$error）。请先在 Chrome 窗口登录平台，再重试。';
    }
    return '加载楼栋失败: $error $message';
  }

  Map<String, dynamic> _nodeToJson(FloorNode node) => {
        'id': node.id,
        'name': node.name,
        'parentId': node.parentId,
        'campusId': node.campusId,
        'children': node.children.map(_nodeToJson).toList(),
      };

  String _relativeTo(String base, String path) {
    final prefix = base.endsWith('/') ? base : '$base/';
    return path.startsWith(prefix) ? path.substring(prefix.length) : path;
  }
}

/// 在页面上下文调用楼层树接口。
const String _treeScript = r'''
(async () => {
  const token = localStorage.getItem('auth._token.local') || '';
  const res = await fetch('/api/house-base/personal/visual/building/floor/tree?attributeCode=GF', {
    headers: { Authorization: token, Accept: 'application/json, text/plain, */*' }
  });
  const text = await res.text();
  if (!res.ok) return { error: 'HTTP ' + res.status, message: text.slice(0, 500) };
  try {
    return JSON.parse(text);
  } catch (e) {
    return { error: 'INVALID_JSON', message: text.slice(0, 500) };
  }
})()
''';

/// 在页面上下文获取单层详情和户型图（base64）。
String _floorScript(String floorId) => '''
(async () => {
  const floorId = '$floorId';
  const token = localStorage.getItem('auth._token.local') || '';
  const detailRes = await fetch('/api/house-base/personal/visual/building/floor/' + floorId + '?type=byDep', {
    headers: { Authorization: token, Accept: 'application/json, text/plain, */*' }
  });
  const detailText = await detailRes.text();
  if (!detailRes.ok) {
    return { error: 'HTTP ' + detailRes.status, message: detailText.slice(0, 500) };
  }
  let detail;
  try {
    detail = JSON.parse(detailText);
  } catch (e) {
    return { error: 'INVALID_JSON', message: detailText.slice(0, 500) };
  }
  const srv = detail.statisticsRoomVo || {};
  const cad = srv.cadPath || detail.cadPath || '';
  if (!cad) return { detail: detail, image: null };

  const path = String(cad).replace(/^\\/+/, '');
  const imgRes = await fetch('/api/base/r/' + path, { headers: { Authorization: token } });
  if (!imgRes.ok) {
    const body = (await imgRes.text()).slice(0, 200);
    return { detail: detail, image: { error: 'HTTP ' + imgRes.status, body: body } };
  }
  const buf = await imgRes.arrayBuffer();
  const bytes = new Uint8Array(buf);
  let binary = '';
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
  }
  return { detail: detail, image: { base64: btoa(binary), bytes: bytes.length } };
})()
''';
