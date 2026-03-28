import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_config_example/main.dart';
import 'package:remote_config_lib/remote_config_lib.dart';

void main() {
  testWidgets('ExampleApp shows title from defaults', (WidgetTester tester) async {
    final bundle = ConfigBundle.fromJson({
      'version': 99,
      'data': {'theme_color': '#1976D2'},
    });
    final client = RemoteConfigClient(
      dataSource: StubRemoteConfigDataSource(bundle),
      storage: MemoryConfigStorage(),
      requestContext: const ConfigRequestContext(appId: 't', platform: 'android'),
      defaults: {'welcome_title': 'Remote Config'},
    );
    await client.initialize();
    await client.fetchAndActivate(forceFullFetch: true);

    await tester.pumpWidget(ExampleApp(client: client));
    await tester.pumpAndSettle();

    expect(find.text('Remote Config'), findsOneWidget);
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
