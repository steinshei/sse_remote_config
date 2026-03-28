import 'crash_recovery_state.dart';

abstract class CrashRecoveryPersistence {
  Future<CrashRecoveryState> load();

  Future<void> save(CrashRecoveryState state);
}

/// In-memory persistence (tests / Example default).
class MemoryCrashRecoveryPersistence implements CrashRecoveryPersistence {
  CrashRecoveryState _state = CrashRecoveryState();

  @override
  Future<CrashRecoveryState> load() async => _state.copy();

  @override
  Future<void> save(CrashRecoveryState state) async {
    _state = state.copy();
  }
}
