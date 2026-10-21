import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'actions/chrome_launcher.dart';
import 'actions/floor_action.dart';
import 'actions/floor_mcp_action.dart';
import 'actions/mcp_client.dart';

enum _ChromeState { idle, starting, waitingLogin, ready, error }

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
  String _buildingFilter = '';
  Map<String, BuildingStatus> _statuses = {};
  Map<String, FloorCrawlResult?> _localResults = {};
  bool _statusLoading = false;
  int _localDataVersion = 0;

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
    if (_crawlAll) {
      if (_crawlAllIndex == 0) return '准备批量爬取...';
      return '批量爬取 $_crawlAllIndex/$_crawlAllTotal：'
          '${_building?.name ?? ''} · $_crawlDone/$_crawlTotal 层';
    }
    return '正在爬取 $_crawlDone / $_crawlTotal 层';
  }

  FloorNode? get _building =>
      _firstWhereOrNull(_buildings, (b) => b.id == _buildingId);

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
        _chromeState = _ChromeState.ready;
      });
      _addLog('已加载：${campus.name} / ${building?.name ?? '暂无楼栋'}'
          '，共 ${_buildings.length} 栋\n');
      unawaited(_refreshLocalData());
    } catch (e) {
      if (!mounted) return;
      final text = e.toString();
      final needLogin = text.contains('401') || text.contains('登录态');
      if (!needLogin) await _resetSession();
      if (!mounted) return;
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
    for (final building in campus.children) {
      final result = await _readLocalResult(campus, building);
      results[building.id] = result;
      statuses[building.id] =
          BuildingStatus.fromResult(building.children.length, result);
    }
    if (!mounted || version != _localDataVersion) return;
    setState(() {
      _localResults = results;
      _statuses = statuses;
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

  /// 读取本地 floors.json；不存在或损坏时返回 null。
  Future<FloorCrawlResult?> _readLocalResult(
      FloorNode campus, FloorNode building) async {
    final base = _outputController.text.trim().isEmpty
        ? defaultFloorOutputDir()
        : _outputController.text.trim();
    final dirPath = '$base/${sanitizeFileName(building.name)}_${building.id}';
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
                    '通过本地 Chrome MCP 复用浏览器登录态；'
                    '首次使用会通过 npx 启动 chrome-devtools-mcp。',
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
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _outputController,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: '本地输出目录',
                helperText: '保存 floors.json、details/ 与 images/',
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
                            ? '启动 Chrome 登录后，点击「加载楼栋」'
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
                      return ListTile(
                        leading: CircleAvatar(
                          radius: 16,
                          backgroundColor: status.completed
                              ? Colors.green.shade50
                              : Colors.grey.shade100,
                          child: Icon(
                            status.completed ? Icons.check : Icons.apartment,
                            size: 16,
                            color:
                                status.completed ? Colors.green : Colors.grey,
                          ),
                        ),
                        title: Text(
                          building.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          _buildingSubtitle(status, building.children.length),
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: _statusBadge(status),
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

  String _buildingSubtitle(BuildingStatus status, int totalFloors) {
    if (status.completed && status.hasNoImages) {
      return '$totalFloors 层 · 平台无户型图';
    }
    if (status.noImageFloors > 0) {
      return '$totalFloors 层 · '
          '图片 ${status.imageCount}/${status.expectedImages} · '
          '${status.noImageFloors} 层无图';
    }
    if (status.crawledFloors == 0) {
      return '$totalFloors 层 · 未获取';
    }
    final expected =
        status.expectedImages == 0 ? totalFloors : status.expectedImages;
    return '$totalFloors 层 · 图片 ${status.imageCount}/$expected';
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
                        _busy ? '正在加载...' : '启动 Chrome 登录后，点击「加载楼栋」',
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
                            : () => setState(() => _selectedIndex = index),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreview() {
    if (_showBuildingList) {
      return _previewPlaceholder(
        icon: Icons.list_alt,
        text: '在左侧选择 ${_campus?.name ?? '校区'} 楼宇\n'
            '查看楼层详情与获取状态',
      );
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
    final image = floor.imagePath;

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
                if (image != null)
                  IconButton(
                    onPressed: () => _openFile(image),
                    icon: const Icon(Icons.open_in_new),
                    tooltip: '打开图片',
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
            child: image == null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          floor.cadPath.isEmpty
                              ? Icons.image_not_supported_outlined
                              : Icons.broken_image_outlined,
                          size: 56,
                          color: Colors.grey.shade400,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          floor.cadPath.isEmpty ? '平台未上传该楼层户型图' : '户型图未下载成功',
                        ),
                        if (floor.cadPath.isEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            '该楼层仍按已完成统计',
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey.shade600),
                          ),
                        ],
                        if (floor.cadPath.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          SelectableText(
                            'cadPath: ${floor.cadPath}',
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey.shade600),
                          ),
                        ],
                      ],
                    ),
                  )
                : Container(
                    color: Colors.grey.shade100,
                    child: InteractiveViewer(
                      minScale: 0.2,
                      maxScale: 6,
                      child: Center(
                        child: Image.file(
                          File(image),
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => const Text('图片加载失败'),
                        ),
                      ),
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
            child: SelectableText(
              image == null
                  ? '详情: ${floor.detailPath ?? '未获取到楼层详情'}'
                  : '本地文件: $image',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              maxLines: 2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _previewPlaceholder({required IconData icon, required String text}) {
    return Card(
      margin: EdgeInsets.zero,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600),
            ),
          ],
        ),
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
