/// Persists the **active** merged config (after experiments / validation).
abstract class ConfigStorage {
  int? readVersion();

  Map<String, dynamic>? readData();

  Future<void> write({required int version, required Map<String, dynamic> data});

  Future<void> clear();

  /// Full [ConfigBundle] JSON for `delay_activation: next_launch` (see client).
  String? readPendingBundleJson();

  Future<void> writePendingBundleJson(String? json);

  Future<void> clearPendingBundle();
}
