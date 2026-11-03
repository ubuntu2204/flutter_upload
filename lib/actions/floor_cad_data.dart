import 'dart:convert';
import 'dart:ui' show Offset, Rect;

/// 单个房间矢量（来自平台 `cadIdentifyData`）。
///
/// 字段口径与 `maintenance/backend/tool/build_floor_maps.py` 完全一致：
/// `no = roomNo`、`name = room.name`、`area = room.useArea`、
/// `type = room.roomTypeName`、`dept = room.baseDepName`、`points = vertex`。
/// `points` 为 CAD 坐标系（[FloorCadData.width]/[FloorCadData.height]）下的多边形顶点。
class FloorRoom {
  const FloorRoom({
    required this.no,
    required this.name,
    required this.area,
    required this.type,
    required this.dept,
    required this.points,
  });

  final String no;
  final String name;
  final double area;
  final String type;
  final String dept;
  final List<Offset> points;

  bool get hasPolygon => points.length >= 3;

  /// 顶点均值，用于房间号标签定位（对齐前端 FloorRoom.centroid）。
  Offset get centroid {
    if (points.isEmpty) return Offset.zero;
    var x = 0.0;
    var y = 0.0;
    for (final p in points) {
      x += p.dx;
      y += p.dy;
    }
    return Offset(x / points.length, y / points.length);
  }

  /// 多边形包围盒（CAD 坐标系），用于标签尺寸/可见性判断。
  Rect get bounds {
    if (points.isEmpty) return Rect.zero;
    var minX = points.first.dx;
    var maxX = points.first.dx;
    var minY = points.first.dy;
    var maxY = points.first.dy;
    for (final p in points) {
      if (p.dx < minX) minX = p.dx;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dy > maxY) maxY = p.dy;
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  /// 射线法判断点是否落在房间多边形内（移植前端 FloorRoom.contains）。
  bool contains(Offset p) {
    var inside = false;
    for (var i = 0, j = points.length - 1; i < points.length; j = i++) {
      final pi = points[i];
      final pj = points[j];
      if ((pi.dy > p.dy) != (pj.dy > p.dy) &&
          p.dx < (pj.dx - pi.dx) * (p.dy - pi.dy) / (pj.dy - pi.dy) + pi.dx) {
        inside = !inside;
      }
    }
    return inside;
  }
}

/// 一层楼的房间矢量数据（CAD 坐标系 + 房间多边形集合）。
class FloorCadData {
  const FloorCadData({
    required this.width,
    required this.height,
    required this.rooms,
  });

  final double width;
  final double height;
  final List<FloorRoom> rooms;

  /// 是否有可绘制的房间矢量。
  bool get hasRooms => rooms.any((r) => r.hasPolygon);
}

/// 从一层详情 JSON（`details/{floorId}.json` 解析结果）提取房间矢量。
///
/// 优先 `statisticsRoomVo.cadIdentifyData`，回退 `rawData`；也兼容详情顶层字段。
/// 无有效 `rooms` 时返回 null，交由底图独立展示。
FloorCadData? parseFloorCadFromDetail(Map<String, dynamic> detail) {
  final cad = _extractCadData(detail);
  if (cad == null) return null;

  final rawRooms = cad['rooms'];
  if (rawRooms is! List) return null;

  final rooms = <FloorRoom>[];
  var maxX = 0.0;
  var maxY = 0.0;
  for (final item in rawRooms) {
    if (item is! Map) continue;
    final room = item['room'];
    final roomMap = room is Map
        ? room.cast<String, dynamic>()
        : const <String, dynamic>{};
    final points = _cleanPoints(item['vertex']);
    if (points.length < 3) continue;
    for (final p in points) {
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy > maxY) maxY = p.dy;
    }
    rooms.add(FloorRoom(
      no: (item['roomNo'] ?? roomMap['roomNo'] ?? '').toString(),
      name: (roomMap['name'] ?? '').toString(),
      area: _toDouble(roomMap['useArea']),
      type: (roomMap['roomTypeName'] ?? '').toString(),
      dept: (roomMap['baseDepName'] ?? '').toString(),
      points: points,
    ));
  }

  var width = 0.0;
  var height = 0.0;
  final size = cad['size'];
  if (size is Map) {
    width = _toDouble(size['width']);
    height = _toDouble(size['height']);
  }
  // size 缺失时用顶点包围盒兜底，保证与底图 BoxFit.fill 对齐。
  if (width <= 0) width = maxX > 0 ? maxX : 1000;
  if (height <= 0) height = maxY > 0 ? maxY : 700;

  return FloorCadData(width: width, height: height, rooms: rooms);
}

/// 依次尝试 `statisticsRoomVo` 与详情顶层的 `cadIdentifyData`/`rawData`。
Map<String, dynamic>? _extractCadData(Map<String, dynamic> detail) {
  final candidates = <dynamic>[];
  final stats = detail['statisticsRoomVo'];
  if (stats is Map) {
    candidates
      ..add(stats['cadIdentifyData'])
      ..add(stats['rawData']);
  }
  candidates
    ..add(detail['cadIdentifyData'])
    ..add(detail['rawData']);
  for (final raw in candidates) {
    final decoded = _maybeDecode(raw);
    if (decoded != null && decoded['rooms'] is List) return decoded;
  }
  return null;
}

Map<String, dynamic>? _maybeDecode(dynamic raw) {
  if (raw == null) return null;
  if (raw is Map) return raw.cast<String, dynamic>();
  if (raw is String) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    try {
      final decoded = jsonDecode(text);
      return decoded is Map ? decoded.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }
  return null;
}

/// 顶点转 Offset 列表：兼容 `{x,y}` 与 `[x,y]`，去掉相邻重复点与闭合重复点。
List<Offset> _cleanPoints(dynamic raw) {
  final points = <Offset>[];
  if (raw is! List) return points;
  for (final vertex in raw) {
    double? x;
    double? y;
    if (vertex is Map) {
      x = _toDoubleOrNull(vertex['x']);
      y = _toDoubleOrNull(vertex['y']);
    } else if (vertex is List && vertex.length >= 2) {
      x = _toDoubleOrNull(vertex[0]);
      y = _toDoubleOrNull(vertex[1]);
    }
    if (x == null || y == null) continue;
    final p = Offset(x, y);
    if (points.isEmpty || points.last != p) points.add(p);
  }
  if (points.length > 1 && points.first == points.last) points.removeLast();
  return points;
}

double _toDouble(dynamic v) => _toDoubleOrNull(v) ?? 0;

double? _toDoubleOrNull(dynamic v) {
  if (v is num) return v.toDouble();
  return double.tryParse('${v ?? ''}');
}
