import 'config_storage.dart';

/// In-memory storage for tests and demos without MMKV.
class MemoryConfigStorage implements ConfigStorage {
  int? _version;
  Map<String, dynamic>? _data;
  String? _pendingJson;

  @override
  Future<void> clear() async {
    _version = null;
    _data = null;
    _pendingJson = null;
  }

  @override
  Future<void> clearPendingBundle() async {
    _pendingJson = null;
  }

  @override
  Map<String, dynamic>? readData() => _data == null ? null : Map<String, dynamic>.from(_data!);

  @override
  String? readPendingBundleJson() => _pendingJson;

  @override
  int? readVersion() => _version;

  @override
  Future<void> write({required int version, required Map<String, dynamic> data}) async {
    _version = version;
    _data = Map<String, dynamic>.from(data);
  }

  @override
  Future<void> writePendingBundleJson(String? json) async {
    _pendingJson = json;
  }
}
