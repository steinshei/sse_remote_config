# remote_config_lib

自研远程配置 Flutter 客户端 SDK 骨架，当前包含：

- REST 拉取：`/config/latest`、`/config/delta`
- 本地持久化：MMKV，Web 下自动退化为内存存储
- A/B 实验：基于 MD5 的稳定分桶与实验片段合并
- 实时通知：当前为自定义 SSE 通知协议
- 同步协调：实时通知 + 最小间隔轮询 + 生命周期管理

## 当前传输层定位

本库当前不是 MCP 客户端，也不使用 JSON-RPC。

实时链路仍然基于远程配置自己的业务协议：

- 服务端入口：`GET /v1/config/stream`
- 服务端事件：`ping`、`config_updated`、`config_revoke`
- 客户端行为：收到通知后再走 `latest` / `delta`

从代码结构上，实时链路已经从具体 SSE 实现中解耦：

- 通用抽象：[RealtimeNotificationTransport](lib/src/realtime/realtime_notification_transport.dart)
- 通用事件模型：[ConfigNotification](lib/src/realtime/config_notification.dart)
- 当前默认实现：[SseConfigNotificationTransport](lib/src/sse/config_sse_client.dart)
- 兼容别名：[ConfigSseClient](lib/src/sse/config_sse_client.dart)

这意味着后续如果要接入 MCP transport，可以新增一套 transport 实现，而不必先重写 `RemoteConfigClient` 或 `RemoteConfigSyncCoordinator`。

## 文档索引

- 设计与实现：[docs/core-implementation.md](docs/core-implementation.md)
- 客户端/服务端契约：[docs/api-contract-v1.md](docs/api-contract-v1.md)
- MCP transport 接入预案：[docs/mcp-transport-adoption.md](docs/mcp-transport-adoption.md)
- 崩溃回滚归因：[docs/crash-rollback-attribution.md](docs/crash-rollback-attribution.md)
- SSE 容量与 SLO：[docs/capacity-slo-sse.md](docs/capacity-slo-sse.md)

## 快速开始

在宿主 `pubspec.yaml` 中添加 path 或 git 依赖后：

```dart
await MMKV.initialize();

final client = RemoteConfigClient(
  dataSource: HttpRemoteConfigDataSource(baseUrl: 'https://api.example.com/v1'),
  storage: MmkvConfigStorage(),
  requestContext: const ConfigRequestContext(
    appId: 'my_app',
    platform: 'android',
    appVersion: '1.0.0',
  ),
  defaults: {'flag_x': false},
  userId: 'signed-in-user-id',
);

await client.fetchAndActivate();
final enabled = client.getBool('flag_x');
```

## 实时同步

如果需要实时通知 + 兜底轮询：

```dart
final sync = RemoteConfigSyncCoordinator(
  client: client,
  analytics: const NoOpRemoteConfigAnalytics(),
  sseBaseUrl: 'https://api.example.com/v1',
);

await sync.start();
```

`RemoteConfigSyncCoordinator` 默认通过 `RealtimeNotificationTransport` 工厂创建 `SseConfigNotificationTransport`。后续接入其他实时协议时，可通过 `transportFactory` 注入。

## Web / Chrome

`mmkv` 使用 `dart:ffi`，不能在浏览器里加载。本库对 `MmkvConfigStorage` 做了条件导出：在 `dart.library.html` 下自动使用内存兜底，刷新页面会丢失 active 配置。Example 通过条件 import 跳过 `MMKV.initialize()`。

```bash
cd example
flutter run -d chrome
```

原生平台仍使用真实 MMKV。

## Mock API + SSE 联调

仓库内 `tool/mock_config_server.dart` 提供 `latest` / `delta` / `stream` 接口，`stream` 会周期性推送 `config_updated`。

```bash
flutter test

# 终端 1
dart run tool/mock_config_server.dart

# 终端 2
cd example
flutter run --dart-define=CONFIG_API_BASE=http://127.0.0.1:8787/v1

# Android 模拟器
flutter run -d android --dart-define=CONFIG_API_BASE=http://10.0.2.2:8787/v1
```

Android 模拟器必须使用 `10.0.2.2`，否则到本机 mock server 的 SSE 连接会持续断开重连。

不设 `CONFIG_API_BASE` 时，Example 仍使用 Stub 数据源，不连网。

## 验证状态

当前仓库已验证：

- `dart analyze`
- `flutter test`

其中包内测试现为 7 个。
