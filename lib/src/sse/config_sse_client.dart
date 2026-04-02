import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/config_request_context.dart';
import '../realtime/config_notification.dart';
import '../realtime/realtime_notification_transport.dart';

/// SSE notify — see [docs/api-contract-v1.md] §4.
class SseConfigNotificationTransport implements RealtimeNotificationTransport {
  SseConfigNotificationTransport({
    required this.baseUrl,
    required this.context,
    http.Client? httpClient,
    this.reconnectDelayMs = 1000,
    this.reconnectDelayMaxMs = 30000,
  }) : _client = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  /// Root including `/v1`, same as [HttpRemoteConfigDataSource].
  final String baseUrl;
  ConfigRequestContext context;
  final http.Client _client;
  final bool _ownsClient;

  int reconnectDelayMs;
  int reconnectDelayMaxMs;

  final _events = StreamController<ConfigNotification>.broadcast();
  @override
  Stream<ConfigNotification> get notifications => _events.stream;

  StreamSubscription<String>? _lineSub;
  http.StreamedResponse? _response;
  Timer? _reconnectTimer;
  bool _stopping = false;
  bool _disposed = false;
  String _carry = '';

  /// `event` field from last line group; defaults to `message`.
  String _currentEvent = 'message';

  @override
  Future<void> start() => _connect();

  @override
  Future<void> stop() async {
    _stopping = true;
    _reconnectTimer?.cancel();
    await _lineSub?.cancel();
    _lineSub = null;
    // Client does not expose abort on streamed response; subscription cancel stops listener.
    _stopping = false;
  }

  Future<void> _scheduleReconnect() async {
    if (_stopping || _disposed) {
      return;
    }
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: reconnectDelayMs), () {
      final next = (reconnectDelayMs * 2).clamp(1000, reconnectDelayMaxMs);
      reconnectDelayMs = next;
      unawaited(_connect());
    });
  }

  Future<void> _connect() async {
    if (_stopping || _disposed) {
      return;
    }
    await _lineSub?.cancel();
    try {
      final root = baseUrl.endsWith('/')
          ? baseUrl.substring(0, baseUrl.length - 1)
          : baseUrl;
      final uri = Uri.parse(root).replace(
        path: '${Uri.parse(root).path}/config/stream',
        queryParameters: context.toQueryParameters(),
      );
      final req = http.Request('GET', uri);
      req.headers['Accept'] = 'text/event-stream';
      req.headers.addAll(context.headers);
      _response = await _client.send(req);
      if (_response!.statusCode != 200) {
        await _scheduleReconnect();
        return;
      }
      reconnectDelayMs = 1000;
      _carry = '';
      _lineSub = _response!.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            _onLine,
            onError: (_) => unawaited(_scheduleReconnect()),
            onDone: () => unawaited(_scheduleReconnect()),
          );
    } catch (_) {
      await _scheduleReconnect();
    }
  }

  void _onLine(String line) {
    if (line.isEmpty) {
      _flushEvent();
      return;
    }
    if (line.startsWith(':')) {
      return;
    }
    if (line.startsWith('event:')) {
      _currentEvent = line.substring(6).trim();
      return;
    }
    if (line.startsWith('data:')) {
      final piece = line.startsWith('data: ')
          ? line.substring(6)
          : line.substring(5).trimLeft();
      _carry = _carry.isEmpty ? piece : '$_carry\n$piece';
    }
  }

  void _flushEvent() {
    final raw = _carry.trim();
    _carry = '';
    if (raw.isEmpty) {
      _currentEvent = 'message';
      return;
    }
    Map<String, dynamic>? json;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        json = decoded;
      } else if (decoded is Map) {
        json = Map<String, dynamic>.from(
          decoded.map((k, dynamic v) => MapEntry(k.toString(), v)),
        );
      }
    } catch (_) {}
    final event = _currentEvent;
    _currentEvent = 'message';
    if (!_events.isClosed) {
      _events.add(ConfigNotification(event: event, data: json, raw: raw));
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await stop();
    await _events.close();
    if (_ownsClient) {
      _client.close();
    }
  }
}

/// Backward-compatible SSE client name for callers importing the old API.
class ConfigSseClient extends SseConfigNotificationTransport {
  ConfigSseClient({
    required super.baseUrl,
    required super.context,
    super.httpClient,
    super.reconnectDelayMs,
    super.reconnectDelayMaxMs,
  });
}
