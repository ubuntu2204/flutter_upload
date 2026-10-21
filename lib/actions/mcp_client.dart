import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// chrome-devtools-mcp 的默认版本（与本地测试通过的版本一致）。
const String chromeMcpPackageVersion = '1.11.0';

/// MCP 工具调用返回的文本结果。
class McpToolResult {
  final String text;
  final bool isError;

  const McpToolResult({required this.text, this.isError = false});

  /// evaluate 的返回值是 JSON 字符串；解析失败时回退为原始文本。
  dynamic get jsonValue {
    try {
      return jsonDecode(text);
    } catch (_) {
      return text;
    }
  }
}

/// 最小可用的 MCP stdio 客户端。
///
/// 只实现本项目需要的 JSON-RPC 方法：initialize、tools/list、tools/call，
/// 以及 ping / roots/list 的服务端请求应答。
class McpStdioClient {
  final Process _process;
  final void Function(String) _addLog;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  final StringBuffer _stderrTail = StringBuffer();
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  int _nextId = 1;
  bool _closed = false;

  McpStdioClient._(this._process, this._addLog);

  /// 启动 MCP 服务并完成 initialize 握手。
  static Future<McpStdioClient> start({
    required void Function(String) addLog,
    List<String> args = const [],
  }) async {
    final executable = await _resolveNpx();
    final process = await Process.start(
      executable,
      args,
      runInShell: false,
      // 应用自身的工作目录可能已被删除（例如重新构建 bundle），
      // 子进程继续继承会触发 Node 的 uv_cwd ENOENT，必须固定到稳定目录。
      workingDirectory: _safeWorkingDirectory(),
    );
    final client = McpStdioClient._(process, addLog);
    client._listen();
    await client._initialize();
    return client;
  }

  static String _safeWorkingDirectory() {
    final home = Platform.environment['HOME'];
    if (home != null && Directory(home).existsSync()) return home;
    return Directory.systemTemp.path;
  }

  static Future<String> _resolveNpx() async {
    final direct = await _which('npx');
    if (direct != null) return direct;

    // 应用从桌面启动时可能没有加载 nvm 的 PATH，用登录 shell 再找一次。
    try {
      final shell = await Process.run(
        'bash',
        ['-lc', 'command -v npx'],
        workingDirectory: _safeWorkingDirectory(),
      );
      if (shell.exitCode == 0) {
        final path = shell.stdout.toString().trim();
        if (path.isNotEmpty) return path;
      }
    } catch (_) {}

    final home = Platform.environment['HOME'];
    if (home != null) {
      final versionsDir = Directory('$home/.nvm/versions/node');
      if (await versionsDir.exists()) {
        final candidates = await versionsDir
            .list()
            .where((e) => e is Directory)
            .cast<Directory>()
            .map((d) => '${d.path}/bin/npx')
            .where((p) => File(p).existsSync())
            .toList();
        candidates.sort();
        if (candidates.isNotEmpty) return candidates.last;
      }
    }
    throw McpException('未找到 npx。请先安装 Node.js（建议 22+），并确保 npx 在 PATH 中。');
  }

  static Future<String?> _which(String name) async {
    try {
      final r = await Process.run(
        'which',
        [name],
        workingDirectory: _safeWorkingDirectory(),
      );
      if (r.exitCode == 0) {
        final path = r.stdout.toString().trim();
        if (path.isNotEmpty) return path;
      }
    } catch (_) {}
    return null;
  }

  void _listen() {
    _subscriptions.add(_process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleLine, onError: (Object e) {
      _addLog('[mcp][stdout] $e\n');
    }));

