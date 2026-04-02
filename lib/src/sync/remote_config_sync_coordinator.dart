import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../analytics/remote_config_analytics.dart';
import '../models/config_request_context.dart';
import '../remote_config_client.dart';
import '../realtime/config_notification.dart';
import '../realtime/realtime_notification_transport.dart';
import '../sse/config_sse_client.dart';

typedef RealtimeNotificationTransportFactory =
    RealtimeNotificationTransport Function({
      required String baseUrl,
      required ConfigRequestContext context,
      required http.Client httpClient,
    });

/// Wires [RemoteConfigClient] with optional SSE, polling floor, connectivity, and lifecycle.
class RemoteConfigSyncCoordinator with WidgetsBindingObserver {
  RemoteConfigSyncCoordinator({
    required this.client,
    required this.analytics,
    required this.sseBaseUrl,
    this.enableSse = true,
    this.pollMinInterval = const Duration(minutes: 5),
    Connectivity? connectivity,
    http.Client? httpClient,
    RealtimeNotificationTransportFactory? transportFactory,
  }) : connectivity = connectivity ?? Connectivity(),
       _httpClient = httpClient ?? http.Client(),
       _transportFactory = transportFactory ?? _defaultTransportFactory;

  final RemoteConfigClient client;
  final RemoteConfigAnalytics analytics;
  final String sseBaseUrl;
  final bool enableSse;
  final Duration pollMinInterval;
  final Connectivity connectivity;
  final http.Client _httpClient;
  final RealtimeNotificationTransportFactory _transportFactory;

  RealtimeNotificationTransport? _transport;
  StreamSubscription<ConfigNotification>? _transportSub;
  StreamSubscription<List<ConnectivityResult>>? _netSub;
  Timer? _pollTimer;
  DateTime? _lastFetchAt;
  bool _observing = false;

  Future<void> start() async {
    await client.initialize();
    await client.fetchAndActivate();
    _lastFetchAt = DateTime.now();

    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(pollMinInterval, (_) {
      unawaited(_pollIfDue(reason: 'timer'));
    });

    _netSub ??= connectivity.onConnectivityChanged.listen((_) {
      unawaited(_pollIfDue(reason: 'connectivity'));
    });

    if (enableSse && sseBaseUrl.isNotEmpty) {
      await _startSse();
    }

    if (!_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
  }

  Future<void> stop() async {
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
    await _stopSse();
    await _netSub?.cancel();
    _netSub = null;
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_pollIfDue(reason: 'resumed'));
      if (enableSse && sseBaseUrl.isNotEmpty) {
        unawaited(_startSse());
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      unawaited(_stopSse());
    }
  }

  Future<void> _pollIfDue({required String reason}) async {
    final last = _lastFetchAt;
    if (last != null && DateTime.now().difference(last) < pollMinInterval) {
      return;
    }
    analytics.pollTick(reason: reason);
    await _fetch();
  }

  Future<void> _fetch() async {
    try {
      await client.fetchAndActivate();
      _lastFetchAt = DateTime.now();
    } catch (_) {
      // Host may log; polling continues.
    }
  }

  Future<void> _startSse() async {
    await _stopSse();
    analytics.sseConnectAttempt();
    final sw = Stopwatch()..start();
    try {
      _transport = _transportFactory(
        baseUrl: sseBaseUrl,
        context: client.requestContext,
        httpClient: _httpClient,
      );
      _transportSub = _transport!.notifications.listen((n) {
        if (n.event == 'ping') {
          analytics.sseCommentOrPing();
          return;
        }
        analytics.sseEventReceived(event: n.event);
        if (n.event == 'config_updated' || n.event == 'config_revoke') {
          unawaited(_fetch());
        }
      });
      await _transport!.start();
      analytics.sseConnectResult(
        success: true,
        durationMs: sw.elapsedMilliseconds,
      );
    } catch (_) {
      analytics.sseConnectResult(
        success: false,
        durationMs: sw.elapsedMilliseconds,
      );
    }
  }

  Future<void> _stopSse() async {
    await _transportSub?.cancel();
    _transportSub = null;
    if (_transport != null) {
      await _transport!.dispose();
      analytics.sseDisconnected(reason: 'paused_or_stop');
    }
    _transport = null;
  }

  static RealtimeNotificationTransport _defaultTransportFactory({
    required String baseUrl,
    required ConfigRequestContext context,
    required http.Client httpClient,
  }) {
    return SseConfigNotificationTransport(
      baseUrl: baseUrl,
      context: context,
      httpClient: httpClient,
    );
  }
}
