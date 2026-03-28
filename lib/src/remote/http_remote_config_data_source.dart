import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/config_bundle.dart';
import '../models/config_request_context.dart';
import 'remote_config_data_source.dart';

class RemoteConfigHttpException implements Exception {
  RemoteConfigHttpException(this.statusCode, this.body);

  final int statusCode;
  final String body;

  @override
  String toString() => 'RemoteConfigHttpException($statusCode): $body';
}

/// REST client for `/v1/config/latest` and `/v1/config/delta`.
///
/// [baseUrl] should include the `/v1` prefix, e.g. `https://api.example.com/v1`.
class HttpRemoteConfigDataSource implements RemoteConfigDataSource {
  HttpRemoteConfigDataSource({
    required String baseUrl,
    http.Client? httpClient,
  })  : _base = _normalizeBase(baseUrl),
        _client = httpClient ?? http.Client();

  final Uri _base;
  final http.Client _client;

  static Uri _normalizeBase(String baseUrl) {
    final trimmed = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    return Uri.parse(trimmed);
  }

  Uri _buildUri(String path, ConfigRequestContext context, [Map<String, String>? extra]) {
    final qp = Map<String, String>.from(context.toQueryParameters());
    if (extra != null) {
      qp.addAll(extra);
    }
    final relative = path.startsWith('/') ? path.substring(1) : path;
    return _base.replace(path: '${_base.path}/$relative', queryParameters: qp);
  }

  Map<String, String> _headers(ConfigRequestContext context) => {
        'Accept': 'application/json',
        ...context.headers,
      };

  @override
  Future<ConfigBundle> fetchLatest(ConfigRequestContext context) async {
    final uri = _buildUri('config/latest', context);
    final res = await _client.get(uri, headers: _headers(context));
    if (res.statusCode == 200) {
      final map = jsonDecode(res.body) as Map<String, dynamic>;
      return ConfigBundle.fromJson(map);
    }
    throw RemoteConfigHttpException(res.statusCode, res.body);
  }

  @override
  Future<DeltaFetchResult> fetchDelta(ConfigRequestContext context, int sinceVersion) async {
    final uri = _buildUri('config/delta', context, {'since': '$sinceVersion'});
    final res = await _client.get(uri, headers: _headers(context));
    if (res.statusCode == 204) {
      return const DeltaFetchResult();
    }
    if (res.statusCode == 200) {
      final map = jsonDecode(res.body) as Map<String, dynamic>;
      return DeltaFetchResult(bundle: ConfigBundle.fromJson(map));
    }
    throw RemoteConfigHttpException(res.statusCode, res.body);
  }
}
