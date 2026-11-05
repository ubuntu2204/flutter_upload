import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'actions/building_info_action.dart';
import 'actions/building_photo_action.dart';
import 'actions/chrome_launcher.dart';
import 'actions/floor_action.dart';
import 'actions/floor_mcp_action.dart';
import 'actions/floor_tree_cache.dart';
import 'actions/mcp_client.dart';
import 'widgets/floor_map_view.dart';

enum _ChromeState { idle, starting, waitingLogin, ready, cached, error }

/// 楼层管理页：通过本地 Chrome MCP 使用手动登录的浏览器会话，
/// 加载校区/楼栋列表，爬取楼层详情与户型图。
class FloorPage extends StatefulWidget {
  final String initialOutputDir;
  final Future<void> Function(String outputDir) onOutputDirSaved;

  const FloorPage({
    super.key,
    required this.initialOutputDir,
    required this.onOutputDirSaved,
  });

  @override
  State<FloorPage> createState() => _FloorPageState();
}

class _FloorPageState extends State<FloorPage> {
  late final TextEditingController _outputController;
  late final TextEditingController _buildingSearchController;

  _ChromeState _chromeState = _ChromeState.idle;
  McpChromeSession? _session;
  List<FloorNode> _campuses = const [];
  String? _campusId;
  String? _buildingId;
  int _campusKeyVersion = 0;

  bool _showBuildingList = true;

  /// 已进入楼层列表时，右侧预览切到「楼照片与简介」（false=楼层户型图）。
  bool _showBuildingInfoView = false;
  String _buildingFilter = '';
  Map<String, BuildingStatus> _statuses = {};
  Map<String, FloorCrawlResult?> _localResults = {};
  bool _statusLoading = false;
  int _localDataVersion = 0;

  /// 每栋楼采集的楼照片路径（buildingId → 本地文件；null 表示未采集）。
  Map<String, String?> _buildingPhotos = {};

  /// 每栋楼从平台采集的简介（使用单位数 / 建筑面积 / 使用面积等）。
  Map<String, BuildingInfo?> _buildingInfos = {};

  /// 照片被覆盖时递增，编进 Image 的 key 强制重新读盘，避免 Flutter 图片缓存。
  int _photoVersion = 0;

  bool _collectingInfo = false;
  bool _cancelCollect = false;

  List<FloorInfo> _floors = const [];
  FloorCrawlResult? _result;
  int _selectedIndex = 0;
  bool _busy = false;
  bool _crawling = false;
  int _crawlDone = 0;
  int _crawlTotal = 0;
  bool _crawlAll = false;
  bool _cancelCrawlAll = false;
  int _crawlAllIndex = 0;
  int _crawlAllTotal = 0;
  int _crawlAllSuccess = 0;
  int _crawlAllFailed = 0;
  String _log = '等待操作...';

  @override
  void initState() {
    super.initState();
    _outputController = TextEditingController(
      text: widget.initialOutputDir.isEmpty
          ? defaultFloorOutputDir()
          : widget.initialOutputDir,
    );
    _buildingSearchController = TextEditingController();
    // 本地树缓存独立于 Chrome 登录态，启动即展示。
    unawaited(_loadCachedTree());
  }

  @override
  void dispose() {
    final session = _session;
    if (session != null) {
      unawaited(session.close());
    }
    _outputController.dispose();
    _buildingSearchController.dispose();
    super.dispose();
  }

  @override
  void reassemble() {
    super.reassemble();
    // 热重载不会迁移已存在对象的字段。BuildingStatus 新增字段后，
    // 旧实例访问新字段会抛 Null is not a subtype of int。
    // 清空缓存并重新从本地 floors.json 构造状态。
    _statuses = {};
    _localResults = {};
    _buildingPhotos = {};
    _buildingInfos = {};
    _result = null;
    _statusLoading = false;
    if (_campuses.isNotEmpty) {
      unawaited(_refreshLocalData());
    }
  }

  FloorNode? get _campus =>
      _firstWhereOrNull(_campuses, (c) => c.id == _campusId);

  List<FloorNode> get _buildings => _campus?.children ?? const [];

  List<FloorNode> get _filteredBuildings {
    final keyword = _buildingFilter.trim().toLowerCase();
    if (keyword.isEmpty) return _buildings;
    return _buildings
        .where((b) => b.name.toLowerCase().contains(keyword))
        .toList();
  }

  List<FloorNode> get _incompleteBuildings => _buildings
      .where((b) =>
          b.children.isNotEmpty && !(_statuses[b.id]?.completed ?? false))
      .toList();

  double? get _progressValue {
    if (_crawlAll) {
      if (_crawlAllTotal == 0) return null;
      final current = _crawlTotal > 0 ? _crawlDone / _crawlTotal : 0.0;
      return (((_crawlAllIndex - 1) + current) / _crawlAllTotal)
          .clamp(0.0, 1.0)
          .toDouble();
    }
    return _crawlTotal > 0 ? _crawlDone / _crawlTotal : null;
  }

  String get _progressText {
    if (_collectingInfo) {
      return '正在采集楼照片与简介 $_crawlDone / $_crawlTotal 栋';
    }
    if (_crawlAll) {
      if (_crawlAllIndex == 0) return '准备批量爬取...';
      return '批量爬取 $_crawlAllIndex/$_crawlAllTotal：'
          '${_building?.name ?? ''} · $_crawlDone/$_crawlTotal 层';
    }
    return '正在爬取 $_crawlDone / $_crawlTotal 层';
  }

  FloorNode? get _building =>
      _firstWhereOrNull(_buildings, (b) => b.id == _buildingId);

  String? get _currentBuildingPhoto {
    final building = _building;
    return building == null ? null : _buildingPhotos[building.id];
  }

  BuildingInfo? get _currentBuildingInfo {
    final building = _building;
    return building == null ? null : _buildingInfos[building.id];
  }

  T? _firstWhereOrNull<T>(Iterable<T> items, bool Function(T) test) {
    for (final item in items) {
      if (test(item)) return item;
    }
    return null;
  }

  void _addLog(String message) {
    if (!mounted) return;
    setState(() {
      _log = '[${DateTime.now().toString().split('.').first}] $message\n$_log';
    });
  }