    _subscriptions.add(_process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (line.trim().isEmpty) return;
      _stderrTail.writeln(line);
      if (_stderrTail.length > 4000) {
        final text = _stderrTail.toString();
        _stderrTail
          ..clear()
          ..write(text.substring(text.length - 2000));
      }
      final lower = line.toLowerCase();
      if (lower.contains('error') ||
          lower.contains('failed') ||
          lower.contains('warn')) {
        _addLog('[mcp] $line\n');
      }
    }, onError: (Object e) {
      _addLog('[mcp][stderr] $e\n');
    }));

    unawaited(_process.exitCode.then((code) {
      _closed = true;
      final message = 'MCP 服务已退出（code=$code）';
      for (final completer in _pending.values) {
        if (!completer.isCompleted) {
          completer.completeError(McpException(message));
        }
      }
      _pending.clear();
      _addLog('$message\n');
    }));
  }

  void _handleLine(String line) {
    if (line.trim().isEmpty) return;
    Map<String, dynamic> message;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) return;
      message = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return;
    }

    // 服务端主动发来的请求（ping / roots/list 等）
    if (message.containsKey('method')) {
      _handleServerRequest(message);
      return;
    }

    final id = message['id'];
    if (id is int) {
      final completer = _pending.remove(id);
      if (completer != null && !completer.isCompleted) {
        completer.complete(message);
      }
    }
  }

  Future<void> _handleServerRequest(Map<String, dynamic> message) async {
    final id = message['id'];
    if (id == null) return; // notification
    final method = (message['method'] ?? '').toString();
    dynamic result;
    if (method == 'ping') {
      result = <String, dynamic>{};
    } else if (method == 'roots/list') {
      result = {'roots': <dynamic>[]};
    } else {
      await _send({
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': -32601, 'message': 'Method not found: $method'},
      });
      return;
    }
    await _send({'jsonrpc': '2.0', 'id': id, 'result': result});
  }

  Future<void> _initialize() async {
    final response = await _request(
        'initialize',
        {
          'protocolVersion': '2024-11-05',
          'capabilities': <String, dynamic>{},
          'clientInfo': {'name': 'flutter_upload', 'version': '1.0.0'},
        },
        timeout: const Duration(seconds: 120));

    final error = response['error'];
    if (error != null) {
      throw McpException('MCP initialize 失败: $error');
    }
    await _send({'jsonrpc': '2.0', 'method': 'notifications/initialized'});
    _addLog('MCP 服务已就绪\n');
  }

  Future<List<String>> listTools() async {
    final response = await _request('tools/list', {});
    final tools = response['result']?['tools'];
    if (tools is! List) return const [];
    return tools
        .whereType<Map>()
        .map((t) => (t['name'] ?? '').toString())
        .where((name) => name.isNotEmpty)
        .toList();
  }

  Future<McpToolResult> callTool(
    String name,
    Map<String, dynamic> arguments, {
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final response = await _request(
        'tools/call',
        {
          'name': name,
          'arguments': arguments,
        },
        timeout: timeout);

    final error = response['error'];
    if (error is Map) {
      throw McpException('MCP 工具 $name 调用失败: ${error['message'] ?? error}');
    }
    final result = response['result'];
    if (result is! Map) {
      throw McpException('MCP 工具 $name 返回格式异常');
    }
    final content = result['content'];
    final buffer = StringBuffer();
    if (content is List) {
      for (final item in content) {
        if (item is Map && item['type'] == 'text') {
          buffer.write(item['text'] ?? '');
        }
      }
    }
    return McpToolResult(
      text: buffer.toString(),
      isError: result['isError'] == true,
    );
  }

  Future<Map<String, dynamic>> _request(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 120),
  }) async {
    if (_closed) throw McpException('MCP 服务已关闭');
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    await _send({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      throw McpException('MCP 调用超时: $method');
    } finally {
      _pending.remove(id);
    }
  }

  Future<void> _send(Map<String, dynamic> message) async {
    if (_closed) throw McpException('MCP 服务已关闭');
    try {
      _process.stdin.writeln(jsonEncode(message));
      await _process.stdin.flush();
    } catch (e) {
      throw McpException('写入 MCP 服务失败: $e');
    }
  }

  Future<void> close() async {
    if (_closed && _pending.isEmpty) return;
    _closed = true;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(McpException('MCP 服务已关闭'));
      }
    }
    _pending.clear();
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    try {
      await _process.stdin.close();
    } catch (_) {}
    try {
      await _process.exitCode.timeout(const Duration(seconds: 2));
    } catch (_) {
      _process.kill();
    }
  }
}

/// 基于 MCP 的 Chrome 页面会话，封装 evaluate / navigate。
class McpChromeSession {
  final McpStdioClient client;

  McpChromeSession(this.client);

  Future<void> navigate(String url) async {
    final result = await client.callTool('navigate', {'url': url},
        timeout: const Duration(seconds: 60));
    if (result.isError) throw McpException(result.text);
  }

  /// 等待页面加载完成并确认登录态可用。
  ///
  /// 刚导航到平台时 Nuxt 可能还在 hydration；直接调用业务接口偶尔会失败。
  /// 这里轮询 document.readyState、localStorage Token 和一个受保护接口。
  Future<void> waitForPlatformReady({
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final info = await evaluate('''(() => ({
          href: location.href,
          ready: document.readyState,
          hasToken: (localStorage.getItem('auth._token.local') || '').length > 0
        }))()''');
        if (info is Map &&
            info['ready'] == 'complete' &&
            info['hasToken'] == true) {
          final status = await evaluate('''(async () => {
            const token = localStorage.getItem('auth._token.local') || '';
            try {
              const res = await fetch('/api/base/personal/system/home/current', {
                headers: { Authorization: token }
              });
              return res.status;
            } catch (e) {
              return 'ERROR';
            }
          })()''');
          if (status == 200) return;
        }
      } catch (_) {
        // 页面可能仍在导航/上下文重建，继续等待
      }
      await Future.delayed(const Duration(milliseconds: 800));
    }
    throw McpException('页面未就绪或登录已失效，请在 Chrome 窗口登录平台后重试。');
  }

  /// 在页面上下文执行表达式。script 必须是一个返回值的表达式，
  /// 例如 `(async () => { ... })()`。
  Future<dynamic> evaluate(
    String script, {
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final result =
        await client.callTool('evaluate', {'script': script}, timeout: timeout);
    if (result.isError) throw McpException(result.text);
    return result.jsonValue;
  }

  Future<void> close() => client.close();
}

/// 启动 chrome-devtools-mcp 并连接指定的 Chrome 调试端口。
Future<McpChromeSession> startChromeMcp({
  required int debugPort,
  required void Function(String) addLog,
  String packageVersion = chromeMcpPackageVersion,
}) async {
  addLog('启动 MCP 服务（chrome-devtools-mcp@$packageVersion）...\n');
  final client = await McpStdioClient.start(
    addLog: addLog,
    args: [
      '-y',
      'chrome-devtools-mcp@$packageVersion',
      '--browserUrl',
      'http://127.0.0.1:$debugPort',
      '--slim',
      '--no-usage-statistics',
      '--no-performance-crux',
    ],
  );

  final tools = await client.listTools();
  if (!tools.contains('evaluate') || !tools.contains('navigate')) {
    await client.close();
    throw McpException('MCP 服务未提供 evaluate/navigate 工具，'
        '请检查 chrome-devtools-mcp 版本。当前工具: ${tools.join(', ')}');
  }
  return McpChromeSession(client);
}

class McpException implements Exception {
  final String message;

  const McpException(this.message);

  @override
  String toString() => message;
}
