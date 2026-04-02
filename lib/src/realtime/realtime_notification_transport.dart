import 'config_notification.dart';

abstract class RealtimeNotificationTransport {
  Stream<ConfigNotification> get notifications;

  Future<void> start();

  Future<void> stop();

  Future<void> dispose() => stop();
}
