import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../actions/floor_action.dart';
import '../actions/floor_cad_data.dart';

const Color _accent = Color(0xFF0891B2);
const Color _ink = Color(0xFF0F172A);
const Color _subtle = Color(0xFF64748B);
const Color _selectedAccent = Color(0xFFB45309);
const Color _line = Color(0xFFD8E4F0);

/// 楼层预览合成控件：底图（户型图原图）+ 房间矢量叠加层 + 点选信息卡。
///
/// - 底图图层：[FloorInfo.imagePath] 指向的 PNG/JPEG，用 `BoxFit.fill` 铺满 CAD 盒子；
/// - 矢量叠加层：[FloorInfo.detailPath] 里 `cadIdentifyData` 解析出的房间多边形与房间号，
///   按 CAD 原生坐标绘制，与底图像素级对齐；
/// - 交互：滚轮/手势缩放平移，悬停高亮，点击房间弹出信息卡（房间号/面积/名称/类型/部门）。
class FloorMapView extends StatefulWidget {
  const FloorMapView({super.key, required this.floor});

  final FloorInfo floor;

  @override
  State<FloorMapView> createState() => _FloorMapViewState();
}

class _FloorMapViewState extends State<FloorMapView> {
  final TransformationController _transform = TransformationController();

  FloorCadData? _cad;
  bool _loading = false;
  int? _selectedRoom;
  int? _hoveredRoom;

  @override
  void initState() {
    super.initState();
    _loadCad();
  }

