import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart'
    show Connectivity, ConnectivityResult;
// ignore: depend_on_referenced_packages
import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart'
    show ConnectivityPlatform;
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:remote_config_lib/remote_config_lib.dart';

void main() {
  group('stableBucketIndex', () {
    test('same inputs yield same bucket for fixed vectors', () {
      final a = stableBucketIndex(
        userId: 'u1',
        experimentKey: 'reader_engine_ab',
        bucketCount: 2,
      );
      final b = stableBucketIndex(
        userId: 'u1',
        experimentKey: 'reader_engine_ab',
        bucketCount: 2,
      );
      expect(a, b);
      expect(a, anyOf(0, 1));
    });

    test('revision changes bucket assignment', () {
      final without = stableBucketIndex(
        userId: 'u1',
        experimentKey: 'exp',
        bucketCount: 10,
      );
      final withRev = stableBucketIndex(
        userId: 'u1',
        experimentKey: 'exp',
        experimentRevision: '2',
        bucketCount: 10,
      );
      expect(without, isNot(withRev));
    });
  });

  group('RemoteConfigClient', () {
    test('activates stub and reads merged experiment variant', () async {
      final bundle = ConfigBundle.fromJson({
        'version': 7,
        'data': {'reader_engine': 'new', 'foo': 1},
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
      });
      final dataSource = StubRemoteConfigDataSource(bundle);
      final storage = MemoryConfigStorage();
      final client = RemoteConfigClient(
        dataSource: dataSource,
        storage: storage,
        requestContext: const ConfigRequestContext(
          appId: 't',
          platform: 'android',
        ),
        userId: 'fixed-user-golden',
      );
      await client.fetchAndActivate(forceFullFetch: true);
      expect(client.activeVersion, 7);
      final engine = client.getString('reader_engine');
      expect(engine, anyOf('legacy', 'new'));
      final reRead = RemoteConfigClient(
        dataSource: dataSource,
        storage: storage,
        requestContext: const ConfigRequestContext(
          appId: 't',
          platform: 'android',
        ),
        userId: 'fixed-user-golden',
      );
      expect(reRead.getString('reader_engine'), engine);
    });

    test('next_launch stores pending and initialize applies', () async {
      final bundle = ConfigBundle.fromJson({
        'version': 9,
        'data': {'flag': 'next'},
        '_meta': {'delay_activation': 'next_launch'},
      });
      final ds = StubRemoteConfigDataSource(bundle);
      final storage = MemoryConfigStorage();
      final client = RemoteConfigClient(
        dataSource: ds,
        storage: storage,
        requestContext: const ConfigRequestContext(
          appId: 't',
          platform: 'android',
        ),
      );
      await client.fetchAndActivate(forceFullFetch: true);
      expect(client.activeVersion, isNull);
      final raw = storage.readPendingBundleJson();
      expect(raw, isNotNull);
      expect(jsonDecode(raw!)['version'], 9);

      final client2 = RemoteConfigClient(
        dataSource: ds,
        storage: storage,
        requestContext: const ConfigRequestContext(
          appId: 't',
          platform: 'android',
        ),
      );
      await client2.initialize();
      expect(client2.activeVersion, 9);
      expect(client2.getString('flag'), 'next');
      expect(storage.readPendingBundleJson(), isNull);
    });
  });

  group('CrashRecoveryCoordinator', () {
    test('arms after risky immediate activation', () async {
      late RemoteConfigClient client;
      final persist = MemoryCrashRecoveryPersistence();
      final coord = CrashRecoveryCoordinator(
        persistence: persist,
        analytics: const NoOpRemoteConfigAnalytics(),
        onRollback: () async {
          await client.emergencyRollback(safeMergedData: {});
        },
      );
      client = RemoteConfigClient(
        dataSource: StubRemoteConfigDataSource(
          ConfigBundle(
            version: 1,
            data: const {},
            meta: const {'risk_level': 'high'},
          ),
        ),
        storage: MemoryConfigStorage(),
        requestContext: const ConfigRequestContext(
          appId: 't',
          platform: 'android',
        ),
        onImmediateActivationCommitted: coord.notifyImmediateActivate,
      );
      await client.fetchAndActivate(forceFullFetch: true);
      final s = await persist.load();
      expect(s.rollbackArmed, isTrue);
    });
  });

  group('SseConfigNotificationTransport', () {
    test('parses SSE events and sends expected request metadata', () async {
      final requests = <HttpRequest>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        requests.add(request);
        expect(request.uri.path, '/v1/config/stream');
        expect(request.uri.queryParameters['app_id'], 'test-app');
        expect(request.uri.queryParameters['platform'], 'android');
        expect(request.uri.queryParameters['app_version'], '1.2.3');
        expect(
          request.headers.value(HttpHeaders.acceptHeader),
          'text/event-stream',
        );
        expect(request.headers.value('authorization'), 'Bearer token');

        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        request.response.write('event: ping\n');
        request.response.write('data: {"ts":"2026-04-02T00:00:00Z"}\n\n');
        request.response.write('event: config_updated\n');
        request.response.write('data: {"version":43,\n');
        request.response.write('data: "kind":"publish"}\n\n');
        await request.response.close();
      });

      final transport = SseConfigNotificationTransport(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        context: const ConfigRequestContext(
          appId: 'test-app',
          platform: 'android',
          appVersion: '1.2.3',
          headers: {'Authorization': 'Bearer token'},
        ),
        reconnectDelayMs: 5000,
      );
      addTearDown(transport.dispose);

      final notificationsFuture = transport.notifications.take(2).toList();
      await transport.start();
      final notifications = await notificationsFuture.timeout(
        const Duration(seconds: 2),
      );

      expect(requests, hasLength(1));
      expect(notifications[0].event, 'ping');
      expect(notifications[0].data?['ts'], '2026-04-02T00:00:00Z');
      expect(notifications[1].event, 'config_updated');
      expect(notifications[1].data?['version'], 43);
      expect(notifications[1].data?['kind'], 'publish');
    });
  });

  group('RemoteConfigSyncCoordinator', () {
    late ConnectivityPlatform originalConnectivityPlatform;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      originalConnectivityPlatform = ConnectivityPlatform.instance;
    });

    tearDown(() {
      ConnectivityPlatform.instance = originalConnectivityPlatform;
    });

    test(
      'uses injected transport abstraction for fetch, pause, and resume',
      () async {
        final connectivityPlatform = _FakeConnectivityPlatform();
        ConnectivityPlatform.instance = connectivityPlatform;

        final dataSource = _CountingRemoteConfigDataSource();
        final analytics = _RecordingAnalytics();
        final transports = <_FakeRealtimeNotificationTransport>[];
        final coordinator = RemoteConfigSyncCoordinator(
          client: RemoteConfigClient(
            dataSource: dataSource,
            storage: MemoryConfigStorage(),
            requestContext: const ConfigRequestContext(
              appId: 't',
              platform: 'android',
            ),
          ),
          analytics: analytics,
          sseBaseUrl: 'https://example.com/v1',
          connectivity: Connectivity(),
          transportFactory:
              ({
                required String baseUrl,
                required ConfigRequestContext context,
                required http.Client httpClient,
              }) {
                final transport = _FakeRealtimeNotificationTransport();
                transports.add(transport);
                return transport;
              },
        );
        addTearDown(coordinator.stop);

        await coordinator.start();

        expect(dataSource.fetchLatestCalls, 1);
        expect(dataSource.fetchDeltaCalls, 0);
        expect(transports, hasLength(1));
        expect(transports[0].startCalls, 1);
        expect(analytics.sseConnectAttempts, 1);
        expect(analytics.sseConnectSuccesses, 1);

        transports[0].emit(ConfigNotification(event: 'ping', raw: 'ping'));
        await Future<void>.delayed(Duration.zero);
        expect(analytics.pingEvents, 1);
        expect(dataSource.fetchDeltaCalls, 0);

        transports[0].emit(
          ConfigNotification(
            event: 'config_updated',
            raw: '{"version":2}',
            data: {'version': 2},
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(analytics.receivedEvents, ['config_updated']);
        expect(dataSource.fetchDeltaCalls, 1);

        coordinator.didChangeAppLifecycleState(AppLifecycleState.paused);
        await Future<void>.delayed(Duration.zero);
        expect(transports[0].disposeCalls, 1);
        expect(analytics.disconnectReasons, ['paused_or_stop']);

        coordinator.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await Future<void>.delayed(Duration.zero);
        expect(transports, hasLength(2));
        expect(transports[1].startCalls, 1);
        expect(analytics.sseConnectAttempts, 2);
        expect(analytics.sseConnectSuccesses, 2);
      },
    );
  });
}

