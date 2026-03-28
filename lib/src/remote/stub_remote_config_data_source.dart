import '../models/config_bundle.dart';
import '../models/config_request_context.dart';
import 'remote_config_data_source.dart';

/// Fixed payload for integration tests / example app without a backend.
class StubRemoteConfigDataSource implements RemoteConfigDataSource {
  StubRemoteConfigDataSource(this.bundle, {this.deltaReturnsNone = false});

  ConfigBundle bundle;
  bool deltaReturnsNone;

  @override
  Future<ConfigBundle> fetchLatest(ConfigRequestContext context) async => bundle;

  @override
  Future<DeltaFetchResult> fetchDelta(ConfigRequestContext context, int sinceVersion) async {
    if (deltaReturnsNone || sinceVersion >= bundle.version) {
      return const DeltaFetchResult();
    }
    return DeltaFetchResult(bundle: bundle);
  }
}
