import 'dart:convert';
import 'dart:io';

/// 楼层数据接口前缀（页面 origin 之后的部分）。
const String _apiPrefix = '/api/house-base';

/// 楼层户型图（PNG）接口前缀。
const String _imagePrefix = '/api/base/r/';

/// 默认的楼层数据输出目录（用户主目录下）。
String defaultFloorOutputDir() {
  final home = Platform.environment['HOME'] ?? Directory.current.path;
  return '$home/floor_data';
}

/// 从页面链接中解析楼栋 ID。
///
/// 支持：
/// - `.../personal/view/1294698345147666432?id=1294698345147666432&name=...`
/// - `...?id=1294698345147666432`
/// - 直接传纯数字 ID
String? parseBuildingId(String input) {
  final text = input.trim();
  if (text.isEmpty) return null;
  if (RegExp(r'^\d+$').hasMatch(text)) return text;

  Uri? uri = Uri.tryParse(text);
  if (uri != null) {
    final id = uri.queryParameters['id'];
    if (id != null && id.isNotEmpty) return id;

    final segments =
        uri.pathSegments.where((s) => s.isNotEmpty).toList(growable: false);
    final viewIndex = segments.indexOf('view');
    if (viewIndex >= 0 && viewIndex + 1 < segments.length) {
      final candidate = segments[viewIndex + 1];
      if (candidate.isNotEmpty) return candidate;
    }
    for (final segment in segments.reversed) {
      if (RegExp(r'^\d{6,}$').hasMatch(segment)) return segment;
    }
  }
  return null;
}

/// 解析页面链接的协议 + 主机（例如 `http://210.30.202.99`）。
Uri? parseSiteOrigin(String input) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  return Uri(
      scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null);
}

/// 规范化 Token：浏览器 localStorage 里通常已是 `Bearer xxx`，
/// 若只粘贴了 JWT 本体则自动补上 `Bearer `。
String normalizeToken(String raw) {
  final token = raw.trim();
  if (token.isEmpty) return '';
  if (RegExp(r'^[A-Za-z]+ ', caseSensitive: false).hasMatch(token)) {
    return token;
  }
  if (token.split('.').length == 3) return 'Bearer $token';
  return token;
}

/// 楼层树节点。平台返回三层结构：校区 → 楼栋 → 楼层。
class FloorNode {
  final String id;
  final String name;
  final String parentId;
  final String campusId;
  final List<FloorNode> children;
  final Map<String, dynamic> raw;

  const FloorNode({
    required this.id,
    required this.name,
    required this.parentId,
    required this.campusId,
    required this.children,
    required this.raw,
  });

  factory FloorNode.fromJson(Map<String, dynamic> json) {
    final nodeData = json['data'];
    final data = nodeData is Map ? Map<String, dynamic>.from(nodeData) : json;

    return FloorNode(
      id: (data['id'] ?? json['id'] ?? json['key'] ?? '').toString(),
      name: (data['name'] ?? json['name'] ?? json['title'] ?? '').toString(),
      parentId: (json['parentId'] ?? data['parentId'] ?? '').toString(),
      campusId: (data['baseCampusId'] ??
              json['baseCampusId'] ??
              data['campusId'] ??
              json['campusId'] ??
              '')
          .toString(),
      children: parseFloorTree(json['children'] ?? data['children']).toList(),
      raw: data,
    );
  }

  /// 序列化为本地缓存（保留层级与标识，不带 raw 以免重复存储子树）。
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'parentId': parentId,
        'baseCampusId': campusId,
        'children': children.map((child) => child.toJson()).toList(),
      };

  bool get hasChildren => children.isNotEmpty;

  /// 深度优先遍历当前节点及其所有后代。
  Iterable<FloorNode> get descendants sync* {
    yield this;
    for (final child in children) {
      yield* child.descendants;
    }
  }
}

