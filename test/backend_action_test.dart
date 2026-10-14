import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_upload/actions/backend_action.dart';

/// 用本地 bash 做语法检查（只解析不执行），确保生成的远程脚本引号与语法正确。
///
/// 远程脚本经 ssh 传递、多层 shell 引号嵌套，写错只会表现为"命令没生效"，
/// 无法从退出码看出问题，因此必须在这里守住。
bool shellSyntaxOk(String script) {
  final r = Process.runSync('bash', ['-n', '-c', script]);
  return r.exitCode == 0;
}

void main() {
  const startCmd = 'cd /xp/www/api.flutter.gold/bin && ./server';

  group('parseBackendBinDir', () {
    test('从 "cd <dir> && ./server" 解析目录', () {
      expect(parseBackendBinDir(startCmd), '/xp/www/api.flutter.gold/bin');
    });

    test('支持带引号的 cd 目标', () {
      expect(parseBackendBinDir("cd '/srv/a b/bin' && ./server"), '/srv/a b/bin');
    });

    test('无 cd 时返回 null（跳过备份）', () {
      expect(parseBackendBinDir('./server'), isNull);
      expect(parseBackendBinDir(''), isNull);
    });
  });

  group('远程脚本 shell 语法', () {
    test('停止脚本', () {
      expect(shellSyntaxOk(buildStopScript(18080)), isTrue);
    });

    test('备份脚本', () {
      expect(shellSyntaxOk(buildBackupScript('/srv/api/bin')), isTrue);
    });

    test('启动脚本（含中文输出与多层引号）', () {
      expect(shellSyntaxOk(buildStartScript(startCmd, 18080)), isTrue);
    });

    test('后台启动后不能直接跟分号（&; 是语法错误）', () {
      final script = buildStartScript(startCmd, 18080);
      expect(script.contains('&;'), isFalse);
      expect(script.contains('& sleep 2'), isTrue);
    });
  });

  group('启动脚本内容', () {
    final script = buildStartScript(startCmd, 18080);

    test('启动命令以 base64 内嵌且可无损还原', () {
      final m =
          RegExp(r"echo '([A-Za-z0-9+/=]+)' \| base64 -d").firstMatch(script);
      expect(m, isNotNull);
      expect(utf8.decode(base64Decode(m!.group(1)!)), startCmd);
    });

    test('健康检查使用配置的端口', () {
      expect(script.contains(':18080 '), isTrue);
      expect(script.contains('http://127.0.0.1:18080/'), isTrue);
    });

    test('进程脱离 ssh 会话，避免 ssh 挂起', () {
      expect(script.contains('setsid nohup'), isTrue);
      expect(script.contains('</dev/null'), isTrue);
      expect(script.contains('>>$remoteServerLog'), isTrue);
    });

    test('健康检查失败时打印启动日志并退出非 0', () {
      expect(script.contains('tail -20 $remoteServerLog'), isTrue);
      expect(script.trimRight().endsWith('exit 1'), isTrue);
    });
  });

  group('停止脚本内容', () {
    final script = buildStopScript(18080);

    test('先优雅停止，再强制停止', () {
      expect(script.contains('pkill -f "\$pat"'), isTrue);
      expect(script.contains('pkill -9 -f "\$pat"'), isTrue);
    });

    test('按完整命令行匹配进程（Dart AOT 的 comm 是 dart:server，-x 会失配）', () {
      expect(script.contains('pgrep -x server'), isFalse);
      expect(script.contains('pkill -x server'), isFalse);
      expect(script.contains("pat='(^\\./server\$)|(^/[^ ]*/server\$)'"), isTrue);
    });

    test('清理包装进程的模式带自排除写法，避免 pkill 杀掉执行脚本的 shell', () {
      expect(script.contains('./[s]erver'), isTrue);
    });

    test('以端口释放作为"进程死透"的最终判据', () {
      expect(script.contains('grep -q ":18080 "'), isTrue);
      expect(script.contains('exit 1'), isTrue);
    });
  });
}
