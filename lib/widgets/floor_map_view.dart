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

// 画布 / 图纸配色：冷调渐变打底，避免出现整块纯白。
const Color _canvasTop = Color(0xFFF4F9FD);
const Color _canvasBottom = Color(0xFFE2EDF6);
const Color _blueprintTop = Color(0xFFEFF6FC);
const Color _blueprintBottom = Color(0xFFDFEAF5);

// 房间号字号（屏幕像素，绘制时会按 CAD 缩放换算回来）与白色描边宽度。
// 调这三个值即可整体改变叠在房间上的文字大小。
const double _roomLabelFontSize = 5.0;
const double _roomLabelActiveFontSize = 6.0;
const double _roomLabelOutlineWidth = 0.9;

/// 房间号是否逐字竖排：只由房间在屏幕上的形状与文字长度决定，
/// 与悬停/选中状态无关，避免 hover 时横竖跳变。
bool shouldStackRoomLabel({
  required double screenWidth,
  required double screenHeight,
  required int charCount,
  double fontSize = _roomLabelFontSize,
}) {
  return screenHeight >= screenWidth * 1.5 &&
      screenHeight >= fontSize * 1.15 * charCount + 6;
}

/// 楼层预览合成控件：底图（户型图原图）+ 房间矢量叠加层 + 点选文字说明。
///
/// - 底图图层：[FloorInfo.imagePath] 指向的 PNG/JPEG，用 `BoxFit.fill` 铺满 CAD 盒子；
/// - 矢量叠加层：[FloorInfo.detailPath] 里 `cadIdentifyData` 解析出的房间多边形与房间号，
///   按 CAD 原生坐标绘制，与底图像素级对齐；
/// - 交互：滚轮/手势缩放平移，悬停/点击只描边高亮房间，房间号与详情均为纯文字，
///   不叠加任何底色块或卡片，保证户型图完整透出。
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

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_canvasTop, _canvasBottom],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          map,
          if (hasOverlay) _buildZoomControls(),
          if (hasOverlay) _buildRoomCaption(cad),
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
      ),
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
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: _line),
                  boxShadow: [
                    BoxShadow(
                      color: _ink.withValues(alpha: 0.16),
                      blurRadius: 22,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: MouseRegion(
                    onHover: (event) =>
                        _handleHover(event.localPosition, childSize),
                    onExit: (_) {
                      if (_hoveredRoom != null) {
                        setState(() => _hoveredRoom = null);
                      }
                    },
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (details) =>
                          _handleTap(details.localPosition, childSize),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Positioned.fill(child: _buildImageLayer(imagePath)),
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
            ),
          ),
        );
      },
    );
  }

  /// 底图图层：给白底 CAD 原图染上一层极淡的纸色；缺失/失败时改用图纸占位。
  Widget _buildImageLayer(String? imagePath) {
    if (imagePath == null) return _buildBlueprint();
    return ColorFiltered(
      colorFilter: const ColorFilter.mode(
        Color(0xFFF3F8FD),
        BlendMode.multiply,
      ),
      child: Image.file(
        File(imagePath),
        fit: BoxFit.fill,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => _buildBlueprint(loadFailed: true),
      ),
    );
  }

  /// 图纸占位：渐变 + 细网格 + 状态说明，不再是纯白一整片。
  Widget _buildBlueprint({bool loadFailed = false}) {
    final noImage = widget.floor.cadPath.isEmpty;
    final message =
        loadFailed ? '户型图加载失败' : (noImage ? '平台未上传该楼层户型图' : '户型图未下载成功');
    final icon = loadFailed
        ? Icons.broken_image_outlined
        : (noImage
            ? Icons.layers_clear_outlined
            : Icons.image_not_supported_outlined);
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [_blueprintTop, _blueprintBottom],
            ),
          ),
        ),
        const Positioned.fill(
            child: CustomPaint(painter: _BlueprintGridPainter())),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 34, color: _accent.withValues(alpha: 0.85)),
              const SizedBox(height: 12),
              Text(
                message,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _ink.withValues(alpha: 0.74),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '房间矢量仍可点选查看',
                style: TextStyle(
                  fontSize: 11,
                  color: _subtle.withValues(alpha: 0.85),
                ),
              ),
            ],
          ),
        ),
      ],
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
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _line),
            boxShadow: [
              BoxShadow(
                color: _ink.withValues(alpha: 0.14),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: ColorFiltered(
            colorFilter: const ColorFilter.mode(
              Color(0xFFF3F8FD),
              BlendMode.multiply,
            ),
            child: Image.file(
              File(imagePath),
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.broken_image_outlined,
                        size: 32, color: _accent.withValues(alpha: 0.8)),
                    const SizedBox(height: 8),
                    const Text('图片加载失败'),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlaceholder() {
    final empty = widget.floor.cadPath.isEmpty;
    return Stack(
      fit: StackFit.expand,
      children: [
        const Positioned.fill(
            child: CustomPaint(painter: _BlueprintGridPainter())),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                empty
                    ? Icons.layers_clear_outlined
                    : Icons.image_not_supported_outlined,
                size: 38,
                color: _accent.withValues(alpha: 0.85),
              ),
              const SizedBox(height: 14),
              Text(
                empty ? '平台未上传该楼层户型图' : '户型图未下载成功',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _ink.withValues(alpha: 0.74),
                ),
              ),
              if (empty) ...[
                const SizedBox(height: 6),
                Text(
                  '该楼层仍按已完成统计',
                  style: TextStyle(fontSize: 12, color: _subtle),
                ),
              ] else ...[
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: SelectableText(
                    'cadPath: ${widget.floor.cadPath}',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: _subtle),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
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

  /// 点选房间只留一行文字说明，没有卡片、底色块或关闭按钮。
  Widget _buildRoomCaption(FloorCadData cad) {
    final index = _selectedRoom;
    if (index == null || index < 0 || index >= cad.rooms.length) {
      return const SizedBox.shrink();
    }
    final room = cad.rooms[index];
    final parts = <String>[
      if (room.no.isNotEmpty) room.no,
      if (room.name.isNotEmpty) room.name,
      if (room.area > 0) '${room.area.toStringAsFixed(1)} ㎡',
      if (room.type.isNotEmpty) room.type,
      if (room.dept.isNotEmpty) room.dept,
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Positioned(
      left: 16,
      right: 210,
      bottom: 15,
      child: IgnorePointer(
        child: Text(
          parts.join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: _ink.withValues(alpha: 0.86),
            shadows: const [
              Shadow(color: Colors.white, blurRadius: 6),
              Shadow(color: Colors.white, blurRadius: 3),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHints() {
    return Positioned(
      right: 16,
      bottom: 16,
      child: IgnorePointer(
        child: Text(
          '滚轮缩放 · 拖动平移 · 点击房间',
          style: TextStyle(
            fontSize: 10,
            color: _subtle.withValues(alpha: 0.8),
            shadows: const [
              Shadow(color: Colors.white, blurRadius: 5),
              Shadow(color: Colors.white, blurRadius: 2),
            ],
          ),
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// 房间矢量叠加绘制（仅描边 + 纯文字房间号，无任何底色块）
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
      // 只描边、不填充：房间区域不再有任何色块，户型图完整透出。
      if (selected) {
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeJoin = StrokeJoin.round
            ..strokeWidth = 7 * unit
            ..color = _selectedAccent.withValues(alpha: 0.18),
        );
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = (selected ? 3.0 : (hovered ? 2.0 : 1.0)) * unit
          ..color = selected
              ? _selectedAccent
              : color.withValues(alpha: hovered ? 0.95 : 0.55),
      );
    }

    for (var i = 0; i < rooms.length; i++) {
      _paintRoomLabel(
        canvas,
        rooms[i],
        sx,
        sy,
        unit,
        selected: i == selectedRoom,
        hovered: i == hoveredRoom,
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
    required bool hovered,
  }) {
    if (!room.hasPolygon) return;
    final label = room.no.isNotEmpty ? room.no : room.name;
    if (label.isEmpty) return;
    final bounds = room.bounds;
    final screenWidth = bounds.width * sx;
    final screenHeight = bounds.height * sy;
    final chars = label.runes.map((r) => String.fromCharCode(r)).toList();

    // 横竖排、是否显示都只由房间形状决定，绝不能随悬停/选中变化，
    // 否则像「109」这种刚卡在高度边界的窄长房间 hover 后会突然变横排。
    final vertical = shouldStackRoomLabel(
      screenWidth: screenWidth,
      screenHeight: screenHeight,
      charCount: chars.length,
    );
    if (!vertical && (screenWidth < 30 || screenHeight < 18)) return;

    final active = selected || hovered;
    // 竖排时字号固定，hover 只换颜色与字重，避免行距变化把竖排挤出去。
    final screenFont = vertical
        ? _roomLabelFontSize
        : (active ? _roomLabelActiveFontSize : _roomLabelFontSize);
    final fontSize = screenFont / math.max(sx, 0.01);
    final color = selected
        ? _selectedAccent
        : (hovered ? _accent : _ink.withValues(alpha: 0.78));
    final double maxWidth = math.max(bounds.width * 0.86, 1);

    // 纯文字房间号：白色细描边代替原来的背景片，任何底图上都清晰。
    TextPainter buildPainter(
      String text, {
      required bool outline,
      double? width,
    }) {
      return TextPainter(
        text: TextSpan(
          text: text,
          style: outline
              ? TextStyle(
                  fontSize: fontSize,
                  fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                  foreground: Paint()
                    ..style = PaintingStyle.stroke
                    ..strokeJoin = StrokeJoin.round
                    ..strokeWidth = _roomLabelOutlineWidth * unit
                    ..color = Colors.white.withValues(alpha: 0.92),
                )
              : TextStyle(
                  fontSize: fontSize,
                  fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                  color: color,
                ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: width ?? double.infinity);
    }

    if (vertical) {
      final lineHeight = fontSize * 1.15;
      var y = room.centroid.dy - lineHeight * chars.length / 2;
      for (final ch in chars) {
        final fill = buildPainter(ch, outline: false);
        final x = room.centroid.dx - fill.width / 2;
        buildPainter(ch, outline: true).paint(canvas, Offset(x, y));
        fill.paint(canvas, Offset(x, y));
        y += lineHeight;
      }
      return;
    }

    final fill = buildPainter(label, outline: false, width: maxWidth);
    final origin = Offset(
      room.centroid.dx - fill.width / 2,
      room.centroid.dy - fill.height / 2,
    );
    buildPainter(label, outline: true, width: maxWidth).paint(canvas, origin);
    fill.paint(canvas, origin);
  }

  Path _path(List<Offset> points) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
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
    return IconButton(
      onPressed: onTap,
      icon: Icon(icon, size: 18, color: _ink.withValues(alpha: 0.62)),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 28, height: 28),
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

/// 图纸网格：细线 + 每 5 格一条主线，给空白底图一点结构感。
class _BlueprintGridPainter extends CustomPainter {
  const _BlueprintGridPainter();

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final minor = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7
      ..color = _accent.withValues(alpha: 0.07);
    final major = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9
      ..color = _accent.withValues(alpha: 0.13);
    const step = 28.0;
    var column = 0;
    for (var x = 0.0; x <= size.width; x += step, column++) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        column % 5 == 0 ? major : minor,
      );
    }
    var row = 0;
    for (var y = 0.0; y <= size.height; y += step, row++) {
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        row % 5 == 0 ? major : minor,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BlueprintGridPainter oldDelegate) => false;
}
