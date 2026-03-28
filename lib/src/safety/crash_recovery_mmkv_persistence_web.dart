import 'crash_recovery_persistence.dart';
import 'crash_recovery_state.dart';

/// Web / session: state is not durable across reloads (same as MMKV web shim intent).
class CrashRecoveryMmkvPersistence implements CrashRecoveryPersistence {
  CrashRecoveryState _state = CrashRecoveryState();

  @override
  Future<CrashRecoveryState> load() async => _state.copy();

  @override
  Future<void> save(CrashRecoveryState state) async {
    _state = state.copy();
  }
}