  Future<void> _startChrome() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _chromeState = _ChromeState.starting;
    });
    _addLog('--- 启动专用 Chrome ---');
    try {
      final reused = await ensureChromeRunning(addLog: _addLog);
      if (!mounted) return;
      setState(() {
        _chromeState = _ChromeState.waitingLogin;
        _busy = false;
      });
      _addLog(reused
          ? '复用已开启调试端口的 Chrome。请确认已登录平台。\n'
          : 'Chrome 已打开。请在窗口中手动登录平台，然后点击「加载楼栋」。\n');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _chromeState = _ChromeState.error;
        _busy = false;
      });
      _addLog('启动 Chrome 失败: $e\n');
      _showError('启动 Chrome 失败', e);
    }
  }

  Future<McpChromeSession> _ensureSession() async {
    final existing = _session;
    if (existing != null) {
      _addLog('检查页面加载与登录状态...\n');
      await existing.waitForPlatformReady();
      return existing;
    }

    await ensureChromeRunning(addLog: _addLog);
    final session = await startChromeMcp(
      debugPort: chromeDebugPort,
      addLog: _addLog,
    );
    try {
      await session.navigate(platformCampusUrl);
      _addLog('等待页面加载完成并确认登录状态...\n');
      await session.waitForPlatformReady();
    } catch (e) {
      await session.close();
      rethrow;
    }
    _session = session;
    return session;
  }

  /// MCP 进程/Chrome 异常后丢弃会话，下一次操作会重新启动。
  Future<void> _resetSession() async {
    final session = _session;
    _session = null;
    if (session != null) await session.close();
  }

  /// 启动时读取本地楼栋缓存，无需 Chrome 登录即可浏览校区/楼宇。
  Future<void> _loadCachedTree() async {
    if (_campuses.isNotEmpty) return;
    final cached = await FloorTreeCache.load(_outputController.text);
    if (!mounted || cached == null || _campuses.isNotEmpty) return;
    _applyTree(cached.tree);
    setState(() => _chromeState = _ChromeState.cached);
    _addLog('已从本地缓存加载校区/楼栋：${cached.path}\n');
    unawaited(_refreshLocalData());
  }

  /// 应用一份校区/楼栋树，并默认选中第一个校区的「主楼」。
  void _applyTree(List<FloorNode> tree) {
    if (tree.isEmpty) return;
    final campus = tree.first;
    final building =
        _firstWhereOrNull(campus.children, (b) => b.name.contains('主楼')) ??
            (campus.children.isNotEmpty ? campus.children.first : null);
    setState(() {
      _campuses = tree;
      _campusId = campus.id;
      _campusKeyVersion++;
      _buildingId = building?.id;
      _floors =
          building == null ? const [] : _placeholderFloors(campus, building);
      _selectedIndex = defaultFloorSelectionIndex(_floors);
      _result = null;
      _showBuildingList = true;
      _buildingFilter = '';
      _buildingSearchController.clear();
      _statuses = {};
      _localResults = {};
      _buildingPhotos = {};
      _buildingInfos = {};
    });
  }

  Future<void> _loadTree() async {
    if (_busy) return;
    setState(() => _busy = true);
    _addLog('--- 加载校区 / 楼栋 ---');
    try {
      final session = await _ensureSession();
      final crawler = ChromeFloorCrawler(
        session: session,
        outputDir: _outputController.text.trim(),
        addLog: _addLog,
      );
      final tree = await crawler.loadTree();
      if (!mounted) return;

      _applyTree(tree);
      setState(() => _chromeState = _ChromeState.ready);
      _addLog('已加载：${_campus?.name ?? ''} / ${_building?.name ?? '暂无楼栋'}'
          '，共 ${_buildings.length} 栋\n');
      try {
        final cachePath =
            await FloorTreeCache.save(_outputController.text, tree);
        _addLog('已保存本地楼栋缓存: $cachePath\n');
      } catch (e) {
        _addLog('保存本地楼栋缓存失败: $e\n');
      }
      unawaited(_refreshLocalData());
    } catch (e) {
      if (!mounted) return;
      final text = e.toString();
      final needLogin = text.contains('401') || text.contains('登录态');
      if (!needLogin) await _resetSession();
      if (!mounted) return;

      // 远程加载失败时回退本地缓存，保证未登录/离线也能浏览列表。
      final cached = _campuses.isEmpty
          ? await FloorTreeCache.load(_outputController.text)
          : null;
      if (!mounted) return;
      if (cached != null) {
        _applyTree(cached.tree);
        setState(() => _chromeState = _ChromeState.cached);
        _addLog('加载失败: $text\n');
        _addLog('已改用本地缓存：${cached.path}。登录后可重新加载以更新。\n');
        unawaited(_refreshLocalData());
        return;
      }

      setState(() {
        _chromeState =
            needLogin ? _ChromeState.waitingLogin : _ChromeState.error;
      });
      _addLog('加载失败: $text\n');
      if (needLogin) {
        _addLog('请先在 Chrome 窗口登录平台，登录后再次点击「加载楼栋」。\n');
      } else {
        _showError('加载失败', e);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _selectCampus(String campusId) {
    if (_busy) return;
    final campus = _firstWhereOrNull(_campuses, (c) => c.id == campusId);
    if (campus == null) return;
    final building =
        _firstWhereOrNull(campus.children, (b) => b.name.contains('主楼')) ??
            (campus.children.isNotEmpty ? campus.children.first : null);
    setState(() {
      _campusId = campusId;
      _campusKeyVersion++;
      _buildingId = building?.id;
      _floors =
          building == null ? const [] : _placeholderFloors(campus, building);
      _selectedIndex = defaultFloorSelectionIndex(_floors);
      _result = null;
      _showBuildingList = true;
      _buildingFilter = '';
      _buildingSearchController.clear();
      _statuses = {};
      _localResults = {};
      _buildingPhotos = {};
      _buildingInfos = {};
    });
    unawaited(_refreshLocalData());
  }

  Future<void> _selectBuilding(String buildingId) async {
    if (_busy) return;
    final campus = _campus;
    final building = _firstWhereOrNull(_buildings, (b) => b.id == buildingId);
    if (campus == null || building == null) return;

    FloorCrawlResult? local;
    if (_localResults.containsKey(building.id)) {
      local = _localResults[building.id];
    } else {
      local = await _readLocalResult(campus, building);
      _localResults[building.id] = local;
    }
    if (!mounted) return;
    setState(() {
      _buildingId = buildingId;
      _showBuildingList = false;
      _showBuildingInfoView = false;
      _result = local;
      _floors = local?.floors ?? _placeholderFloors(campus, building);
      _selectedIndex = defaultFloorSelectionIndex(_floors);
    });
  }

  /// 计算当前校区所有楼栋的本地获取状态，并缓存可用结果。
  Future<void> _refreshLocalData() async {
    final campus = _campus;
    if (campus == null || campus.children.isEmpty) return;
    final version = ++_localDataVersion;
    setState(() => _statusLoading = true);
    final results = <String, FloorCrawlResult?>{};
    final statuses = <String, BuildingStatus>{};
    final photos = <String, String?>{};
    final infos = <String, BuildingInfo?>{};
    for (final building in campus.children) {
      final result = await _readLocalResult(campus, building);
      results[building.id] = result;
      statuses[building.id] =
          BuildingStatus.fromResult(building.children.length, result);
      photos[building.id] = results[building.id]?.buildingPhotoPath ??
          await BuildingPhotoStore.resolve(_buildingDir(building));
      infos[building.id] =
          await BuildingPhotoStore.readInfo(_buildingDir(building));
    }
    if (!mounted || version != _localDataVersion) return;
    setState(() {
      _localResults = results;
      _statuses = statuses;
      _buildingPhotos = photos;
      _buildingInfos = infos;
      _statusLoading = false;
    });

    // 当前楼栋如果还没加载过本地结果，补上最新状态。
    final current = _building;
    if (current != null && _result == null) {
      final local = results[current.id];
      if (local != null) {
        setState(() {
          _result = local;
          _floors = local.floors;
          _selectedIndex = defaultFloorSelectionIndex(_floors);
        });
      }
    }
  }

  /// 楼栋本地数据目录（爬取楼层与采集楼照片共用）。
  String _buildingDir(FloorNode building) {
    final base = _outputController.text.trim().isEmpty
        ? defaultFloorOutputDir()
        : _outputController.text.trim();
    return '$base/${sanitizeFileName(building.name)}_${building.id}';
  }

  /// 读取本地 floors.json；不存在或损坏时返回 null。
  Future<FloorCrawlResult?> _readLocalResult(
      FloorNode campus, FloorNode building) async {
    final dirPath = _buildingDir(building);
    final manifestFile = File('$dirPath/floors.json');
    if (!await manifestFile.exists()) return null;
    try {
      final raw = await manifestFile.readAsString();
      final map = jsonDecode(raw);
      if (map is! Map) return null;
      final manifestFloors = <String, Map<String, dynamic>>{};
      final list = map['floors'];
      if (list is List) {
        for (final item in list) {
          if (item is Map && item['id'] != null) {
            manifestFloors[item['id'].toString()] =
                Map<String, dynamic>.from(item);
          }
        }
      }

      final infos = <FloorInfo>[];
      for (final node in building.children) {
        final m = manifestFloors[node.id];
        if (m == null) {
          infos.add(FloorInfo(
            id: node.id,
            name: node.name,
            buildingId: building.id,
            buildingName: building.name,
            campusId: campus.id,
            campusName: campus.name,
            cadPath: '',
            imagePath: null,
            detailPath: null,
            roomCount: 0,
            raw: node.raw,
          ));
          continue;
        }
        var imagePath =
            _resolveLocalPath(dirPath, (m['image'] ?? '').toString());
        if (imagePath != null && !await File(imagePath).exists()) {
          imagePath = null;
        }
        infos.add(FloorInfo(
          id: node.id,
          name: node.name,
          buildingId: building.id,
          buildingName: building.name,
          campusId: campus.id,
          campusName: campus.name,
          cadPath: (m['cadPath'] ?? '').toString(),
          imagePath: imagePath,
          detailPath:
              _resolveLocalPath(dirPath, (m['detail'] ?? '').toString()),
          roomCount: int.tryParse('${m['roomCount']}') ?? 0,
          raw: node.raw,
        ));
      }

      return FloorCrawlResult(
        sourceUrl: (map['sourceUrl'] ?? platformCampusUrl).toString(),
        origin: (map['origin'] ?? 'http://210.30.202.99').toString(),
        buildingId: building.id,
        buildingName: building.name,
        campusId: campus.id,
        campusName: campus.name,
        floors: infos,
        outputDir: dirPath,
        manifestPath: manifestFile.path,
        crawledAt: DateTime.tryParse((map['crawledAt'] ?? '').toString()) ??
            DateTime.now(),
        buildingPhotoPath: await BuildingPhotoStore.resolve(dirPath),
      );
    } catch (_) {
      return null;
    }
  }

  String? _resolveLocalPath(String base, String path) {
    if (path.isEmpty) return null;
    if (path.startsWith('/')) return path;
    return '$base/$path';
  }

  Future<Map<String, String?>> _loadBuildingPhotos(
      List<FloorNode> buildings) async {
    final photos = <String, String?>{};
    for (final building in buildings) {
      photos[building.id] =
          await BuildingPhotoStore.resolve(_buildingDir(building));
    }
    return photos;
  }

  Future<Map<String, BuildingInfo?>> _loadBuildingInfos(
      List<FloorNode> buildings) async {
    final infos = <String, BuildingInfo?>{};
    for (final building in buildings) {
      infos[building.id] =
          await BuildingPhotoStore.readInfo(_buildingDir(building));
    }
    return infos;
  }

  /// 更新某栋楼的照片状态；清掉图片缓存并递增版本，保证替换后立刻刷新。
  Future<void> _setBuildingPhoto(String buildingId, String? path) async {
    final previous = _buildingPhotos[buildingId];
    if (previous != null) await FileImage(File(previous)).evict();
    if (path != null) await FileImage(File(path)).evict();
    if (!mounted) return;
    setState(() {
      _buildingPhotos[buildingId] = path;
      _photoVersion++;
    });
  }

  /// 从平台重新采集当前楼的照片与简介。
  Future<void> _recaptureCurrentBuilding() async {
    final campus = _campus;
    final building = _building;
    if (campus == null || building == null || _busy) return;
    setState(() => _busy = true);
    _addLog('--- 重新采集 ${building.name} 楼照片与简介 ---');
    try {
      final session = await _ensureSession();
      final crawler = BuildingInfoCrawler(session: session, addLog: _addLog);
      final info = await crawler.collectBuilding(
        campus: campus,
        building: building,
        outputDir: _outputController.text.trim(),
      );
      final path = await BuildingPhotoStore.resolve(_buildingDir(building));
      await _setBuildingPhoto(building.id, path);
      if (!mounted) return;
      setState(() => _buildingInfos[building.id] = info);
      _addLog('已重新采集 ${building.name}：${info?.statsLine ?? '无简介'}\n');
    } catch (e) {
      final text = e.toString();
      final needLogin = text.contains('401') || text.contains('登录态');
      if (!needLogin) await _resetSession();
      if (mounted) {
        setState(() => _chromeState = needLogin
            ? _ChromeState.waitingLogin
            : _ChromeState.error);
      }
      _addLog('重新采集失败: $text\n');
      if (!needLogin) _showError('重新采集失败', e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 删除当前楼栋已采集的照片。
  Future<void> _removeBuildingPhoto() async {
    final building = _building;
    if (building == null || _busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除楼照片'),
        content: Text('确定删除「${building.name}」已采集的楼照片吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await BuildingPhotoStore.remove(_buildingDir(building));
      await _setBuildingPhoto(building.id, null);
      _addLog('已删除 ${building.name} 的楼照片\n');
    } catch (e) {
      _addLog('删除楼照片失败: $e\n');
      _showError('删除楼照片失败', e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 从平台批量采集当前校区每栋楼的一张照片与简介，可中途停止。
  Future<void> _collectCampusInfo() async {
    final campus = _campus;
    if (campus == null || _busy || campus.children.isEmpty) return;
    final mode = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('采集楼照片与简介'),
        content: Text(
          '复用已登录的 Chrome 会话，从平台读取 '
          '${campus.name} ${campus.children.length} 栋楼：\n'
          '每栋取平台第一张楼照片，并保存使用单位数、建筑面积、'
          '使用面积与文字简介。\n'
          '「仅补采缺失」会跳过已采集过的楼。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'all'),
            child: const Text('全部重新采集'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, 'missing'),
            child: const Text('仅补采缺失'),
          ),
        ],
      ),
    );
    if (mode == null || !mounted) return;
    setState(() {
      _busy = true;
      _crawling = true;
      _collectingInfo = true;
      _cancelCollect = false;
      _crawlDone = 0;
      _crawlTotal = campus.children.length;
      _showBuildingList = true;
    });
    _addLog('--- 采集 ${campus.name} 楼照片与简介'
        '（${mode == 'all' ? '全部重采' : '仅补缺'}）---');
    try {
      final session = await _ensureSession();
      final crawler = BuildingInfoCrawler(session: session, addLog: _addLog);
      final result = await crawler.collectCampus(
        campus: campus,
        outputDir: _outputController.text.trim(),
        onlyMissing: mode != 'all',
        shouldStop: () => _cancelCollect,
        onProgress: (done, total, _) {
          if (!mounted) return;
          setState(() {
            _crawlDone = done;
            _crawlTotal = total;
          });
        },
      );
      final photos = await _loadBuildingPhotos(campus.children);
      final infos = await _loadBuildingInfos(campus.children);
      if (!mounted) return;
      setState(() {
        _buildingPhotos = photos;
        _buildingInfos = infos;
        _photoVersion++;
      });
      _addLog('楼照片与简介采集完成：${result.summary}\n');
      if (result.failures.isNotEmpty) {
        _addLog('未采集成功（前 10）：'
            '${result.failures.take(10).join('；')}\n');
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.summary)),
      );
      await widget.onOutputDirSaved(_outputController.text.trim());
    } catch (e) {
      final text = e.toString();
      final needLogin = text.contains('401') || text.contains('登录态');
      if (!needLogin) await _resetSession();
      if (mounted) {
        setState(() => _chromeState = needLogin
            ? _ChromeState.waitingLogin
            : _ChromeState.error);
      }
      _addLog('采集楼照片与简介失败: $text\n');
      if (!needLogin) _showError('采集楼照片与简介失败', e);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _crawling = false;
          _collectingInfo = false;
          _cancelCollect = false;
        });
      }
    }
  }

  List<FloorInfo> _placeholderFloors(FloorNode campus, FloorNode building) {
    return building.children
        .map((node) => FloorInfo(
              id: node.id,
              name: node.name,
              buildingId: building.id,
              buildingName: building.name,
              campusId: campus.id,
              campusName: campus.name,
              cadPath: '',
              imagePath: null,
              detailPath: null,
              roomCount: 0,
              raw: node.raw,
            ))
        .toList();
  }

  Future<void> _crawlBuilding() async {
    final campus = _campus;
    final building = _building;
    if (campus == null || building == null || _busy) return;

    setState(() {
      _busy = true;
      _crawling = true;
      _crawlDone = 0;
      _crawlTotal = building.children.length;
      _result = null;
      _showBuildingInfoView = false;
    });
    _addLog('--- 爬取 ${building.name} ---');
    try {
      final session = await _ensureSession();
      final crawler = ChromeFloorCrawler(
        session: session,
        outputDir: _outputController.text.trim(),
        addLog: _addLog,
      );
      final result = await crawler.crawlBuilding(
        tree: _campuses,
        campus: campus,
        building: building,
        onProgress: (done, total, floor) {
          if (!mounted) return;
          setState(() {
            _crawlDone = done;
            _crawlTotal = total;
            if (floor != null) {
              final index = _floors.indexWhere((f) => f.id == floor.id);
              if (index >= 0) _floors[index] = floor;
            }
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _floors = result.floors;
        _selectedIndex = defaultFloorSelectionIndex(_floors);
        _localResults[building.id] = result;
        _statuses[building.id] =
            BuildingStatus.fromResult(building.children.length, result);
        _buildingPhotos[building.id] = result.buildingPhotoPath;
        _statusLoading = false;
        _localDataVersion++;
        _chromeState = _ChromeState.ready;
      });
      final noImageCount = result.floors.where((f) => f.cadPath.isEmpty).length;
      _addLog('爬取完成：${result.floors.length} 层，'
          '图片 ${result.floors.where((f) => f.hasImage).length} 张'
          '${noImageCount == 0 ? '' : '，$noImageCount 层平台无图'}\n');
      await widget.onOutputDirSaved(_outputController.text.trim());
    } catch (e) {
      final text = e.toString();
      final needLogin = text.contains('401') || text.contains('登录态');
      if (!needLogin) await _resetSession();
      if (mounted) {
        setState(() {
          _chromeState =
              needLogin ? _ChromeState.waitingLogin : _ChromeState.error;
        });
      }
      _addLog('爬取失败: $text\n');
      if (!needLogin) _showError('爬取失败', e);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _crawling = false;
        });
      }
    }
  }

  /// 依次爬取当前校区所有未完成楼栋，可中途停止。
  Future<void> _crawlAllIncomplete() async {
    final campus = _campus;
    if (campus == null || _busy) return;
    if (_statusLoading) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('正在检测本地获取状态，请稍候再试')),
      );
      return;
    }
    final pending = _incompleteBuildings;
    if (pending.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前校区没有未完成楼栋')),
      );
      return;
    }

    final totalFloors =
        pending.fold<int>(0, (sum, b) => sum + b.children.length);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('批量爬取未完成楼栋'),
        content: Text('将依次爬取 ${pending.length} 栋楼宇，共 $totalFloors 层。\n'
            '可能需要较长时间，期间可以点击「停止批量爬取」。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('开始爬取'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _busy = true;
      _crawling = true;
      _crawlAll = true;
      _cancelCrawlAll = false;
      _crawlAllIndex = 0;
      _crawlAllTotal = pending.length;
      _crawlAllSuccess = 0;
      _crawlAllFailed = 0;
      _crawlDone = 0;
      _crawlTotal = 0;
      _result = null;
      _showBuildingList = false;
      _showBuildingInfoView = false;
    });
    _addLog('--- 批量爬取未完成：${pending.length} 栋 / $totalFloors 层 ---');

    try {
      final session = await _ensureSession();
      final crawler = ChromeFloorCrawler(
        session: session,
        outputDir: _outputController.text.trim(),
        addLog: _addLog,
      );

      for (var i = 0; i < pending.length; i++) {
        if (_cancelCrawlAll) break;
        final building = pending[i];
        if (_statuses[building.id]?.completed == true) continue;

        setState(() {
          _buildingId = building.id;
          _showBuildingList = false;
          _crawlAllIndex = i + 1;
          _crawlDone = 0;
          _crawlTotal = building.children.length;
          _result = null;
          _floors = _placeholderFloors(campus, building);
          _selectedIndex = defaultFloorSelectionIndex(_floors);
        });
        _addLog('--- 批量 ${i + 1}/${pending.length}：${building.name} ---');

        try {
          final result = await crawler.crawlBuilding(
            tree: _campuses,
            campus: campus,
            building: building,
            shouldStop: () => _cancelCrawlAll,
            onProgress: (done, total, floor) {
              if (!mounted) return;
              setState(() {
                _crawlDone = done;
                _crawlTotal = total;
                if (floor != null) {
                  final index = _floors.indexWhere((f) => f.id == floor.id);
                  if (index >= 0) _floors[index] = floor;
                }
              });
            },
          );
          if (!mounted) return;
          final status =
              BuildingStatus.fromResult(building.children.length, result);
          setState(() {
            _result = result;
            _floors = result.floors;
            _selectedIndex = defaultFloorSelectionIndex(_floors);
            _localResults[building.id] = result;
            _statuses[building.id] = status;
            _buildingPhotos[building.id] = result.buildingPhotoPath;
            if (status.completed) {
              _crawlAllSuccess++;
            } else {
              _crawlAllFailed++;
            }
          });
          _addLog('${building.name}: ${status.label} '
              '${status.hasNoImages ? '（平台无户型图）' : '(${status.imageCount}/${status.expectedImages})'}\n');
        } catch (e) {
          final text = e.toString();
          final needLogin = text.contains('401') || text.contains('登录态');
          _addLog('批量爬取 ${building.name} 失败: $text\n');
          if (mounted) {
            setState(() {
              _crawlAllFailed++;
              _chromeState =
                  needLogin ? _ChromeState.waitingLogin : _ChromeState.error;
            });
          }
          if (needLogin) break;
          if (text.contains('MCP') ||
              text.contains('Chrome') ||
              text.contains('WebSocket')) {
            await _resetSession();
            _addLog('MCP 会话异常，停止批量爬取\n');
            break;
          }
        }
      }

      _addLog(_cancelCrawlAll
          ? '批量爬取已停止：成功 $_crawlAllSuccess，未完成/失败 $_crawlAllFailed\n'
          : '批量爬取结束：成功 $_crawlAllSuccess，未完成/失败 $_crawlAllFailed\n');
      await widget.onOutputDirSaved(_outputController.text.trim());
    } catch (e) {
      final text = e.toString();
      final needLogin = text.contains('401') || text.contains('登录态');
      if (!needLogin) await _resetSession();
      if (mounted) {
        setState(() {
          _chromeState =
              needLogin ? _ChromeState.waitingLogin : _ChromeState.error;
        });
      }
      _addLog('批量爬取失败: $text\n');
      if (!needLogin) _showError('批量爬取失败', e);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _crawling = false;
          _crawlAll = false;
          _cancelCrawlAll = false;
          _statusLoading = false;
          _localDataVersion++;
        });
      }
    }
  }

  void _showError(String title, Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$title: $error')),
    );
  }

  Future<void> _openDirectory(String path) async {
    try {
      final dir = Directory(path);
      if (!await dir.exists()) await dir.create(recursive: true);
      await Process.run(
        'xdg-open',
        [dir.path],
        workingDirectory: _safeWorkingDirectory(),
      );
    } catch (e) {
      _addLog('打开目录失败: $e\n');
    }
  }

  Future<void> _openFile(String path) async {
    try {
      await Process.run(
        'xdg-open',
        [path],
        workingDirectory: _safeWorkingDirectory(),
      );
    } catch (e) {
      _addLog('打开文件失败: $e\n');
    }
  }

  String _safeWorkingDirectory() {
    final home = Platform.environment['HOME'];
    if (home != null && Directory(home).existsSync()) return home;
    return Directory.systemTemp.path;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('楼层管理'),
        actions: [
          IconButton(
            onPressed: () => _openDirectory(
                _result?.outputDir ?? _outputController.text.trim()),
            icon: const Icon(Icons.folder_open),
            tooltip: '打开输出目录',
          ),
          IconButton(
            onPressed: () => setState(() => _log = '日志已清空'),
            icon: const Icon(Icons.delete_sweep),
            tooltip: '清空日志',
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _buildControlCard(),
            if (_crawling) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: _progressValue),
              const SizedBox(height: 4),
              Text(_progressText, style: const TextStyle(fontSize: 12)),
            ],
            const SizedBox(height: 12),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                      width: 360,
                      child: _showBuildingList
                          ? _buildBuildingList()
                          : _buildFloorList()),
                  const SizedBox(width: 12),
                  Expanded(child: _buildPreview()),
                ],
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(height: 120, child: _buildLogPanel()),
          ],
        ),
      ),
    );
  }

  Widget _buildControlCard() {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                _buildStatusChip(),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    '校区/楼宇列表会缓存到本地，未登录也能浏览；'
                    '登录后点击「加载楼栋」可刷新并爬取。',
                    style: TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: _busy ? null : _startChrome,
                  icon: const Icon(Icons.login),
                  label: const Text('启动登录 Chrome'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _loadTree,
                  icon: const Icon(Icons.refresh),
                  label: const Text('加载楼栋'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                DropdownMenu<String>(
                  key: ValueKey('campus-$_campusKeyVersion'),
                  width: 180,
                  initialSelection: _campusId,
                  label: const Text('校区'),
                  dropdownMenuEntries: _campuses
                      .map((c) => DropdownMenuEntry(value: c.id, label: c.name))
                      .toList(),
                  onSelected: (value) {
                    if (value != null) _selectCampus(value);
                  },
                ),
                if (_building != null && !_showBuildingList)
                  Chip(
                    avatar: const Icon(Icons.apartment, size: 16),
                    label: Text(
                      '当前楼宇：${_building!.name}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                ElevatedButton.icon(
                  onPressed: (_busy || _showBuildingList || _building == null)
                      ? null
                      : _crawlBuilding,
                  icon: const Icon(Icons.travel_explore),
                  label: Text(
                      _crawling ? '爬取中 $_crawlDone/$_crawlTotal' : '爬取当前楼栋'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 16),
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: (_busy ||
                          _statusLoading ||
                          _campuses.isEmpty ||
                          _incompleteBuildings.isEmpty)
                      ? null
                      : _crawlAllIncomplete,
                  icon: const Icon(Icons.playlist_add_check),
                  label: Text(_crawlAll
                      ? '批量爬取中...'
                      : '爬取所有未完成 (${_incompleteBuildings.length})'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 16),
                    backgroundColor: Colors.orange.shade800,
                    foregroundColor: Colors.white,
                  ),
                ),
                if (_crawlAll)
                  OutlinedButton.icon(
                    onPressed: _cancelCrawlAll
                        ? null
                        : () => setState(() => _cancelCrawlAll = true),
                    icon: const Icon(Icons.stop),
                    label: Text(_cancelCrawlAll ? '正在停止...' : '停止批量爬取'),
                  ),
                OutlinedButton.icon(
                  onPressed: _building == null ? null : _showBuildingInfoDialog,
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: const Text('查看楼照片与简介'),
                ),
                OutlinedButton.icon(
                  onPressed: (_busy || _campuses.isEmpty)
                      ? null
                      : _collectCampusInfo,
                  icon: const Icon(Icons.cloud_download_outlined),
                  label: Text(_collectingInfo
                      ? '采集中 $_crawlDone/$_crawlTotal'
                      : '采集楼照片与简介'),
                ),
                OutlinedButton.icon(
                  onPressed: (_busy || _building == null || _campuses.isEmpty)
                      ? null
                      : _recaptureCurrentBuilding,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重新采集当前楼'),
                ),
                if (_collectingInfo)
                  OutlinedButton.icon(
                    onPressed: _cancelCollect
                        ? null
                        : () => setState(() => _cancelCollect = true),
                    icon: const Icon(Icons.stop),
                    label: Text(_cancelCollect ? '正在停止...' : '停止采集'),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _outputController,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: '本地输出目录',
                helperText: '保存 tree.json、floors.json、details/ 与 images/',
                prefixIcon: Icon(Icons.folder),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusChip() {
    late final Color color;
    late final String text;
    switch (_chromeState) {
      case _ChromeState.idle:
        color = Colors.grey;
        text = 'Chrome 未启动';
        break;
      case _ChromeState.starting:
        color = Colors.blue;
        text = '正在启动 Chrome';
        break;
      case _ChromeState.waitingLogin:
        color = Colors.orange;
        text = '等待登录';
        break;
      case _ChromeState.ready:
        color = Colors.green;
        text = '已登录 / 可爬取';
        break;
      case _ChromeState.cached:
        color = Colors.blueGrey;
        text = '本地缓存';
        break;
      case _ChromeState.error:
        color = Colors.red;
        text = '连接失败';
        break;
    }
    return Chip(
      avatar: Icon(Icons.circle, size: 10, color: color),
      label: Text(text, style: const TextStyle(fontSize: 12)),
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _buildBuildingList() {
    final campus = _campus;
    final buildings = _filteredBuildings;
    final completed =
        buildings.where((b) => _statuses[b.id]?.completed == true).length;
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 4, 4),
            child: Row(
              children: [
                const Icon(Icons.apartment, size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${campus?.name ?? '校区'} · 楼宇列表',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_statusLoading)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Text(
                    '已完成 $completed/${buildings.length}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                IconButton(
                  onPressed: _statusLoading
                      ? null
                      : () => unawaited(_refreshLocalData()),
                  icon: const Icon(Icons.refresh, size: 18),
                  tooltip: '刷新获取状态',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              controller: _buildingSearchController,
              decoration: const InputDecoration(
                hintText: '搜索楼宇',
                prefixIcon: Icon(Icons.search, size: 18),
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => setState(() => _buildingFilter = value),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: buildings.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _buildings.isEmpty
                            ? '本地暂无楼栋缓存。登录后点击「加载楼栋」，'
                                '成功加载过一次即可离线浏览'
                            : '没有匹配的楼宇',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey.shade600),
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: buildings.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final building = buildings[index];
                      final status = _statuses[building.id] ??
                          BuildingStatus.fromResult(
                              building.children.length, null);
                      final photoPath = _buildingPhotos[building.id];
                      return ListTile(
                        leading:
                            _buildingPhotoThumb(photoPath, status.completed),
                        title: Text(
                          building.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          _buildingSubtitle(status, building.children.length,
                              photoPath != null),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              onPressed: _busy
                                  ? null
                                  : () => setState(() {
                                        _buildingId = building.id;
                                        _showBuildingInfoView = false;
                                      }),
                              icon: Icon(
                                photoPath != null
                                    ? Icons.photo_camera_outlined
                                    : Icons.info_outline,
                                size: 18,
                                color: photoPath != null
                                    ? Colors.green
                                    : Colors.grey,
                              ),
                              tooltip: '查看「${building.name}」的楼照片与简介',
                              visualDensity: VisualDensity.compact,
                            ),
                            _statusBadge(status),
                          ],
                        ),
                        onTap:
                            _busy ? null : () => _selectBuilding(building.id),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  String _buildingSubtitle(
      BuildingStatus status, int totalFloors, bool hasPhoto) {
    final photo = hasPhoto ? ' · 楼照片已采集' : ' · 无楼照片';
    if (status.completed && status.hasNoImages) {
      return '$totalFloors 层 · 平台无户型图$photo';
    }
    if (status.noImageFloors > 0) {
      return '$totalFloors 层 · '
          '图片 ${status.imageCount}/${status.expectedImages} · '
          '${status.noImageFloors} 层无图$photo';
    }
    if (status.crawledFloors == 0) {
      return '$totalFloors 层 · 未获取$photo';
    }
    final expected =
        status.expectedImages == 0 ? totalFloors : status.expectedImages;
    return '$totalFloors 层 · 图片 ${status.imageCount}/$expected$photo';
  }

  /// 有楼照片时列表头像显示缩略图，否则沿用原来的状态图标。
  Widget _buildingPhotoThumb(String? path, bool completed) {
    if (path == null) {
      return CircleAvatar(
        radius: 16,
        backgroundColor:
            completed ? Colors.green.shade50 : Colors.grey.shade100,
        child: Icon(
          completed ? Icons.check : Icons.apartment,
          size: 16,
          color: completed ? Colors.green : Colors.grey,
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 36,
        height: 36,
        child: Image.file(
          File(path),
          key: ValueKey('thumb-$path#$_photoVersion'),
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const Icon(
            Icons.broken_image_outlined,
            size: 18,
            color: Colors.grey,
          ),
        ),
      ),
    );
  }

  Widget _statusBadge(BuildingStatus status) {
    final color = status.completed ? Colors.green : Colors.grey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        status.label,
        style: TextStyle(
          fontSize: 11,
          color: color.shade700,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _buildFloorList() {
    final floors = _floors;
    final building = _building;
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 12, 6),
            child: Row(
              children: [
                IconButton(
                  onPressed: () => setState(() => _showBuildingList = true),
                  icon: const Icon(Icons.arrow_back),
                  tooltip: '返回楼宇列表',
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  onPressed: () =>
                      setState(() => _showBuildingInfoView = true),
                  icon: const Icon(Icons.photo_camera_outlined),
                  tooltip: '查看当前楼照片与简介',
                  visualDensity: VisualDensity.compact,
                ),
                Expanded(
                  child: Text(
                    building == null
                        ? '楼层列表'
                        : '${building.name} · ${floors.length} 层',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (building != null)
                  _statusBadge(_statuses[building.id] ??
                      BuildingStatus.fromResult(
                          building.children.length, _result)),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: floors.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _busy ? '正在加载...' : '本地暂无楼栋缓存，登录后点击「加载楼栋」',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey.shade600),
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: floors.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final floor = floors[index];
                      final selected = index == _selectedIndex;
                      final crawled = floor.roomCount > 0 ||
                          floor.hasImage ||
                          floor.detailPath != null;
                      return ListTile(
                        selected: selected,
                        selectedTileColor:
                            Theme.of(context).colorScheme.primaryContainer,
                        leading: CircleAvatar(
                          radius: 16,
                          child: Text(
                            '${index + 1}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        title: Text(
                          floor.name.isEmpty ? floor.id : floor.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          !crawled
                              ? '待爬取'
                              : '房间 ${floor.roomCount} · '
                                  '${floor.hasImage ? '图片已保存' : (floor.cadPath.isEmpty ? '平台无户型图' : '户型图未下载')}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: Icon(
                          !crawled
                              ? Icons.schedule
                              : (floor.hasImage
                                  ? Icons.image
                                  : Icons.image_not_supported_outlined),
                          size: 18,
                          color: floor.hasImage
                              ? Colors.green
                              : Colors.grey.shade400,
                        ),
                        onTap: _busy
                            ? null
                            : () => setState(() {
                                  _selectedIndex = index;
                                  _showBuildingInfoView = false;
                                }),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreview() {
    if (_showBuildingList || _showBuildingInfoView) {
      return _buildBuildingPhotoPreview();
    }
    final result = _result;
    final floors = _floors;
    if (floors.isEmpty || _building == null) {
      return _previewPlaceholder(
        icon: Icons.apartment,
        text: '先启动 Chrome、登录平台并加载楼栋',
      );
    }
    if (result == null) {
      return _previewPlaceholder(
        icon: Icons.download_outlined,
        text: '已选择「${_building!.name}」，点击「爬取当前楼栋」\n'
            '获取楼层详情与户型图',
      );
    }

    final index = _selectedIndex.clamp(0, floors.length - 1);
    final floor = floors[index];

    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        floor.name.isEmpty ? floor.id : floor.name,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${floor.campusName} / ${floor.buildingName} · '
                        '房间 ${floor.roomCount} · ID ${floor.id}',
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade600),
                      ),
                    ],
                  ),
                ),
                if (floor.imagePath != null)
                  IconButton(
                    onPressed: () => _openFile(floor.imagePath!),
                    icon: const Icon(Icons.open_in_new),
                    tooltip: '打开户型图原图',
                  ),
                IconButton(
                  onPressed: () =>
                      setState(() => _showBuildingInfoView = true),
                  icon: const Icon(Icons.apartment_outlined),
                  tooltip: '查看楼照片与简介',
                ),
                IconButton(
                  onPressed: () => _openDirectory(result.outputDir),
                  icon: const Icon(Icons.folder),
                  tooltip: '打开楼层目录',
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: FloorMapView(key: ValueKey('map-${floor.id}'), floor: floor),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
            child: SelectableText(
              floor.imagePath == null
                  ? '详情: ${floor.detailPath ?? '未获取到楼层详情'}'
                  : '本地文件: ${floor.imagePath}',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              maxLines: 2,
            ),
          ),
        ],
      ),
    );
  }

  /// 随时可打开的楼照片与简介弹窗，不依赖当前处于哪个预览视图。
  Future<void> _showBuildingInfoDialog() async {
    final building = _building;
    if (building == null) return;
    final path = _currentBuildingPhoto;
    final info = _currentBuildingInfo;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('${building.name} · 楼照片与简介'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (path != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(
                      File(path),
                      key: ValueKey('dialog-$path#$_photoVersion'),
                      height: 260,
                      width: double.infinity,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => const SizedBox(
                        height: 80,
                        child: Center(child: Text('楼照片无法显示')),
                      ),
                    ),
                  )
                else
                  Container(
                    height: 120,
                    width: double.infinity,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text('尚未采集楼照片'),
                  ),
                const SizedBox(height: 12),
                if (info != null) ...[
                  Text(
                    info.statsLine,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  if (info.description.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    SelectableText(
                      info.description,
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade800),
                    ),
                  ],
                ] else
                  const Text('尚未采集平台简介，可点击「采集楼照片与简介」'),
                if (path != null) ...[
                  const SizedBox(height: 8),
                  SelectableText(
                    '本地文件: $path',
                    style:
                        TextStyle(fontSize: 11, color: Colors.grey.shade700),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          if (path != null)
            TextButton(
              onPressed: () => _openFile(path),
              child: const Text('打开原图'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 楼栋列表模式：查看 / 采集当前楼的照片，并显示校区采集进度。
  Widget _buildBuildingPhotoPreview() {
    final building = _building;
    final path = _currentBuildingPhoto;
    final info = _currentBuildingInfo;
    final captured =
        _buildings.where((b) => _buildingPhotos[b.id] != null).length;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '楼照片与简介 · ${building?.name ?? '未选择楼宇'}',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${_campus?.name ?? ''} · 已采集 $captured/${_buildings.length} 栋 · 每栋一张',
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade600),
                      ),
                    ],
                  ),
                ),
                if (!_showBuildingList && _showBuildingInfoView)
                  IconButton(
                    onPressed: () =>
                        setState(() => _showBuildingInfoView = false),
                    icon: const Icon(Icons.arrow_back),
                    tooltip: '返回楼层预览',
                  ),
                IconButton(
                  onPressed: (_busy || building == null)
                      ? null
                      : _recaptureCurrentBuilding,
                  icon: const Icon(Icons.cloud_download_outlined),
                  tooltip: '从平台重新采集当前楼的照片与简介',
                ),
                if (path != null) ...[
                  IconButton(
                    onPressed: _busy ? null : () => _openFile(path),
                    icon: const Icon(Icons.open_in_new),
                    tooltip: '打开楼照片原图',
                  ),
                  IconButton(
                    onPressed: _busy ? null : _removeBuildingPhoto,
                    icon: const Icon(Icons.delete_outline),
                    tooltip: '删除楼照片',
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: path == null
                ? _previewPlaceholder(
                    icon: Icons.apartment,
                    text: '「${building?.name ?? '当前楼宇'}」尚未采集\n'
                        '点击「采集楼照片与简介」从平台批量采集，\n'
                        '或点右上角按钮只重新采集当前楼',
                  )
                : ColoredBox(
                    color: Colors.grey.shade200,
                    child: Image.file(
                      File(path),
                      key: ValueKey('building-photo-$path#$_photoVersion'),
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => const Center(
                        child: Text('楼照片无法显示'),
                      ),
                    ),
                  ),
          ),
          if (info != null || path != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (info != null) ...[
                    Text(
                      info.statsLine,
                      style: const TextStyle(
                          fontSize: 12.5, fontWeight: FontWeight.w600),
                    ),
                    if (info.description.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      SelectableText(
                        info.description,
                        maxLines: 3,
                        style: TextStyle(
                            fontSize: 11.5, color: Colors.grey.shade700),
                      ),
                    ],
                    const SizedBox(height: 4),
                  ],
                  if (path != null)
                    SelectableText(
                      '本地文件: $path',
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey.shade700),
                      maxLines: 2,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _previewPlaceholder({required IconData icon, required String text}) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFF4F9FD), Color(0xFFE2EDF6)],
              ),
            ),
          ),
          Positioned(
            right: -70,
            top: -70,
            child: _placeholderHalo(230, 0.05),
          ),
          Positioned(
            left: -60,
            bottom: -90,
            child: _placeholderHalo(280, 0.04),
          ),
          Center(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 40,
                    color: const Color(0xFF0891B2).withValues(alpha: 0.85),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    text,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.6,
                      color: Colors.grey.shade700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _placeholderHalo(double size, double opacity) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF38BDF8).withValues(alpha: opacity),
      ),
    );
  }

  Widget _buildLogPanel() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text(
                '运行日志',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              IconButton(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: _log));
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('日志已复制到剪贴板')),
                  );
                },
                icon: const Icon(Icons.copy, size: 16, color: Colors.white70),
                tooltip: '复制日志',
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          Expanded(
            child: SingleChildScrollView(
              child: SelectableText(
                _log,
                style: const TextStyle(
                  color: Colors.greenAccent,
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
