import '../analytics/remote_config_analytics.dart';
import '../models/config_bundle.dart';
import 'crash_recovery_persistence.dart';
import 'crash_recovery_state.dart';

/// L3 crash-aware rollback — see [docs/crash-rollback-attribution.md].
///
/// Call order:
/// 1. [handleAppLaunch] before [RemoteConfigClient.initialize].
/// 2. [handleLaunchSuccess] after first frame / main UI ready.
/// 3. [notifyImmediateActivate] after each **immediate** activation (host can wire via client callback).
class CrashRecoveryCoordinator {
  CrashRecoveryCoordinator({
    required this.persistence,
    required this.analytics,
    required this.onRollback,
    this.applyWindow = const Duration(minutes: 5),
    this.threshold = 2,
  });

  final CrashRecoveryPersistence persistence;
  final RemoteConfigAnalytics analytics;
  final Future<void> Function() onRollback;
  final Duration applyWindow;
  final int threshold;

  bool _inWindow(CrashRecoveryState s) {
    final t = s.lastActivateWallMs;
    if (t == null) {
      return false;
    }
    final elapsed = DateTime.now().millisecondsSinceEpoch - t;
    return elapsed >= 0 && elapsed <= applyWindow.inMilliseconds;
  }

  static bool isHighRiskConfig(ConfigBundle bundle) {
    final m = bundle.meta;
    if (m == null) {
      return false;
    }
    if (m['risk_level'] == 'high') {
      return true;
    }
    return m['rollback_on_crash'] == true;
  }

  Future<void> handleAppLaunch() async {
    var s = await persistence.load();
    if (s.launchInProgress) {
      if (s.rollbackArmed && _inWindow(s)) {
        s.suspectCount += 1;
      }
    }
    if (s.suspectCount >= threshold) {
      analytics.crashRollbackTriggered(fromVersion: null);
      await onRollback();
      s = CrashRecoveryState(generation: s.generation + 1);
    }
    s.launchInProgress = true;
    await persistence.save(s);
  }

  Future<void> handleLaunchSuccess() async {
    var s = await persistence.load();
    s
      ..launchInProgress = false
      ..rollbackArmed = false
      ..suspectCount = 0
      ..lastActivateWallMs = null
      ..generation += 1;
    await persistence.save(s);
  }

  Future<void> notifyImmediateActivate(ConfigBundle bundle) async {
    if (!isHighRiskConfig(bundle)) {
      return;
    }
    var s = await persistence.load();
    s
      ..rollbackArmed = true
      ..lastActivateWallMs = DateTime.now().millisecondsSinceEpoch;
    await persistence.save(s);
  }
}
