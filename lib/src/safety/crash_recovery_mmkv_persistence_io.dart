import 'package:mmkv/mmkv.dart';

import 'crash_recovery_persistence.dart';
import 'crash_recovery_state.dart';

/// Native MMKV persistence for crash recovery (v1 JSON blob).
class CrashRecoveryMmkvPersistence implements CrashRecoveryPersistence {
  CrashRecoveryMmkvPersistence({MMKV? mmkv}) : _mmkv = mmkv ?? MMKV.defaultMMKV();

  final MMKV _mmkv;
  static const _key = 'rc.crash.state.v1';

  @override
  Future<CrashRecoveryState> load() async {
    final raw = _mmkv.decodeString(_key);
    return CrashRecoveryState.decode(raw);
  }

  @override
  Future<void> save(CrashRecoveryState state) async {
    _mmkv.encodeString(_key, CrashRecoveryState.encode(state));
  }
}
