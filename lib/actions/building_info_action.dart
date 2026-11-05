import 'dart:convert';
import 'dart:io';

import 'building_photo_action.dart';
import 'floor_action.dart';
import 'mcp_client.dart';

/// 从房产平台自动采集每栋楼的楼照片与简介。
///
/// 数据接口：`GET /api/house-base/personal/visual/map/<campusId>/sign?attributeCode=GF`
/// 返回 `list`，每栋楼含 `attachImg`（逗号分隔多张照片 ID，取第一张）、
/// `deptNum`（使用单位数）、`floorArea`（建筑面积）、`useArea`（使用面积）
/// 与 `backup3`（文字简介）。照片走 `GET /api/base/r/<photoId>`。
///
/// 与楼层爬取一样，通过 Chrome MCP 在页面上下文 fetch，复用浏览器登录态。
class BuildingInfoCrawler {
  final McpChromeSession session;
  final void Function(String) addLog;

  const BuildingInfoCrawler({required this.session, required this.addLog});

  /// 拉取某校区全部楼栋信息（精简字段，避免传输整份地图数据）。
  Future<List<BuildingInfo>> loadCampus(String campusId) async {
    addLog('--- 加载校区楼栋信息（$campusId）---\n');
    final result = await session.evaluate(_campusInfoScript(campusId));
    if (result is Map && result['error'] != null) {
      final text = '${result['error']} ${result['message'] ?? ''}';
      if (text.contains('401')) {
        throw const FloorCrawlException(
            '未检测到登录态（HTTP 401），请先在 Chrome 窗口登录平台后重试。');
      }
      throw FloorCrawlException('加载楼栋信息失败: $text');
    }
    final infos = parseBuildingInfoList(result);
    if (infos.isEmpty) {
      // 「其他」等校区没有可视化楼栋数据，不算登录/接口故障。
      addLog('平台未返回该校区楼栋信息（可能没有可视化数据）\n');
      return infos;
    }
    addLog('平台返回 ${infos.length} 栋楼\n');
    return infos;
  }

  /// 下载楼照片字节；失败返回 null（不中断整批采集）。
  Future<List<int>?> fetchPhoto(String photoId) async {
    final result = await session.evaluate(_photoScript(photoId));
    if (result is Map && result['error'] != null) {
      addLog('  照片 $photoId 下载失败: ${result['error']} '
          '${result['message'] ?? ''}\n');
      return null;
    }
    if (result is Map && result['base64'] is String) {
      try {
        return base64Decode(result['base64'] as String);
      } catch (e) {
        addLog('  照片 $photoId 解码失败: $e\n');
        return null;
      }
    }
    addLog('  照片 $photoId 返回格式异常: $result\n');
    return null;
  }

