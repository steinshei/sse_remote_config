// ignore_for_file: avoid_print
// Minimal Config API mock for local / CI — see docs/api-contract-v1.md
// Run: dart run tool/mock_config_server.dart
//      dart run tool/mock_config_server.dart --port=8787
// Example: flutter run --dart-define=CONFIG_API_BASE=http://localhost:8787/v1
import 'dart:async';
import 'dart:convert';
import 'dart:io';

int _port = 8787;
int _version = 42;
int _chapterPrice = 0;
bool _newReaderEnabled = false;

Map<String, dynamic> get _bundle => {
  'version': _version,
  'data': {
    'reader_engine': 'new',
    'theme_color': '#FF5722',
    'chapter_price': _chapterPrice,
    'home_banner': {'id': 1, 'img': 'https://cdn.example.com/banner/1.png'},
    'feature_flags': {'new_reader_enabled': _newReaderEnabled},
  },
  'conditions': {
    'region': 'ID',
    'app_version': '>=2.5.0',
    'rollout_percentage': 10,
  },
  '_meta': {
    'risk_level': 'low',
    'requires_validation': false,
    'rollback_on_crash': false,
    'delay_activation': 'immediate',
  },
  'experiments': [
    {
      'key': 'reader_engine_ab',
      'bucket_count': 2,
      'variants': {
        '0': {'reader_engine': 'legacy'},
        '1': {'reader_engine': 'new'},
      },
    },
  ],
};

final _sseClients = <HttpResponse>[];

Future<void> main(List<String> args) async {
  for (final a in args) {
    if (a.startsWith('--port=')) {
      _port = int.parse(a.split('=').last);
    }
  }

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, _port);
  print(
    'mock_config_server listening on http://${server.address.host}:${server.port}/v1/ …',
  );
  print(
    'Try: curl "http://127.0.0.1:$_port/v1/config/latest?app_id=demo&platform=android"',
  );

  //定期心跳响应 + 供演示时使用的可选震动（每 45 秒进行一次震动版本更新并发出通知）。
  Timer.periodic(const Duration(seconds: 5), (_) => _broadcastSseComment());
  Timer.periodic(const Duration(seconds: 10), (_) {
    _version++;
    _chapterPrice += 100;
    _newReaderEnabled = !_newReaderEnabled;
    _broadcastConfigUpdated();
  });

  await for (final req in server) {
    unawaited(_handle(req));
  }
}

Future<void> _handle(HttpRequest req) async {
  final path = req.uri.path;
  try {
    if (req.method == 'GET' && path.endsWith('/config/latest')) {
      await _json(req.response, _bundle);
    } else if (req.method == 'GET' && path.endsWith('/config/delta')) {
      final since = int.tryParse(req.uri.queryParameters['since'] ?? '');
      if (since == null) {
        req.response.statusCode = 400;
        await req.response.close();
        return;
      }
      if (_version > since) {
        await _json(req.response, _bundle);
      } else {
        req.response.statusCode = 204;
        await req.response.close();
      }
    } else if (req.method == 'GET' && path.endsWith('/config/stream')) {
      await _sse(req);
    } else {
      req.response.statusCode = 404;
      await req.response.close();
    }
  } catch (e, st) {
    stderr.writeln('$e\n$st');
    try {
      req.response.statusCode = 500;
      await req.response.close();
    } catch (_) {}
  }
}

Future<void> _json(HttpResponse res, Object obj) async {
  res.headers.contentType = ContentType.json;
  res.write(jsonEncode(obj));
  await res.close();
}

Future<void> _sse(HttpRequest req) async {
  final res = req.response;
  res.statusCode = 200;
  res.headers.set('Content-Type', 'text/event-stream; charset=utf-8');
  res.headers.set('Cache-Control', 'no-cache');
  res.headers.set('Connection', 'keep-alive');

  // 优化：发送一个稍微大一点的初始化注释，打破某些浏览器的 1024 字节缓冲限制
  res.write(': ${' ' * 1024}\n');
  res.write(': hello\n\n');
  await res.flush();

  _sseClients.add(res);
}

// 修改 _broadcastSseComment
Future<void> _broadcastSseComment() async {
  // 加上 async
  final dead = <HttpResponse>[];
  final now = DateTime.now().toUtc().toIso8601String();

  // 使用 List.from 避免在遍历时因删除元素导致异常
  for (final res in List.from(_sseClients)) {
    try {
      res.write(': keepalive $now v=$_version\n\n');
      await res.flush(); // 现在可以安全使用 await 了
    } catch (_) {
      dead.add(res);
    }
  }
  _sseClients.removeWhere(dead.contains);
}

// 修改 _broadcastConfigUpdated
Future<void> _broadcastConfigUpdated() async {
  // 加上 async
  final payload = jsonEncode({'version': _version, 'kind': 'publish'});
  final dead = <HttpResponse>[];

  for (final res in List.from(_sseClients)) {
    try {
      res.write('event: config_updated\n');
      res.write('data: $payload\n\n');
      await res.flush(); // 强制刷新，减少客户端延时
    } catch (_) {
      dead.add(res);
    }
  }
  _sseClients.removeWhere(dead.contains);
}