/// 解析楼层树响应（兼容 `{data: [...]}` 与直接数组两种返回）。
List<FloorNode> parseFloorTree(dynamic payload) {
  final data = unwrapPayload(payload);
  if (data is List) {
    return data
        .whereType<Map>()
        .map((e) => FloorNode.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
  if (data is Map) {
    final map = Map<String, dynamic>.from(data);
    final list = map['records'] ?? map['list'] ?? map['children'];
    if (list is List) return parseFloorTree(list);
    return [FloorNode.fromJson(map)];
  }
  return const [];
}

/// 去掉平台的统一响应外壳，返回业务数据。
dynamic unwrapPayload(dynamic payload) {
  if (payload is Map) {
    final map = Map<String, dynamic>.from(payload);
    if (map.containsKey('data') && map['data'] != null) return map['data'];
  }
  return payload;
}

/// 单层楼的信息（爬取结果）。
class FloorInfo {
  final String id;
  final String name;
  final String buildingId;
  final String buildingName;
  final String campusId;
  final String campusName;
  final String cadPath;
  final String? imagePath;
  final String? detailPath;
  final int roomCount;
  final Map<String, dynamic> raw;

  const FloorInfo({
    required this.id,
    required this.name,
    required this.buildingId,
    required this.buildingName,
    required this.campusId,
    required this.campusName,
    required this.cadPath,
    required this.imagePath,
    required this.detailPath,
    required this.roomCount,
    required this.raw,
  });

  bool get hasImage => imagePath != null;
}

/// 默认选中一层（F1）；楼层列表通常以 B1 开头，直接取 0 会默认显示地下室。
/// 找不到一层时回退到第一层。
int defaultFloorSelectionIndex(List<FloorInfo> floors) {
  if (floors.isEmpty) return 0;
  for (var i = 0; i < floors.length; i++) {
    final name =
        floors[i].name.trim().toUpperCase().replaceAll(RegExp(r'\s+'), '');
    if (name == '一层' || RegExp(r'^(F|L)?0?1(F|楼|层)?$').hasMatch(name)) {
      return i;
    }
  }
  return 0;
}

/// 一次爬取任务的汇总结果。
class FloorCrawlResult {
  final String sourceUrl;
  final String origin;
  final String buildingId;
  final String buildingName;
  final String campusId;
  final String campusName;
  final List<FloorInfo> floors;
  final String outputDir;
  final String manifestPath;
  final DateTime crawledAt;

  const FloorCrawlResult({
    required this.sourceUrl,
    required this.origin,
    required this.buildingId,
    required this.buildingName,
    required this.campusId,
    required this.campusName,
    required this.floors,
    required this.outputDir,
    required this.manifestPath,
    required this.crawledAt,
  });
}

/// 楼栋本地获取状态。
class BuildingStatus {
  final int totalFloors;
  final int crawledFloors;
  final int imageCount;

  /// 平台实际有户型图的楼层数（cadPath 非空）。
  final int expectedImages;

  /// 已获取详情、但平台本身没有户型图的楼层数。
  final int noImageFloors;
  final bool completed;

  const BuildingStatus({
    required this.totalFloors,
    required this.crawledFloors,
    required this.imageCount,
    required this.expectedImages,
    required this.noImageFloors,
    required this.completed,
  });

  /// 完成标准：所有楼层详情都已获取，且平台存在的户型图都已下载。
  /// 平台本身没有户型图的楼层不算未完成。
  factory BuildingStatus.fromResult(int totalFloors, FloorCrawlResult? result) {
    final floors = result?.floors ?? const <FloorInfo>[];
    final crawled =
        floors.where((f) => f.detailPath != null || f.hasImage).length;
    final images = floors.where((f) => f.hasImage).length;
    final expectedImages = floors.where((f) => f.cadPath.isNotEmpty).length;
    final noImageFloors = floors
        .where((f) =>
            f.cadPath.isEmpty &&
            !f.hasImage &&
            (f.detailPath != null || f.roomCount > 0))
        .length;
    return BuildingStatus(
      totalFloors: totalFloors,
      crawledFloors: crawled,
      imageCount: images,
      expectedImages: expectedImages,
      noImageFloors: noImageFloors,
      completed:
          totalFloors > 0 && crawled >= totalFloors && images >= expectedImages,
    );
  }

  bool get hasNoImages => expectedImages == 0;

  String get label => completed ? '已完成' : '未完成';
}

/// 楼层爬取器：登录态通过 Authorization 头传入。
///
/// 流程：
/// 1. `GET /api/house-base/personal/visual/building/floor/tree` 拉取校区/楼栋/楼层树；
/// 2. 对每个楼层 `GET /api/house-base/personal/visual/building/floor/{id}?type=byDep`
///    获取 `statisticsRoomVo.cadPath` 与房间明细；
/// 3. 下载 `GET /api/base/r/{cadPath}` 户型图（PNG），连同 JSON 元数据落盘。
class FloorCrawler {
  final String pageUrl;
  final String token;
  final String outputDir;
  final void Function(String) addLog;

  FloorCrawler({
    required this.pageUrl,
    required this.token,
    required this.outputDir,
    required this.addLog,
  });

  /// 执行爬取，返回汇总结果。
  Future<FloorCrawlResult> run() async {
    final buildingId = parseBuildingId(pageUrl);
    if (buildingId == null) {
      throw const FloorCrawlException('无法从链接中解析楼栋 ID，请检查链接或直接填写 ID。');
    }
    final origin = parseSiteOrigin(pageUrl);
    if (origin == null) {
      throw const FloorCrawlException('无法解析站点地址，请填写完整的 http(s) 链接。');
    }
    final auth = normalizeToken(token);
    if (auth.isEmpty) {
      throw const FloorCrawlException('未填写登录 Token，无法访问楼层接口。');
    }

    addLog('楼栋 ID: $buildingId');
    addLog('接口站点: $origin');
    addLog('--- 1/3 获取楼层树 ---');

    final treeUri = origin.replace(
      path: '$_apiPrefix/personal/visual/building/floor/tree',
      queryParameters: {'attributeCode': 'GF', 'buildingId': buildingId},
    );
    final treePayload = await _getJson(treeUri, auth);
    final tree = parseFloorTree(treePayload);
    if (tree.isEmpty) {
      throw const FloorCrawlException('楼层树为空，可能是 Token 无权限或该楼栋没有楼层数据。');
    }
    addLog('楼层树节点: ${tree.first.descendants.length} 个');

    final context = _resolveBuilding(tree, buildingId);
    addLog('校区: ${context.campusName}  楼栋: ${context.buildingName}  '
        '楼层: ${context.floors.length} 层');
    if (context.floors.isEmpty) {
      throw const FloorCrawlException('该楼栋下没有楼层数据。');
    }

    final dir = Directory(_outputDirFor(context));
    final imageDir = Directory('${dir.path}/images');
    final detailDir = Directory('${dir.path}/details');
    await imageDir.create(recursive: true);
    await detailDir.create(recursive: true);

    final floors = <FloorInfo>[];
    for (var i = 0; i < context.floors.length; i++) {
      final node = context.floors[i];
      final index = i + 1;
      addLog('--- 2/3 获取楼层 $index/${context.floors.length}: '
          '${node.name} (${node.id}) ---');

      Map<String, dynamic>? detail;
      String cadPath = '';
      var roomCount = 0;
      try {
        final detailUri = origin.replace(
          path: '$_apiPrefix/personal/visual/building/floor/${node.id}',
          queryParameters: {'type': 'byDep'},
        );
        final payload = unwrapPayload(await _getJson(detailUri, auth));
        if (payload is Map) {
          detail = Map<String, dynamic>.from(payload);
          final roomVo = detail['statisticsRoomVo'];
          if (roomVo is Map) {
            cadPath = (roomVo['cadPath'] ?? '').toString();
            final rooms = detail['roomDetailVo'];
            if (rooms is List) roomCount = rooms.length;
          }
          cadPath =
              cadPath.isEmpty ? (detail['cadPath'] ?? '').toString() : cadPath;
        }
      } catch (e) {
        addLog('  楼层详情获取失败: $e');
      }

      String? detailPath;
      if (detail != null) {
        final file = File('${detailDir.path}/${node.id}.json');
        await file
            .writeAsString(const JsonEncoder.withIndent('  ').convert(detail));
        detailPath = file.path;
      }

      String? imagePath;
      if (cadPath.isEmpty) {
        addLog('  该楼层没有 cadPath（可能未上传户型图）');
      } else {
        addLog('--- 3/3 下载户型图: $cadPath ---');
        try {
          imagePath = await _downloadImage(
            origin: origin,
            cadPath: cadPath,
            token: auth,
            targetPrefix: '${imageDir.path}/'
                '${index.toString().padLeft(2, '0')}_'
                '${sanitizeFileName(node.name)}_${node.id}',
          );
        } catch (e) {
          addLog('  图片下载失败: $e');
        }
      }

      floors.add(FloorInfo(
        id: node.id,
        name: node.name,
        buildingId: context.buildingId,
        buildingName: context.buildingName,
        campusId: context.campusId,
        campusName: context.campusName,
        cadPath: cadPath,
        imagePath: imagePath,
        detailPath: detailPath,
        roomCount: roomCount,
        raw: node.raw,
      ));
    }

    final manifest = <String, dynamic>{
      'sourceUrl': pageUrl,
      'origin': origin.toString(),
      'buildingId': context.buildingId,
      'buildingName': context.buildingName,
      'campusId': context.campusId,
      'campusName': context.campusName,
      'crawledAt': DateTime.now().toIso8601String(),
      'floors': floors
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
      'tree': tree.map((n) => _nodeToJson(n)).toList(),
    };
    final manifestFile = File('${dir.path}/floors.json');
    await manifestFile
        .writeAsString(const JsonEncoder.withIndent('  ').convert(manifest));
    addLog('已保存楼层清单: ${manifestFile.path}');

    return FloorCrawlResult(
      sourceUrl: pageUrl,
      origin: origin.toString(),
      buildingId: context.buildingId,
      buildingName: context.buildingName,
      campusId: context.campusId,
      campusName: context.campusName,
      floors: floors,
      outputDir: dir.path,
      manifestPath: manifestFile.path,
      crawledAt: DateTime.now(),
    );
  }

  String _outputDirFor(_BuildingContext context) {
    final base = outputDir.trim().isEmpty ? defaultFloorOutputDir() : outputDir;
    final safeBuilding = sanitizeFileName(context.buildingName);
    return '$base/${safeBuilding}_${context.buildingId}';
  }

  /// 在树中定位目标楼栋，收集其下的楼层。
  _BuildingContext _resolveBuilding(List<FloorNode> tree, String buildingId) {
    // 先按 ID 精确匹配（楼栋节点）。
    for (final node in tree.expand((n) => n.descendants)) {
      if (node.id == buildingId && node.children.isNotEmpty) {
        final parent = _findParent(tree, node);
        return _BuildingContext(
          campusId: node.campusId.isNotEmpty
              ? node.campusId
              : parent?.id ?? tree.first.id,
          campusName: parent?.name ?? tree.first.name,
          buildingId: node.id,
          buildingName: node.name,
          floors: node.children,
        );
      }
    }

    // 回退 1：在任意节点的子节点中按 ID 找。
    for (final node in tree.expand((n) => n.descendants)) {
      for (final child in node.children) {
        if (child.id == buildingId) {
          return _BuildingContext(
            campusId: node.id,
            campusName: node.name,
            buildingId: child.id,
            buildingName: child.name,
            floors: child.children,
          );
        }
      }
    }

    // 回退 2：按页面默认逻辑取 校区→楼栋→楼层 的第一栋。
    if (tree.first.children.isNotEmpty) {
      final building = tree.first.children.first;
      if (building.children.isNotEmpty) {
        return _BuildingContext(
          campusId: tree.first.id,
          campusName: tree.first.name,
          buildingId: building.id,
          buildingName: building.name,
          floors: building.children,
        );
      }
      // 两层结构：校区节点下直接挂楼层。
      return _BuildingContext(
        campusId: tree.first.campusId,
        campusName: '',
        buildingId: tree.first.id,
        buildingName: tree.first.name,
        floors: tree.first.children,
      );
    }

    return _BuildingContext(
      campusId: tree.first.id,
      campusName: tree.first.name,
      buildingId: buildingId,
      buildingName: tree.first.name,
      floors: tree,
    );
  }

  FloorNode? _findParent(List<FloorNode> nodes, FloorNode target) {
    for (final node in nodes) {
      for (final child in node.children) {
        if (identical(child, target) || child.id == target.id) return node;
        final found = _findParent(node.children, target);
        if (found != null) return found;
      }
    }
    return null;
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

  Future<dynamic> _getJson(Uri uri, String token) async {
    final res = await _httpGet(uri, token: token);
    dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(res.bytes));
    } catch (_) {
      throw FloorCrawlException(
          '接口返回的不是 JSON（HTTP ${res.statusCode}）: ${res.preview()}');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final message =
          decoded is Map ? (decoded['message'] ?? decoded['msg']) : null;
      throw FloorCrawlException(
          '接口请求失败 HTTP ${res.statusCode}: ${message ?? res.preview()}');
    }
    if (decoded is Map) {
      final code = (decoded['code'] ?? '').toString();
      final success = code.isEmpty ||
          code == '0' ||
          code == '200' ||
          code.toLowerCase() == 'success';
      if (!success && decoded['data'] == null) {
        throw FloorCrawlException(
            '接口返回错误 code=$code: ${decoded['message'] ?? decoded['msg'] ?? ''}');
      }
    }
    return decoded;
  }

  /// 下载户型图。浏览器 `<img>` 不携带 Authorization，因此先匿名请求，
  /// 返回 401/403 时再带 Token 重试。
  Future<String> _downloadImage({
    required Uri origin,
    required String cadPath,
    required String token,
    required String targetPrefix,
  }) async {
    final path = cadPath.replaceFirst(RegExp(r'^/+'), '');
    final Uri uri;
    if (cadPath.startsWith('http://') || cadPath.startsWith('https://')) {
      uri = Uri.parse(cadPath);
    } else if (cadPath.startsWith('/api/')) {
      uri = origin.replace(path: cadPath);
    } else {
      uri = origin.replace(path: '$_imagePrefix$path');
    }
    var res = await _httpGet(uri);
    // 图片接口通常可匿名访问；若返回登录页/401，则带 Token 重试。
    if (res.statusCode == 401 ||
        res.statusCode == 403 ||
        !_looksLikeImage(res.bytes)) {
      final authed = await _httpGet(uri, token: token);
      if (authed.statusCode == 200 && _looksLikeImage(authed.bytes)) {
        res = authed;
      }
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw FloorCrawlException('HTTP ${res.statusCode}: ${res.preview()}');
    }
    if (!_looksLikeImage(res.bytes)) {
      throw FloorCrawlException('返回内容不是图片: ${res.preview()}');
    }
    final file = File('$targetPrefix.${imageExtensionFromBytes(res.bytes)}');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(res.bytes);
    addLog('  已保存: ${file.path} (${formatBytes(res.bytes.length)})');
    return file.path;
  }

  Future<_HttpResult> _httpGet(Uri uri, {String? token}) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(uri);
      request.headers
          .set(HttpHeaders.acceptHeader, 'application/json, text/plain, */*');
      if (token != null && token.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, token);
      }
      final response = await request.close();
      final bytes = await response.fold<List<int>>(
        <int>[],
        (buffer, chunk) => buffer..addAll(chunk),
      );
      return _HttpResult(statusCode: response.statusCode, bytes: bytes);
    } finally {
      client.close(force: true);
    }
  }

  bool _looksLikeImage(List<int> bytes) {
    if (bytes.length < 8) return false;
    // PNG
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return true;
    }
    // JPEG
    if (bytes[0] == 0xFF && bytes[1] == 0xD8) return true;
    // GIF
    if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) return true;
    return false;
  }
}