  /// 批量采集当前校区每栋楼的一张照片 + 简介。
  ///
  /// [onlyMissing] 为 true 时跳过「已有照片且有简介」的楼，支持断点续采。
  Future<BuildingInfoCollectionResult> collectCampus({
    required FloorNode campus,
    required String outputDir,
    bool onlyMissing = true,
    bool Function()? shouldStop,
    void Function(int done, int total, String buildingName)? onProgress,
  }) async {
    final infos = await loadCampus(campus.id);
    final byId = <String, BuildingInfo>{
      for (final info in infos) info.id: info,
    };

    final base =
        outputDir.trim().isEmpty ? defaultFloorOutputDir() : outputDir.trim();
    final summaryDir = Directory('$base/building_info');
    await summaryDir.create(recursive: true);
    await File('${summaryDir.path}/${campus.id}.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'campusId': campus.id,
        'campusName': campus.name,
        'collectedAt': DateTime.now().toIso8601String(),
        'buildings': infos.map((info) => info.toJson()).toList(),
      }),
    );
    addLog('已保存校区楼栋信息: ${summaryDir.path}/${campus.id}.json\n');

    final result = BuildingInfoCollectionResult()
      ..total = campus.children.length
      ..platformCount = infos.length;
    final buildings = campus.children;
    for (var i = 0; i < buildings.length; i++) {
      if (shouldStop?.call() == true) {
        result.stopped = true;
        addLog('收到停止请求，保留已采集结果\n');
        break;
      }
      final building = buildings[i];
      onProgress?.call(i + 1, buildings.length, building.name);
      final dir = buildingDir(outputDir, building);
      final info = byId[building.id];
      if (info == null) {
        result.missingInfo++;
        result.failures.add('${building.name}: 平台无该楼信息');
        continue;
      }
      if (onlyMissing &&
          await BuildingPhotoStore.resolve(dir) != null &&
          await BuildingPhotoStore.hasInfo(dir)) {
        result.skipped++;
        continue;
      }

      if (info.firstPhotoId.isEmpty) {
        await BuildingPhotoStore.saveInfo(dir, info);
        result.noPhoto++;
        result.failures.add('${building.name}: 平台未上传楼照片（已保存简介）');
        addLog('  ${building.name} 平台未上传楼照片（仅保存简介）\n');
        continue;
      }

      final captured = await _saveOne(dir, info, building.name);
      if (captured) {
        result.captured++;
      } else {
        result.failed++;
        result.failures.add('${building.name}: 照片下载失败');
      }
      if (i < buildings.length - 1) {
        await Future.delayed(const Duration(milliseconds: 60));
      }
    }
    addLog('采集结束：${result.summary}\n');
    return result;
  }

  /// 重新采集单栋楼（用于预览里的「重新采集当前楼」）。
  Future<BuildingInfo?> collectBuilding({
    required FloorNode campus,
    required FloorNode building,
    required String outputDir,
  }) async {
    final infos = await loadCampus(campus.id);
    BuildingInfo? target;
    for (final info in infos) {
      if (info.id == building.id) {
        target = info;
        break;
      }
    }
    if (target == null) {
      throw const FloorCrawlException('平台未返回该楼栋的信息');
    }
    final dir = buildingDir(outputDir, building);
    await _saveOne(dir, target, building.name);
    return target;
  }

  Future<bool> _saveOne(
      String dir, BuildingInfo info, String buildingName) async {
    await BuildingPhotoStore.saveInfo(dir, info);
    final photoId = info.firstPhotoId;
    if (photoId.isEmpty) {
      addLog('  $buildingName 平台未上传楼照片（仅保存简介）\n');
      return false;
    }
    final bytes = await fetchPhoto(photoId);
    if (bytes == null) return false;
    try {
      final path = await BuildingPhotoStore.saveBytes(dir, bytes);
      addLog('  已采集 $buildingName：${info.statsLine} · '
          '${formatBytes(bytes.length)} · $path\n');
      return true;
    } catch (e) {
      addLog('  $buildingName 照片保存失败: $e\n');
      return false;
    }
  }
}

/// 楼栋本地数据目录，与楼层爬取、页面预览共用同一规则。
String buildingDir(String outputDir, FloorNode building) {
  final base = outputDir.trim().isEmpty
      ? defaultFloorOutputDir()
      : outputDir.trim();
  return '$base/${sanitizeFileName(building.name)}_${building.id}';
}

String _campusInfoScript(String campusId) => '''
(async () => {
  const campusId = '$campusId';
  const token = localStorage.getItem('auth._token.local') || '';
  let res;
  try {
    res = await fetch('/api/house-base/personal/visual/map/' + campusId + '/sign?attributeCode=GF', {
      headers: { Authorization: token, Accept: 'application/json, text/plain, */*' }
    });
  } catch (e) {
    return { error: 'FETCH_ERROR', message: String(e) };
  }
  const text = await res.text();
  if (!res.ok) return { error: 'HTTP ' + res.status, message: text.slice(0, 300) };
  let data;
  try {
    data = JSON.parse(text);
  } catch (e) {
    return { error: 'INVALID_JSON', message: text.slice(0, 300) };
  }
  const list = (data && data.list) || [];
  return { list: list.map(b => ({
    id: b.id,
    name: b.name,
    attachImg: b.attachImg || '',
    deptNum: b.deptNum,
    floorArea: b.floorArea,
    useArea: b.useArea,
    address: b.address || '',
    description: b.backup3 || ''
  })) };
})()
''';

String _photoScript(String photoId) => '''
(async () => {
  const id = '$photoId';
  const token = localStorage.getItem('auth._token.local') || '';
  let res;
  try {
    res = await fetch('/api/base/r/' + id, {
      headers: { Authorization: token }
    });
  } catch (e) {
    return { error: 'FETCH_ERROR', message: String(e) };
  }
  if (!res.ok) {
    return { error: 'HTTP ' + res.status, message: (await res.text()).slice(0, 200) };
  }
  const buf = await res.arrayBuffer();
  const bytes = new Uint8Array(buf);
  let binary = '';
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
  }
  return { base64: btoa(binary), bytes: bytes.length };
})()
''';
