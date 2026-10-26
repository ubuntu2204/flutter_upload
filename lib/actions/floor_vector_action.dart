import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 与 images/ 同级的 vectors/ 中，对应户型图的 SVG 路径。
String floorVectorPathForImage(String imagePath) {
  final image = File(imagePath);
  final filename = image.uri.pathSegments.last;
  final dot = filename.lastIndexOf('.');
  final basename = dot > 0 ? filename.substring(0, dot) : filename;
  return '${image.parent.parent.path}/vectors/$basename.svg';
}

class FloorVectorProgress {
  final int done;
  final int total;
  final int converted;
  final int skipped;
  final int failed;
  final String current;
  final String error;

  const FloorVectorProgress({
    required this.done,
    required this.total,
    required this.converted,
    required this.skipped,
    required this.failed,
    this.current = '',
    this.error = '',
  });

  factory FloorVectorProgress.fromMap(Map<String, dynamic> map) {
    return FloorVectorProgress(
      done: _asInt(map['done']),
      total: _asInt(map['total']),
      converted: _asInt(map['converted']),
      skipped: _asInt(map['skipped']),
      failed: _asInt(map['failed']),
      current: (map['current'] ?? '').toString(),
      error: (map['error'] ?? '').toString(),
    );
  }

  double? get fraction => total <= 0 ? null : done / total;
}

class FloorVectorResult {
  final int total;
  final int converted;
  final int skipped;
  final int failed;
  final int svgBytes;

  const FloorVectorResult({
    required this.total,
    required this.converted,
    required this.skipped,
    required this.failed,
    required this.svgBytes,
  });

  factory FloorVectorResult.fromMap(Map<String, dynamic> map) {
    return FloorVectorResult(
      total: _asInt(map['total']),
      converted: _asInt(map['converted']),
      skipped: _asInt(map['skipped']),
      failed: _asInt(map['failed']),
      svgBytes: _asInt(map['svgBytes']),
    );
  }
}

class FloorVectorException implements Exception {
  final String message;

  const FloorVectorException(this.message);

  @override
  String toString() => message;
}

/// 扫描输出目录下所有 floors.json，把全部已下载户型图增量转换为纯路径 SVG。
Future<FloorVectorResult> convertFloorMapsToSvg(
  String outputDir, {
  void Function(String message)? addLog,
  void Function(FloorVectorProgress progress)? onProgress,
  bool force = false,
  String? projectDir,
  String? pythonExecutable,
}) async {
  final root = outputDir.trim();
  if (root.isEmpty || !await Directory(root).exists()) {
    throw FloorVectorException('楼层输出目录不存在：$root');
  }
  final projectRoot = _resolveProjectRoot(projectDir);
  final script = '$projectRoot/tool/vectorize_floor_maps.py';
  final args = <String>[
    script,
    '--root',
    root,
    if (force) '--force',
  ];

  final Process process;
  try {
    process = await Process.start(
      pythonExecutable ?? 'python3',
      args,
      workingDirectory: projectRoot,
    );
  } catch (e) {
    throw FloorVectorException('无法启动 Python 矢量转换器：$e');
  }

  final stderrFuture = process.stderr.transform(utf8.decoder).join();
  FloorVectorResult? result;
  var lastLoggedDone = 0;
  await for (final line in process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    dynamic decoded;
    try {
      decoded = jsonDecode(line);
    } catch (_) {
      addLog?.call('$line\n');
      continue;
    }
    if (decoded is! Map) continue;
    final map = Map<String, dynamic>.from(decoded);
    switch (map['type']) {
      case 'progress':
        final progress = FloorVectorProgress.fromMap(map);
        onProgress?.call(progress);
        if (progress.error.isNotEmpty) {
          addLog?.call('矢量化失败 ${progress.current}: ${progress.error}\n');
        } else if (progress.done == progress.total ||
            progress.done - lastLoggedDone >= 50) {
          lastLoggedDone = progress.done;
          addLog?.call(
            '已处理 ${progress.done}/${progress.total} 张，'
            '新增 ${progress.converted}，跳过 ${progress.skipped}\n',
          );
        }
      case 'result':
        result = FloorVectorResult.fromMap(map);
    }
  }

  final exitCode = await process.exitCode;
  final stderr = (await stderrFuture).trim();
  final completed = result;
  if (completed != null && (exitCode == 0 || completed.failed > 0)) {
    return completed;
  }
  final detail = stderr.isEmpty ? '' : '\n$stderr';
  throw FloorVectorException('矢量转换进程失败（退出码 $exitCode）$detail');
}

int _asInt(dynamic value) => value is int ? value : int.tryParse('$value') ?? 0;

String _resolveProjectRoot(String? explicit) {
  final starts = <Directory>[
    if (explicit != null && explicit.trim().isNotEmpty)
      Directory(explicit.trim()),
    Directory.current,
    File(Platform.resolvedExecutable).parent,
  ];
  for (final start in starts) {
    var dir = start.absolute;
    for (var depth = 0; depth < 10; depth++) {
      if (File('${dir.path}/tool/vectorize_floor_maps.py').existsSync()) {
        return dir.path;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
  }
  throw const FloorVectorException(
    '未找到 tool/vectorize_floor_maps.py，请从 flutter_upload 项目目录运行。',
  );
}
