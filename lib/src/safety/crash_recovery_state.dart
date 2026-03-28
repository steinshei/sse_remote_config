import 'dart:convert';

/// Persisted snapshot for [CrashRecoveryCoordinator].
class CrashRecoveryState {
  CrashRecoveryState({
    this.launchInProgress = false,
    this.rollbackArmed = false,
    this.suspectCount = 0,
    this.generation = 0,
    this.lastActivateWallMs,
  });

  bool launchInProgress;
  bool rollbackArmed;
  int suspectCount;
  int generation;
  int? lastActivateWallMs;

  CrashRecoveryState copy() {
    return CrashRecoveryState(
      launchInProgress: launchInProgress,
      rollbackArmed: rollbackArmed,
      suspectCount: suspectCount,
      generation: generation,
      lastActivateWallMs: lastActivateWallMs,
    );
  }

  Map<String, dynamic> toJson() => {
        'launchInProgress': launchInProgress,
        'rollbackArmed': rollbackArmed,
        'suspectCount': suspectCount,
        'generation': generation,
        'lastActivateWallMs': lastActivateWallMs,
      };

  factory CrashRecoveryState.fromJson(Map<String, dynamic> j) {
    return CrashRecoveryState(
      launchInProgress: j['launchInProgress'] == true,
      rollbackArmed: j['rollbackArmed'] == true,
      suspectCount: (j['suspectCount'] as num?)?.toInt() ?? 0,
      generation: (j['generation'] as num?)?.toInt() ?? 0,
      lastActivateWallMs: (j['lastActivateWallMs'] as num?)?.toInt(),
    );
  }

  static String encode(CrashRecoveryState s) => jsonEncode(s.toJson());

  static CrashRecoveryState decode(String? raw) {
    if (raw == null || raw.isEmpty) {
      return CrashRecoveryState();
    }
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return CrashRecoveryState.fromJson(m);
  }
}