  @override
  void didUpdateWidget(covariant FloorMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.floor.id != widget.floor.id ||
        oldWidget.floor.detailPath != widget.floor.detailPath) {
      _selectedRoom = null;
      _hoveredRoom = null;
      _transform.value = Matrix4.identity();
      _loadCad();
    }
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  Future<void> _loadCad() async {
    final path = widget.floor.detailPath;
    if (path == null) {
      if (mounted) setState(() => _cad = null);
      return;
    }
    setState(() => _loading = true);
    FloorCadData? parsed;
    try {
      final file = File(path);
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          parsed = parseFloorCadFromDetail(Map<String, dynamic>.from(decoded));
        }
      }
    } catch (_) {
      parsed = null;
    }
    if (!mounted) return;
    setState(() {
      _cad = parsed;
      _loading = false;
      _selectedRoom = null;
      _hoveredRoom = null;
    });
  }

  void _zoomBy(double factor) {
    final current = _transform.value.getMaxScaleOnAxis();
    final target = (current * factor).clamp(0.5, 8.0).toDouble();
    _transform.value = _transform.value.clone()
      ..scaleByDouble(target / current, target / current, 1, 1);
  }

  void _resetZoom() => _transform.value = Matrix4.identity();

  FloorRoom? _roomAt(Offset local, Size size) {
    final cad = _cad;
    if (cad == null || !cad.hasRooms || size.isEmpty) return null;
    final point = Offset(
      local.dx / size.width * cad.width,
      local.dy / size.height * cad.height,
    );
    for (var i = cad.rooms.length - 1; i >= 0; i--) {
      final room = cad.rooms[i];
      if (room.hasPolygon && room.contains(point)) return room;
    }
    return null;
  }

  void _handleTap(Offset local, Size size) {
    final room = _roomAt(local, size);
    final cad = _cad;
    setState(() => _selectedRoom =
        room == null || cad == null ? null : cad.rooms.indexOf(room));
  }

  void _handleHover(Offset local, Size size) {
    final room = _roomAt(local, size);
    final cad = _cad;
    final index = room == null || cad == null ? null : cad.rooms.indexOf(room);
    if (index != _hoveredRoom) setState(() => _hoveredRoom = index);
  }

  @override
  Widget build(BuildContext context) {
    final cad = _cad;
    final hasOverlay = cad != null && cad.hasRooms;
    final hasImage = widget.floor.imagePath != null;

    Widget map;
    if (hasOverlay) {
      map = _buildCadBox(cad);
    } else if (hasImage) {
      map = _buildImageOnly(widget.floor.imagePath!);
    } else {
      map = _buildPlaceholder();
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        map,
        if (hasOverlay) _buildZoomControls(),
        if (hasOverlay) _buildRoomCard(cad),
        if (hasOverlay) _buildHints(),
        if (_loading)
          const Positioned(
            top: 12,
            right: 12,
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
      ],
    );
  }

  /// 有房间矢量时：以 CAD 尺寸建盒子，底图 `BoxFit.fill` 铺底，矢量叠加在上。
  Widget _buildCadBox(FloorCadData cad) {
    final imagePath = widget.floor.imagePath;
    return LayoutBuilder(
      builder: (context, constraints) {
        final fit = math.min(
          constraints.maxWidth / cad.width,
          constraints.maxHeight / cad.height,
        );
        final width = math.max(cad.width * fit, 1.0);
        final height = math.max(cad.height * fit, 1.0);
        final childSize = Size(width, height);
        return Center(
          child: InteractiveViewer(
            transformationController: _transform,
            scaleFactor: 400,
            minScale: 0.5,
            maxScale: 8,
            boundaryMargin: const EdgeInsets.all(80),
            child: SizedBox(
              width: width,
              height: height,
              child: MouseRegion(
                onHover: (event) => _handleHover(event.localPosition, childSize),
                onExit: (_) {
                  if (_hoveredRoom != null) setState(() => _hoveredRoom = null);
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (details) =>
                      _handleTap(details.localPosition, childSize),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (imagePath != null)
                        Positioned.fill(
                          child: Image.file(
                            File(imagePath),
                            fit: BoxFit.fill,
                            gaplessPlayback: true,
                            errorBuilder: (_, __, ___) =>
                                const ColoredBox(color: Colors.white),
                          ),
                        )
                      else
                        const ColoredBox(color: Colors.white),
                      CustomPaint(
                        painter: _FloorOverlayPainter(
                          cad: cad,
                          selectedRoom: _selectedRoom,
                          hoveredRoom: _hoveredRoom,
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 无房间矢量、仅有底图时：直接展示原图，保留缩放平移。
  Widget _buildImageOnly(String imagePath) {
    return Center(
      child: InteractiveViewer(
        transformationController: _transform,
        scaleFactor: 400,
        minScale: 0.5,
        maxScale: 8,
        boundaryMargin: const EdgeInsets.all(80),
        child: Image.file(
          File(imagePath),
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => const Text('图片加载失败'),
        ),
      ),
    );
  }

  Widget _buildPlaceholder() {
    final empty = widget.floor.cadPath.isEmpty;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            empty ? Icons.image_not_supported_outlined : Icons.broken_image_outlined,
            size: 56,
            color: Colors.grey.shade400,
          ),
          const SizedBox(height: 12),
          Text(empty ? '平台未上传该楼层户型图' : '户型图未下载成功'),
          if (empty) ...[
            const SizedBox(height: 6),
            Text(
              '该楼层仍按已完成统计',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ] else ...[
            const SizedBox(height: 8),
            SelectableText(
              'cadPath: ${widget.floor.cadPath}',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildZoomControls() {
    return Positioned(
      right: 14,
      top: 14,
      child: Column(
        children: [
          _MapButton(icon: Icons.add, onTap: () => _zoomBy(1.25)),
          const SizedBox(height: 6),
          _MapButton(icon: Icons.remove, onTap: () => _zoomBy(0.8)),
          const SizedBox(height: 6),
          _MapButton(icon: Icons.center_focus_strong, onTap: _resetZoom),
        ],
      ),
    );
  }

  Widget _buildRoomCard(FloorCadData cad) {
    final index = _selectedRoom;
    if (index == null || index < 0 || index >= cad.rooms.length) {
      return const SizedBox.shrink();
    }
    final room = cad.rooms[index];
    return Positioned(
      left: 16,
      bottom: 16,
      child: _GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  room.no.isEmpty ? '房间' : room.no,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: _accent,
                  ),
                ),
                if (room.area > 0) ...[
                  const SizedBox(width: 8),
                  Text(
                    '${room.area.toStringAsFixed(1)} ㎡',
                    style: TextStyle(
                      fontSize: 11,
                      color: _subtle.withValues(alpha: 0.82),
                    ),
                  ),
                ],
              ],
            ),
            if (room.name.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                room.name,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _ink,
                ),
              ),
            ],
            if (room.type.isNotEmpty || room.dept.isNotEmpty) ...[
              const SizedBox(height: 6),
              SizedBox(
                width: 250,
                child: Text(
                  [room.type, room.dept].where((e) => e.isNotEmpty).join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.4,
                    color: _subtle.withValues(alpha: 0.82),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildHints() {
    return Positioned(
      right: 16,
      bottom: 16,
      child: Text(
        '滚轮缩放 · 拖动平移 · 点击房间',
        style: TextStyle(fontSize: 10, color: _subtle.withValues(alpha: 0.72)),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// 房间矢量叠加绘制（多边形填充/描边 + 房间号标签）
// ──────────────────────────────────────────────────────────────────────────────

class _FloorOverlayPainter extends CustomPainter {
  _FloorOverlayPainter({
    required this.cad,
    required this.selectedRoom,
    required this.hoveredRoom,
  });

  final FloorCadData cad;
  final int? selectedRoom;
  final int? hoveredRoom;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final sx = size.width / cad.width;
    final sy = size.height / cad.height;
    final unit = 1 / math.max(math.min(sx, sy), 0.01);
    canvas.save();
    canvas.scale(sx, sy);

    final rooms = cad.rooms;
    for (var i = 0; i < rooms.length; i++) {
      final room = rooms[i];
      if (!room.hasPolygon) continue;
      final path = _path(room.points);
      final selected = i == selectedRoom;
      final hovered = i == hoveredRoom;
      final color = _roomColor(room);
      // 底图透出：默认低不透明度，悬停/选中再加深。
      final fillAlpha = selected ? 0.62 : (hovered ? 0.46 : 0.26);
      canvas.drawPath(path, Paint()..color = color.withValues(alpha: fillAlpha));
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = (selected ? 2.6 : 1.2) / math.min(sx, sy)
          ..color = selected
              ? _selectedAccent
              : color.withValues(alpha: hovered ? 0.95 : 0.8),
      );
      if (selected) {
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 8 / math.min(sx, sy)
            ..color = _selectedAccent.withValues(alpha: 0.16),
        );
      }
    }

    for (var i = 0; i < rooms.length; i++) {
      _paintRoomLabel(
        canvas,
        rooms[i],
        sx,
        sy,
        unit,
        selected: i == selectedRoom || i == hoveredRoom,
      );
    }

    canvas.restore();
  }

  void _paintRoomLabel(
    Canvas canvas,
    FloorRoom room,
    double sx,
    double sy,
    double unit, {
    required bool selected,
  }) {
    if (!room.hasPolygon) return;
    final label = room.no.isNotEmpty ? room.no : room.name;
    if (label.isEmpty) return;
    final bounds = room.bounds;
    final screenWidth = bounds.width * sx;
    final screenHeight = bounds.height * sy;
    if (!selected && (screenWidth < 28 || screenHeight < 16)) return;

    final center = room.centroid;
    final fontSize = (selected ? 13 : 11) / math.max(sx, 0.01);
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
          color: _ink,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: math.max(bounds.width * 0.9, 1));

    // 半透明白色药丸底，保证房间号在底图之上清晰可读。
    final padX = fontSize * 0.28;
    final padY = fontSize * 0.14;
    final rect = Rect.fromLTWH(
      center.dx - tp.width / 2 - padX,
      center.dy - tp.height / 2 - padY,
      tp.width + padX * 2,
      tp.height + padY * 2,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(fontSize * 0.3)),
      Paint()..color = Colors.white.withValues(alpha: selected ? 0.92 : 0.72),
    );
    tp.paint(canvas, Offset(center.dx - tp.width / 2, center.dy - tp.height / 2));
  }

  Path _path(List<Offset> points) {
    final path = Path()
      ..moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length; i++) {
      path.lineTo(points[i].dx, points[i].dy);
    }
    return path..close();
  }

  Color _roomColor(FloorRoom room) {
    final key = room.type.isNotEmpty ? room.type : room.dept;
    final hash = key.codeUnits.fold<int>(
      0,
      (sum, c) => (sum * 31 + c) & 0x7fffffff,
    );
    const palette = [
      Color(0xFF38BDF8),
      Color(0xFF60A5FA),
      Color(0xFFA78BFA),
      Color(0xFF2DD4BF),
      Color(0xFFF59E0B),
      Color(0xFF4ADE80),
      Color(0xFFF87171),
    ];
    return palette[hash % palette.length];
  }

  @override
  bool shouldRepaint(covariant _FloorOverlayPainter oldDelegate) =>
      oldDelegate.cad != cad ||
      oldDelegate.selectedRoom != selectedRoom ||
      oldDelegate.hoveredRoom != hoveredRoom;
}

// ──────────────────────────────────────────────────────────────────────────────
// 小部件
// ──────────────────────────────────────────────────────────────────────────────

class _MapButton extends StatelessWidget {
  const _MapButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.94),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: _line),
      ),
      elevation: 2,
      shadowColor: const Color(0xFF0F172A).withValues(alpha: 0.16),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(7),
          child: Icon(icon, size: 17, color: const Color(0xFF475569)),
        ),
      ),
    );
  }
}

class _GlassCard extends StatelessWidget {
  const _GlassCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 16, 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _accent.withValues(alpha: 0.20)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0F172A).withValues(alpha: 0.14),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
  }
}
