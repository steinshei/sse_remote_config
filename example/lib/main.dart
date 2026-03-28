import 'package:flutter/material.dart';
import 'package:remote_config_lib/remote_config_lib.dart';

import 'platform_init_io.dart'
    if (dart.library.html) 'platform_init_web.dart'
    as platform_init;

/// Base URL including `/v1`, e.g. `http://127.0.0.1:8787/v1`.
/// Run mock: `dart run ../tool/mock_config_server.dart`
/// Then: `flutter run --dart-define=CONFIG_API_BASE=http://127.0.0.1:8787/v1`
const String _configApiBase = String.fromEnvironment(
  'CONFIG_API_BASE',
  defaultValue: '',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await platform_init.ensurePlatformStorageReady();

  const analytics = NoOpRemoteConfigAnalytics();

  final sample = ConfigBundle.fromJson({
    'version': 1,
    'data': {
      'theme_color': '#1976D2',
      'feature_flags': {'new_reader_enabled': true},
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
  });

  late final RemoteConfigClient client;
  final crashPersistence = MemoryCrashRecoveryPersistence();
  final crash = CrashRecoveryCoordinator(
    persistence: crashPersistence,
    analytics: analytics,
    onRollback: () async {
      await client.emergencyRollback(
        safeMergedData: {'reader_engine': 'legacy', 'use_safe_mode': true},
      );
    },
  );

  final RemoteConfigDataSource dataSource = _configApiBase.isEmpty
      ? StubRemoteConfigDataSource(sample)
      : HttpRemoteConfigDataSource(baseUrl: _configApiBase);

  client = RemoteConfigClient(
    dataSource: dataSource,
    storage: MmkvConfigStorage(),
    requestContext: const ConfigRequestContext(
      appId: 'remote_config_example',
      platform: 'android',
      appVersion: '1.0.0',
    ),
    defaults: {'theme_color': '#333333', 'welcome_title': 'Remote Config'},
    userId: 'example-user',
    analytics: analytics,
    onImmediateActivationCommitted: (b) => crash.notifyImmediateActivate(b),
  );

  await crash.handleAppLaunch();

  final sync = RemoteConfigSyncCoordinator(
    client: client,
    analytics: analytics,
    sseBaseUrl: _configApiBase,
    enableSse: _configApiBase.isNotEmpty,
    pollMinInterval: const Duration(seconds: 2),
  );

  await sync.start();

  WidgetsBinding.instance.addPostFrameCallback((_) {
    crash.handleLaunchSuccess();
  });

  runApp(BootstrapApp(client: client, sync: sync));
}

class BootstrapApp extends StatefulWidget {
  const BootstrapApp({super.key, required this.client, required this.sync});

  final RemoteConfigClient client;
  final RemoteConfigSyncCoordinator sync;

  @override
  State<BootstrapApp> createState() => _BootstrapAppState();
}

class _BootstrapAppState extends State<BootstrapApp> {
  @override
  void dispose() {
    widget.sync.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ExampleApp(client: widget.client);
  }
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key, required this.client});

  final RemoteConfigClient client;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Remote Config Example',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
      home: HomePage(client: client),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.client});

  final RemoteConfigClient client;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late String _themeColor;
  late String _readerEngine;
  late bool _newReader;
  int? _version;
  late String _mode;

  @override
  void initState() {
    super.initState();
    _mode = _configApiBase.isEmpty ? 'stub' : 'http+sse ($_configApiBase)';
    _pull();
    widget.client.onConfigUpdated.listen((_) {
      if (mounted) {
        setState(_pull);
      }
    });
  }

  void _pull() {
    var newReader = false;
    final flags = widget.client.getValue('feature_flags');
    if (flags is Map) {
      final v = flags['new_reader_enabled'];
      newReader = v == true || v == 1 || v == 'true';
    }
    setState(() {
      _themeColor = widget.client.getString('theme_color');
      _readerEngine = widget.client.getString(
        'reader_engine',
        defaultValue: '(none)',
      );
      _newReader = newReader;
      _version = widget.client.activeVersion;
    });
  }

  Color _parseColor(String hex) {
    var s = hex.trim();
    if (s.startsWith('#')) {
      s = s.substring(1);
    }
    if (s.length == 6) {
      s = 'FF$s';
    }
    final v = int.tryParse(s, radix: 16);
    if (v == null) {
      return Colors.blue;
    }
    return Color(v);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.client.getString('welcome_title')),
        backgroundColor: _parseColor(_themeColor),
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Mode: $_mode', style: Theme.of(context).textTheme.labelLarge),
            Text(
              'Active version: ${_version ?? '-'}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Text('theme_color: $_themeColor'),
            Text('reader_engine (A/B): $_readerEngine'),
            Text('new_reader_enabled: $_newReader'),
            const Spacer(),
            FilledButton(
              onPressed: () async {
                await widget.client.fetchAndActivate(forceFullFetch: true);
                _pull();
              },
              child: const Text('fetchAndActivate'),
            ),
          ],
        ),
      ),
    );
  }
}