class _BuildingContext {
  final String campusId;
  final String campusName;
  final String buildingId;
  final String buildingName;
  final List<FloorNode> floors;

  const _BuildingContext({
    required this.campusId,
    required this.campusName,
    required this.buildingId,
    required this.buildingName,
    required this.floors,
  });
}

class _HttpResult {
  final int statusCode;
  final List<int> bytes;

  const _HttpResult({required this.statusCode, required this.bytes});

  String preview() {
    try {
      final text = utf8.decode(bytes.take(300).toList(), allowMalformed: true);
      return text.replaceAll(RegExp(r'\s+'), ' ').trim();
    } catch (_) {
      return '<二进制内容>';
    }
  }
}

/// 把楼层/楼栋名转换为安全的文件名。
String sanitizeFileName(String name) {
  final cleaned = name
      .trim()
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ')
      .replaceAll(RegExp(r'\s+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  if (cleaned.isEmpty) return 'floor';
  return cleaned.length > 60 ? cleaned.substring(0, 60) : cleaned;
}

/// 按文件头判断图片真实格式（平台 Content-Type 可能是错误的）。
String imageExtensionFromBytes(List<int> bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return 'png';
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
    return 'jpg';
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46) {
    return 'gif';
  }
  return 'png';
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '${bytes}B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)}MB';
}

class FloorCrawlException implements Exception {
  final String message;

  const FloorCrawlException(this.message);

  @override
  String toString() => message;
}