class _CountingRemoteConfigDataSource implements RemoteConfigDataSource {
  int fetchLatestCalls = 0;
  int fetchDeltaCalls = 0;

  @override
  Future<ConfigBundle> fetchLatest(ConfigRequestContext context) async {
    fetchLatestCalls += 1;
    return ConfigBundle.fromJson({
      'version': 1,
      'data': {'flag': true},
    });
  }

  @override
  Future<DeltaFetchResult> fetchDelta(
    ConfigRequestContext context,
    int sinceVersion,
  ) async {
    fetchDeltaCalls += 1;
    return DeltaFetchResult(
      bundle: ConfigBundle.fromJson({
        'version': sinceVersion + 1,
        'data': {'flag': false},
      }),
    );
  }
}

class _FakeConnectivityPlatform extends ConnectivityPlatform {
  final _changes = StreamController<List<ConnectivityResult>>.broadcast();

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async {
    return [ConnectivityResult.wifi];
  }

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => _changes.stream;
}

class _FakeRealtimeNotificationTransport
    implements RealtimeNotificationTransport {
  final _notifications = StreamController<ConfigNotification>.broadcast();
  int startCalls = 0;
  int stopCalls = 0;
  int disposeCalls = 0;

  @override
  Stream<ConfigNotification> get notifications => _notifications.stream;

  void emit(ConfigNotification notification) {
    _notifications.add(notification);
  }

  @override
  Future<void> start() async {
    startCalls += 1;
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
  }

  @override
  Future<void> dispose() async {
    disposeCalls += 1;
    await _notifications.close();
  }
}

