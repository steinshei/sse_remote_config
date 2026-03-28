import '../models/config_bundle.dart';
import '../models/config_request_context.dart';

/// Result of `GET /config/delta` — see [docs/api-contract-v1.md] §3.
class DeltaFetchResult {
  const DeltaFetchResult({this.bundle});

  final ConfigBundle? bundle;

  bool get hasUpdate => bundle != null;
}

/// Network abstraction — keeps URLs out of [RemoteConfigClient].
abstract class RemoteConfigDataSource {
  Future<ConfigBundle> fetchLatest(ConfigRequestContext context);

  Future<DeltaFetchResult> fetchDelta(ConfigRequestContext context, int sinceVersion);
}
