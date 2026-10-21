import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'actions/floor_action.dart';

/// 用户提供的示例楼栋页面；首次打开时作为默认链接。
const String _defaultBuildingUrl =
    'http://210.30.202.99/house/house-base-decision/personal/view/'
    '1294698345147666432?id=1294698345147666432&name=主楼（南湖校区）';

/// 楼层管理页：爬取楼栋楼层树、楼层详情与户型图（PNG），并本地归档。
class FloorPage extends StatefulWidget {
  final String initialToken;
  final String initialOutputDir;

  /// 爬取成功后回写 Token / 输出目录，由主页面保存到配置文件。
  final Future<void> Function(String token, String outputDir) onAuthSaved;

  const FloorPage({
    super.key,
    required this.initialToken,
    required this.initialOutputDir,
    required this.onAuthSaved,
  });

  @override
  State<FloorPage> createState() => _FloorPageState();
}

class _FloorPageState extends State<FloorPage> {
  late final TextEditingController _urlController;
  late final TextEditingController _tokenController;
  late final TextEditingController _outputController;

  bool _isCrawling = false;
  bool _obscureToken = true;
  int _selectedIndex = 0;
  String _log = '等待爬取...';
  FloorCrawlResult? _result;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: _defaultBuildingUrl);
    _tokenController = TextEditingController(text: widget.initialToken);
    _outputController = TextEditingController(
      text: widget.initialOutputDir.isEmpty
          ? defaultFloorOutputDir()
          : widget.initialOutputDir,
    );
  }

  @override
  void dispose() {
    _urlController.dispose();
    _tokenController.dispose();
    _outputController.dispose();
    super.dispose();
  }

  void _addLog(String message) {
    if (!mounted) return;
    setState(() {
      _log = '[${DateTime.now().toString().split('.').first}] $message\n$_log';
    });
  }

  Future<void> _crawl() async {
    if (_isCrawling) return;
    final token = _tokenController.text.trim();
    final output = _outputController.text.trim();
    if (token.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先填写登录 Token')),
      );
      return;
    }

    setState(() {
      _isCrawling = true;
      _result = null;
      _selectedIndex = 0;
      _log = '开始爬取...';
    });
    try {
      final result = await FloorCrawler(
        pageUrl: _urlController.text.trim(),
        token: token,
        outputDir: output,
        addLog: _addLog,
      ).run();
      if (!mounted) return;
      setState(() => _result = result);
      _addLog('爬取完成：${result.floors.length} 层，'
          '图片 ${result.floors.where((f) => f.hasImage).length} 张');
      await widget.onAuthSaved(token, output);
    } catch (e) {
      _addLog('爬取失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('爬取失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isCrawling = false);
    }
  }

  Future<void> _openDirectory(String path) async {
    try {
      final dir = Directory(path);
      if (!await dir.exists()) await dir.create(recursive: true);
      await Process.run('xdg-open', [dir.path]);
    } catch (e) {
      _addLog('打开目录失败: $e');
    }
  }

  Future<void> _openFile(String path) async {
    try {
      await Process.run('xdg-open', [path]);
    } catch (e) {
      _addLog('打开文件失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('楼层管理'),
        actions: [
          IconButton(
            onPressed: () {
              final dir = _result?.outputDir ?? _outputController.text.trim();
              _openDirectory(dir);
            },
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
            _buildInputCard(),
            if (_isCrawling) ...[
              const SizedBox(height: 8),
              const LinearProgressIndicator(),
            ],
            const SizedBox(height: 12),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: 340, child: _buildFloorList()),
                  const SizedBox(width: 12),
                  Expanded(child: _buildPreview()),
                ],
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(height: 160, child: _buildLogPanel()),
          ],
        ),
      ),
    );
  }

  Widget _buildInputCard() {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            TextField(
              controller: _urlController,
              maxLines: 2,
              minLines: 1,
              decoration: const InputDecoration(
                labelText: '楼栋页面链接',
                helperText: '支持带 id 参数的页面链接，也支持直接填写楼栋 ID',
                prefixIcon: Icon(Icons.link),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _tokenController,
                    obscureText: _obscureToken,
                    decoration: InputDecoration(
                      labelText: '登录 Token（Authorization）',
                      helperText: '浏览器 localStorage 的 auth._token.local，'
                          '形如 Bearer eyJ...',
                      prefixIcon: const Icon(Icons.key),
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        onPressed: () =>
                            setState(() => _obscureToken = !_obscureToken),
                        icon: Icon(_obscureToken
                            ? Icons.visibility
                            : Icons.visibility_off),
                        tooltip: _obscureToken ? '显示' : '隐藏',
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _outputController,
                    decoration: const InputDecoration(
                      labelText: '本地输出目录',
                      prefixIcon: Icon(Icons.folder),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  height: 56,
                  child: ElevatedButton.icon(
                    onPressed: _isCrawling ? null : _crawl,
                    icon: const Icon(Icons.travel_explore),
                    label: Text(_isCrawling ? '爬取中...' : '爬取楼层'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFloorList() {
    final floors = _result?.floors ?? const <FloorInfo>[];
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                const Icon(Icons.apartment, size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _result == null
                        ? '楼层列表'
                        : '${_result!.buildingName} · ${floors.length} 层',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_result != null)
                  Text(
                    '${floors.where((f) => f.hasImage).length} 张图',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
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
                        _isCrawling ? '正在爬取楼层数据...' : '填写链接与 Token 后点击「爬取楼层」',
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
                          '房间 ${floor.roomCount} · '
                          '${floor.hasImage ? '图片已保存' : '无户型图'}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: Icon(
                          floor.hasImage
                              ? Icons.image
                              : Icons.image_not_supported_outlined,
                          size: 18,
                          color: floor.hasImage
                              ? Colors.green
                              : Colors.grey.shade400,
                        ),
                        onTap: () => setState(() => _selectedIndex = index),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreview() {
    final result = _result;
    final floors = result?.floors ?? const <FloorInfo>[];
    if (result == null || floors.isEmpty) {
      return Card(
        margin: EdgeInsets.zero,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.image_outlined, size: 56, color: Colors.grey.shade400),
              const SizedBox(height: 12),
              Text(
                '爬取完成后，在左侧选择楼层查看户型图',
                style: TextStyle(color: Colors.grey.shade600),
              ),
            ],
          ),
        ),
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
                        Icon(Icons.broken_image_outlined,
                            size: 56, color: Colors.grey.shade400),
                        const SizedBox(height: 12),
                        const Text('该楼层没有可用的户型图'),
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
                '爬取日志',
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