class _RecordingAnalytics implements RemoteConfigAnalytics {
  int pingEvents = 0;
  int sseConnectAttempts = 0;
  int sseConnectSuccesses = 0;
  final List<String> receivedEvents = <String>[];
  final List<String> disconnectReasons = <String>[];

  @override
  void activationApplied({required int version}) {}

  @override
  void crashRollbackTriggered({int? fromVersion}) {}

  @override
  void delayActivationScheduled({required int version}) {}

  @override
  void fetchCompleted({
    required bool success,
    int? httpStatus,
    int? durationMs,
    int? sinceVersion,
  }) {}

  @override
  void fetchStarted({int? sinceVersion}) {}

  @override
  void pollTick({required String reason}) {}

  @override
  void sandboxRejected({required int version}) {}

  @override
  void sseCommentOrPing() {
    pingEvents += 1;
  }

  @override
  void sseConnectAttempt() {
    sseConnectAttempts += 1;
  }

  @override
  void sseConnectResult({required bool success, int? durationMs}) {
    if (success) {
      sseConnectSuccesses += 1;
    }
  }

  @override
  void sseDisconnected({String? reason}) {
    if (reason != null) {
      disconnectReasons.add(reason);
    }
  }

  @override
  void sseEventReceived({required String event}) {
    receivedEvents.add(event);
  }
}
