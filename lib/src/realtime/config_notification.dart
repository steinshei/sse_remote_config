class ConfigNotification {
  ConfigNotification({required this.event, required this.raw, this.data});

  final String event;
  final String raw;
  final Map<String, dynamic>? data;
}

typedef SseNotification = ConfigNotification;
