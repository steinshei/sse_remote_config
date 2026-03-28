import 'dart:convert';

import 'package:mmkv/mmkv.dart';

import 'config_storage.dart';

/// MMKV-backed active config. Call [MMKV.initialize] before first use (native only).
class MmkvConfigStorage implements ConfigStorage {
  MmkvConfigStorage({MMKV? mmkv, this.mmapId = 'remote_config'})
      : _mmkv = mmkv ?? MMKV(mmapId);

  /// Passes through to [MMKV] when [mmkv] is null.
  final String mmapId;
  final MMKV _mmkv;

  static const _kVersion = 'rc.active.version';
  static const _kData = 'rc.active.data';
  static const _kPending = 'rc.pending.bundle';

  @override
  Future<void> clear() async {
    _mmkv.removeValue(_kVersion);
    _mmkv.removeValue(_kData);
    _mmkv.removeValue(_kPending);
  }

  @override
  Future<void> clearPendingBundle() async {
    _mmkv.removeValue(_kPending);
  }

  @override
  String? readPendingBundleJson() => _mmkv.decodeString(_kPending);

  @override
  Future<void> writePendingBundleJson(String? json) async {
    if (json == null || json.isEmpty) {
      _mmkv.removeValue(_kPending);
    } else {
      _mmkv.encodeString(_kPending, json);
    }
  }

  @override
  Map<String, dynamic>? readData() {
    final raw = _mmkv.decodeString(_kData);
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
  int? readVersion() {
    if (!_mmkv.containsKey(_kVersion)) {
      return null;
    }
    return _mmkv.decodeInt(_kVersion);
  }

  @override
  Future<void> write({required int version, required Map<String, dynamic> data}) async {
    _mmkv.encodeInt(_kVersion, version);
    _mmkv.encodeString(_kData, jsonEncode(data));
  }
}
