import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
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
}
