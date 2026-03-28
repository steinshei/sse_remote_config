// ignore_for_file: avoid_print
// Minimal Config API mock for local / CI — see docs/api-contract-v1.md
// Run: dart run tool/mock_config_server.dart
//      dart run tool/mock_config_server.dart --port=8787
// Example: flutter run --dart-define=CONFIG_API_BASE=http://localhost:8787/v1
import 'dart:async';
import 'dart:convert';
import 'dart:io';

int _port = 8787;
int _version = 0;
int _chapter_price = 100;
bool _new_reader_enabled = false;

Map<String, dynamic> get _bundle => {
  'version': _version,
  'data': {
    'reader_engine': true,
    'theme_color': '#FF5722',
    'chapter_price': _chapter_price,
    'home_banner': {'id': 1, 'img': 'https://cdn.example.com/banner/1.png'},
    'feature_flags': {'new_reader_enabled': _new_reader_enabled},
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

  final server = await HttpServer.bind(InternetAddress.anyIPv4, _port);
  print(
    'mock_config_server listening on http://${server.address.host}:${server.port}/v1/ …',
  );
  print(
    'Try: curl "http://127.0.0.1:$_port/v1/config/latest?app_id=demo&platform=android"',
  );

  // 优化 1：心跳缩短至 5 秒，保持连接极其活跃
  Timer.periodic(const Duration(seconds: 5), (_) => _broadcastSseComment());

  // 优化 2：配置变更缩短至 10 秒（或者根据你的测试需求调整）
  Timer.periodic(const Duration(seconds: 10), (_) {
    _version++;
    _chapter_price += 100;
    _new_reader_enabled = !_new_reader_enabled;
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
  await res.flush();
  _sseClients.add(res);
  // Initial ping
  res.write(': hello\n\n');
  await res.flush();
}

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
