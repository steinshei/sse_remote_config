import 'dart:async';
import 'dart:convert';

import 'ab/stable_bucket.dart';
import 'analytics/remote_config_analytics.dart';
import 'models/config_bundle.dart';
import 'models/config_request_context.dart';
import 'models/config_update.dart';
import 'remote/remote_config_data_source.dart';
import 'storage/config_storage.dart';

/// Remote config façade: defaults + active persistence + fetch/activate.
class RemoteConfigClient {
  RemoteConfigClient({
    required RemoteConfigDataSource dataSource,
    required ConfigStorage storage,
    required ConfigRequestContext requestContext,
    Map<String, Object?> defaults = const {},
    String userId = 'anonymous',
    this.validateBeforeActivate,
    this.analytics = const NoOpRemoteConfigAnalytics(),
    this.onImmediateActivationCommitted,
  })  : _dataSource = dataSource,
        _storage = storage,
        _context = requestContext,
        _defaults = Map<String, Object?>.from(defaults),
        _userId = userId {
    _hydrate();
  }

  final RemoteConfigDataSource _dataSource;
  final ConfigStorage _storage;
  ConfigRequestContext _context;
  final Map<String, Object?> _defaults;

  String _userId;
  int? _activeVersion;
  Map<String, dynamic> _activeData = {};

  final _updates = StreamController<ConfigUpdate>.broadcast();

  final RemoteConfigAnalytics analytics;

  /// Optional sandbox / validation — return `false` to skip persistence.
  final Future<bool> Function(ConfigBundle candidate)? validateBeforeActivate;

  /// After an **immediate** activation is persisted (not `next_launch` staging).
  final Future<void> Function(ConfigBundle bundle)? onImmediateActivationCommitted;

  ConfigRequestContext get requestContext => _context;

  /// Fired after local activation succeeds.
  Stream<ConfigUpdate> get onConfigUpdated => _updates.stream;

  int? get activeVersion => _activeVersion;

  String get userId => _userId;

  void setUserId(String id) {
    _userId = id;
  }

  void setRequestContext(ConfigRequestContext context) {
    _context = context;
  }

  void _hydrate() {
    _activeVersion = _storage.readVersion();
    final stored = _storage.readData();
    _activeData = stored ?? {};
  }

  /// Apply `next_launch` pending payload, then continue normal reads.
  Future<void> initialize() async {
    final pending = _storage.readPendingBundleJson();
    if (pending == null || pending.isEmpty) {
      return;
    }
    try {
      final map = jsonDecode(pending) as Map<String, dynamic>;
      final b = ConfigBundle.fromJson(map);
      await activate(b, applyingPending: true);
    } catch (_) {
      await _storage.clearPendingBundle();
    }
  }

  Map<String, Object?> _effectiveMap() {
    final merged = <String, Object?>{..._defaults, ..._activeData};
    return merged;
  }

  String getString(String key, {String defaultValue = ''}) {
    final v = _effectiveMap()[key];
    if (v == null) {
      return defaultValue;
    }
    if (v is String) {
      return v;
    }
    return v.toString();
  }

  bool getBool(String key, {bool defaultValue = false}) {
    final v = _effectiveMap()[key];
    if (v == null) {
      return defaultValue;
    }
    if (v is bool) {
      return v;
    }
    if (v is num) {
      return v != 0;
    }
    if (v is String) {
      final lower = v.toLowerCase();
      if (lower == 'true' || lower == '1' || lower == 'yes') {
        return true;
      }
      if (lower == 'false' || lower == '0' || lower == 'no') {
        return false;
      }
    }
    return defaultValue;
  }

  int getInt(String key, {int defaultValue = 0}) {
    final v = _effectiveMap()[key];
    if (v == null) {
      return defaultValue;
    }
    if (v is int) {
      return v;
    }
    if (v is num) {
      return v.toInt();
    }
    if (v is String) {
      return int.tryParse(v) ?? defaultValue;
    }
    return defaultValue;
  }

  dynamic getValue(String key) => _effectiveMap()[key];

  Future<void> fetchAndActivate({bool forceFullFetch = false}) async {
    final since = (!forceFullFetch && _activeVersion != null) ? _activeVersion : null;
    final sw = Stopwatch()..start();
    analytics.fetchStarted(sinceVersion: since);
    try {
      late final ConfigBundle bundle;
      if (since == null) {
        bundle = await _dataSource.fetchLatest(_context);
      } else {
        final delta = await _dataSource.fetchDelta(_context, since);
        if (!delta.hasUpdate) {
          analytics.fetchCompleted(
            success: true,
            durationMs: sw.elapsedMilliseconds,
            sinceVersion: since,
          );
          return;
        }
        bundle = delta.bundle!;
      }
      await activate(bundle);
      analytics.fetchCompleted(
        success: true,
        durationMs: sw.elapsedMilliseconds,
        sinceVersion: since,
      );
    } catch (e) {
      analytics.fetchCompleted(
        success: false,
        durationMs: sw.elapsedMilliseconds,
        sinceVersion: since,
      );
      rethrow;
    }
  }

  Future<void> activate(ConfigBundle bundle, {bool applyingPending = false}) async {
    if (_activeVersion != null && bundle.version < _activeVersion!) {
      return;
    }
    if (!applyingPending && _activeVersion != null && bundle.version == _activeVersion!) {
      return;
    }

    final delayRaw = bundle.meta?['delay_activation'] as String?;
    final delay = delayRaw ?? 'immediate';
    final defer = !applyingPending && delay == 'next_launch';

    if (defer) {
      await _storage.writePendingBundleJson(jsonEncode(bundle.toJson()));
      analytics.delayActivationScheduled(version: bundle.version);
      return;
    }

    final merged = _mergeExperiments(bundle);
    final toPersist = bundle.copyWithMergedData(merged);
    final guard = validateBeforeActivate;
    if (guard != null && !await guard(toPersist)) {
      analytics.sandboxRejected(version: bundle.version);
      return;
    }
    await _storage.clearPendingBundle();
    await _storage.write(version: bundle.version, data: merged);
    _activeVersion = bundle.version;
    _activeData = Map<String, dynamic>.from(merged);
    if (!_updates.isClosed) {
      _updates.add(ConfigUpdate(version: bundle.version));
    }
    analytics.activationApplied(version: bundle.version);
    final cb = onImmediateActivationCommitted;
    if (cb != null) {
      await cb(bundle);
    }
  }

  /// L3 rollback: replace active config (and clear pending). Host supplies safe merged map.
  Future<void> emergencyRollback({Map<String, dynamic>? safeMergedData}) async {
    final from = _activeVersion;
    await _storage.clearPendingBundle();
    await _storage.write(
      version: 0,
      data: Map<String, dynamic>.from(safeMergedData ?? {}),
    );
    _hydrate();
    analytics.crashRollbackTriggered(fromVersion: from);
  }

  Map<String, dynamic> _mergeExperiments(ConfigBundle bundle) {
    var result = Map<String, dynamic>.from(bundle.data);
    final experiments = bundle.experiments;
    if (experiments == null) {
      return result;
    }
    final uid = _userId;
    for (final exp in experiments) {
      final idx = stableBucketIndex(
        userId: uid,
        experimentKey: exp.key,
        experimentRevision: exp.revision,
        bucketCount: exp.bucketCount,
      );
      final fragment = exp.variants['$idx'];
      if (fragment != null) {
        result = {...result, ...fragment};
      }
    }
    return result;
  }

  Future<void> dispose() async {
    await _updates.close();
  }
}
