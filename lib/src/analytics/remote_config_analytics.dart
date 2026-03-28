/// Client telemetry aligned with [docs/capacity-slo-sse.md] §3.2 (SDK 埋点).
abstract class RemoteConfigAnalytics {
  void fetchStarted({int? sinceVersion});

  void fetchCompleted({
    required bool success,
    int? httpStatus,
    int? durationMs,
    int? sinceVersion,
  });

  void sseConnectAttempt();

  void sseConnectResult({required bool success, int? durationMs});

  void sseCommentOrPing();

  void sseEventReceived({required String event});

  void sseDisconnected({String? reason});

  /// Local active config was updated (not `next_launch` staging only).
  void activationApplied({required int version});

  /// Payload stored for next process start — [docs/api-contract-v1.md] `_meta.delay_activation`.
  void delayActivationScheduled({required int version});

  void sandboxRejected({required int version});

  void crashRollbackTriggered({int? fromVersion});

  void pollTick({required String reason});
}

/// Default no-op for apps that do not wire analytics yet.
class NoOpRemoteConfigAnalytics implements RemoteConfigAnalytics {
  const NoOpRemoteConfigAnalytics();

  @override
  void activationApplied({required int version}) {}

  @override
  void crashRollbackTriggered({int? fromVersion}) {}

  @override
  void delayActivationScheduled({required int version}) {}

  @override
  void fetchCompleted({
    required bool success,
    int? httpStatus,
    int? durationMs,
    int? sinceVersion,
  }) {}

  @override
  void fetchStarted({int? sinceVersion}) {}

  @override
  void pollTick({required String reason}) {}

  @override
  void sandboxRejected({required int version}) {}

  @override
  void sseCommentOrPing() {}

  @override
  void sseConnectAttempt() {}

  @override
  void sseConnectResult({required bool success, int? durationMs}) {}

  @override
  void sseDisconnected({String? reason}) {}

  @override
  void sseEventReceived({required String event}) {}
}
