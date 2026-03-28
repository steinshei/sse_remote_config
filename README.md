# remote_config_lib

自研远程配置 **Flutter 客户端 SDK 骨架**：REST（latest / delta）、MMKV 持久化、MD5 稳定分桶合并实验桶、[ConfigSseClient](lib/src/sse/config_sse_client.dart) SSE 通知骨架。

设计文档见仓库根目录 [docs/api-contract-v1.md](docs/api-contract-v1.md)、[docs/hash-bucketing-and-cache.md](docs/hash-bucketing-and-cache.md)、[docs/crash-rollback-attribution.md](docs/crash-rollback-attribution.md)。

## 快速开始

在宿主 `pubspec.yaml` 中添加 path / git 依赖后：

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

## Web / Chrome

`mmkv` 使用 `dart:ffi`，**不能**在浏览器里加载。本库对 `MmkvConfigStorage` 做了条件导出：在 `dart.library.html` 下自动使用**内存兜底**（刷新页面会丢 active 配置）。Example 通过条件 import 跳过 `MMKV.initialize()`。

```bash
cd example
flutter run -d chrome
```

原生（iOS / Android / 桌面）仍使用真实 MMKV。

## Mock API + SSE（联调）

仓库内 [tool/mock_config_server.dart](tool/mock_config_server.dart) 提供 `latest` / `delta` / `stream`（含周期性 `config_updated`）。

```bash
# 终端 1
dart run tool/mock_config_server.dart

# 终端 2 — iOS/Android/Web 均可试 SSE
cd example
flutter run --dart-define=CONFIG_API_BASE=http://127.0.0.1:8787/v1
```

不设 `CONFIG_API_BASE` 时 Example 仍使用 **Stub** 数据源（不连网）。

## 进阶 API

- [RemoteConfigSyncCoordinator](lib/src/sync/remote_config_sync_coordinator.dart)：SSE + 最小间隔轮询 + 前后台暂停/恢复 SSE。
- [CrashRecoveryCoordinator](lib/src/safety/crash_recovery_coordinator.dart) + [RemoteConfigClient.onImmediateActivationCommitted](lib/src/remote_config_client.dart)：高风险配置观察与回滚钩子（见 [docs/crash-rollback-attribution.md](docs/crash-rollback-attribution.md)）。
- [RemoteConfigAnalytics](lib/src/analytics/remote_config_analytics.dart)：埋点抽象（默认 `NoOpRemoteConfigAnalytics`）。

Fix README typo - NoOp is in remote_config_analytics.dart

## Example

```bash
cd example
flutter run
```

## 测试

```bash
flutter test
```
