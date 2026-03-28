import 'dart:convert';

import 'config_storage.dart';

/// **Web / WASM:** MMKV (FFI) is unavailable. This class keeps the same name but
/// stores active config **in memory only** (clears on full page reload).
///
/// For durable web persistence later, plug a [ConfigStorage] backed by
/// `shared_preferences` or IndexedDB.
class MmkvConfigStorage implements ConfigStorage {
  MmkvConfigStorage({this.mmapId = 'remote_config'});

  /// Ignored on web; kept for API parity with the native implementation.
  final String mmapId;

  int? _version;
  String? _dataJson;
  String? _pendingJson;

  @override
  Future<void> clear() async {
    _version = null;
    _dataJson = null;
    _pendingJson = null;
  }

  @override
  Future<void> clearPendingBundle() async {
    _pendingJson = null;
  }

  @override
  String? readPendingBundleJson() => _pendingJson;

  @override
  Future<void> writePendingBundleJson(String? json) async {
    _pendingJson = (json == null || json.isEmpty) ? null : json;
  }

  @override
  Map<String, dynamic>? readData() {
    final raw = _dataJson;
    if (raw == null || raw.isEmpty) {
      return null;
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      return null;
    }
    return Map<String, dynamic>.from(
      decoded.map((k, dynamic v) => MapEntry(k.toString(), v)),
    );
  }

  @override
  int? readVersion() => _version;

  @override
  Future<void> write({required int version, required Map<String, dynamic> data}) async {
    _version = version;
    _dataJson = jsonEncode(data);
  }
}
