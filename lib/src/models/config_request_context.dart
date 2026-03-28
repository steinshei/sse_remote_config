/// Query parameters from [docs/api-contract-v1.md] §1.1.
class ConfigRequestContext {
  const ConfigRequestContext({
    required this.appId,
    required this.platform,
    this.appVersion,
    this.locale,
    this.region,
    this.headers = const {},
  });

  final String appId;

  /// `ios` | `android`
  final String platform;
  final String? appVersion;
  final String? locale;
  final String? region;

  /// Extra HTTP headers (e.g. `Authorization`).
  final Map<String, String> headers;

  Map<String, String> toQueryParameters() {
    final q = <String, String>{
      'app_id': appId,
      'platform': platform,
    };
    final v = appVersion;
    if (v != null && v.isNotEmpty) {
      q['app_version'] = v;
    }
    final l = locale;
    if (l != null && l.isNotEmpty) {
      q['locale'] = l;
    }
    final r = region;
    if (r != null && r.isNotEmpty) {
      q['region'] = r;
    }
    return q;
  }
}
