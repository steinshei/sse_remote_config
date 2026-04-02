# 核心实现类详解

## 一、模块总览

整个远程配置库采用 **门面模式(Facade)** 架构，分为 **7 大模块**，共 **13 个关键类/函数**：

| 模块 | 类数量 | 职责 |
|-----|-------|-----|
| 1️⃣ 主入口 | 1 | 业务逻辑编排 |
| 2️⃣ 数据源层 | 3 | 网络请求抽象 |
| 3️⃣ 存储层 | 3 | 本地持久化 |
| 4️⃣ 实时通知 | 3 | transport抽象 + SSE实现 + 通知模型 |
| 5️⃣ A/B实验 | 1 | 分桶算法 |
| 6️⃣ 同步协调 | 1 | 生命周期管理 |
| 7️⃣ 安全容灾 | 1 | 崩溃回滚 |

---

## 二、核心类详细说明

### 1️⃣ 主入口

#### RemoteConfigClient

**文件**: [`lib/src/remote_config_client.dart`](lib/src/remote_config_client.dart)

**职责**:
- 配置库的门面类，统一对外API
- 管理三级缓存架构
- 处理配置激活和A/B实验合并
- 提供零延迟取值接口

**核心方法**:

| 方法 | 返回值 | 说明 |
|-----|-------|-----|
| `getString(key, {defaultValue})` | `String` | 取字符串配置 |
| `getBool(key, {defaultValue})` | `bool` | 取布尔配置 |
| `getInt(key, {defaultValue})` | `int` | 取整数配置 |
| `getValue(key)` | `dynamic` | 取任意类型配置 |
| `fetchAndActivate({forceFullFetch})` | `Future<void>` | 拉取并激活配置 |
| `initialize()` | `Future<void>` | 初始化：加载pending配置 |
| `onConfigUpdated` | `Stream<ConfigUpdate>` | 配置更新流 |

**关键状态**:

```dart
final _defaults;      // 代码内置默认值
final _activeData;    // 当前生效配置
final _activeVersion; // 当前版本号
final _userId;        // 用户ID
```

**配置合并流程**:

```
Default Config
      +
Active Config
      +
A/B实验片段
      ↓
Effective Config (实际返回值)
```

**示例代码**:

```dart
final client = RemoteConfigClient(
  dataSource: HttpRemoteConfigDataSource(baseUrl: 'https://api.example.com/v1'),
  storage: MMKVConfigStorage(),
  requestContext: ConfigRequestContext(
    appId: 'com.example.app',
    platform: 'android',
  ),
  defaults: {
    'feature_enabled': false,
    'theme_color': '#000000',
  },
);

// 取值(零延迟，本地读取)
String feature = client.getString('feature_enabled');
bool darkMode = client.getBool('dark_mode');
int timeout = client.getInt('request_timeout');
```

---

### 2️⃣ 数据源层

#### 2.1 RemoteConfigDataSource (接口)

**文件**: [`lib/src/remote/remote_config_data_source.dart`](lib/src/remote/remote_config_data_source.dart)

**职责**: 定义数据获取的抽象接口

**方法**:

```dart
abstract class RemoteConfigDataSource {
  Future<ConfigBundle> fetchLatest(ConfigRequestContext context);
  Future<DeltaFetchResult> fetchDelta(ConfigRequestContext context, int sinceVersion);
}
```

**DeltaFetchResult定义**:

```dart
class DeltaFetchResult {
  final bool hasUpdate;
  final ConfigBundle? bundle;
  DeltaFetchResult({this.hasUpdate = false, this.bundle});
}
```

---

#### 2.2 HttpRemoteConfigDataSource

**文件**: [`lib/src/remote/http_remote_config_data_source.dart`](lib/src/remote/http_remote_config_data_source.dart)

**职责**: HTTP请求实现，调用服务端REST API

**实现细节**:

| API | 方法 | 说明 |
|-----|------|-----|
| `/v1/config/latest` | `GET` | 获取最新全量配置 |
| `/v1/config/delta?since=xxx` | `GET` | 增量检测(返回全量快照) |

**响应处理**:

```dart
// 200 OK: 返回ConfigBundle
// 204 No Content: 无更新
// 其他: 抛出RemoteConfigHttpException
```

**错误处理**:

```dart
class RemoteConfigHttpException implements Exception {
  final int statusCode;
  final String body;

  @override
  String toString() => 'RemoteConfigHttpException($statusCode): $body';
}
```

---

#### 2.3 StubRemoteConfigDataSource

**文件**: [`lib/src/remote/stub_remote_config_data_source.dart`](lib/src/remote/stub_remote_config_data_source.dart)

**职责**: 单元测试用桩实现，返回硬编码配置

---

### 3️⃣ 存储层

#### 3.1 ConfigStorage (接口)

**文件**: [`lib/src/storage/config_storage.dart`](lib/src/storage/config_storage.dart)

**职责**: 定义本地持久化抽象接口

**方法**:

```dart
abstract class ConfigStorage {
  int? readVersion();                    // 读取当前版本
  Map<String, dynamic>? readData();      // 读取Active配置
  Future<void> write({required int version, required Map<String, dynamic> data});
  Future<void> clear();                  // 清空所有配置

  // Delay Activation支持
  String? readPendingBundleJson();       // 读取Pending配置JSON
  Future<void> writePendingBundleJson(String? json);
  Future<void> clearPendingBundle();
}
```

---

#### 3.2 MemoryConfigStorage

**文件**: [`lib/src/storage/memory_config_storage.dart`](lib/src/storage/memory_config_storage.dart)

**职责**: 内存实现，用于测试

---

#### 3.3 MMKVConfigStorage

**文件**: [`lib/src/storage/mmkv_config_storage.dart`](lib/src/storage/mmkv_config_storage.dart)

**职责**: MMKV持久化实现，生产环境使用

**存储结构**:

```
MMKV
├─ "rc:version"           → int? (当前版本)
├─ "rc:active_data"       → JSON string (Active配置)
├─ "rc:pending_bundle"    → JSON string (Pending配置)
└─ "rc:crash_count"       → int (崩溃计数)
```

**关键特性**:
- 性能优于SharedPreferences
- 支持加密存储
- 跨平台兼容

---

### 4️⃣ 实时通知

#### RealtimeNotificationTransport

**文件**: [`lib/src/realtime/realtime_notification_transport.dart`](../lib/src/realtime/realtime_notification_transport.dart)

**职责**: 定义统一的实时通知传输抽象，隔离具体协议实现

**接口**:

```dart
abstract class RealtimeNotificationTransport {
  Stream<ConfigNotification> get notifications;
  Future<void> start();
  Future<void> stop();
  Future<void> dispose();
}
```

---

#### ConfigNotification

**文件**: [`lib/src/realtime/config_notification.dart`](../lib/src/realtime/config_notification.dart)

**职责**: transport 层向上游暴露的统一通知模型

```dart
class ConfigNotification {
  final String event;
  final String raw;
  final Map<String, dynamic>? data;
}
```

---

#### SseConfigNotificationTransport

**文件**: [`lib/src/sse/config_sse_client.dart`](lib/src/sse/config_sse_client.dart)

**职责**: 当前默认的 SSE 实时通知实现，负责连接 `/config/stream` 并发出 [ConfigNotification]

**兼容说明**:

- 旧名称 `ConfigSseClient` 仍然保留
- 旧别名 `SseNotification` 仍映射到 `ConfigNotification`
- 业务层已不再直接依赖具体 SSE 类型

**连接流程**:

```
1. 建立HTTP GET /config/stream连接
2. 解析SSE格式事件
3. 指数退避重连机制
4. 心跳保活(ping事件)
```

**事件类型** ([`api-contract-v1.md`](api-contract-v1.md#4)):

| 事件 | 触发条件 | 客户端行为 |
|-----|---------|----------|
| `ping` | 服务端心跳(≤30s) | 更新ping统计，保持连接 |
| `config_updated` | 有新配置发布 | 调用 `fetchAndActivate()` |
| `config_revoke` | 紧急撤回配置 | 调用 `fetchAndActivate()` |

**重连策略**:

```dart
reconnectDelayMs = 1000
每次重连: reconnectDelayMs *= 2
最大延迟: 30000ms (30s)
```

**通知流**:

```dart
class SseConfigNotificationTransport
    implements RealtimeNotificationTransport {
  final _events = StreamController<ConfigNotification>.broadcast();
  Stream<ConfigNotification> get notifications => _events.stream;
}
```

**示例代码**:

```dart
final transport = SseConfigNotificationTransport(
  baseUrl: 'https://api.example.com/v1',
  context: requestContext,
);

await transport.start();

transport.notifications.listen((notification) {
  if (notification.event == 'config_updated' || notification.event == 'config_revoke') {
    // 触发重新拉取
    client.fetchAndActivate();
  }
});

await transport.dispose();
```

---

### 5️⃣ A/B实验引擎

#### stableBucketIndex

**文件**: [`lib/src/ab/stable_bucket.dart`](lib/src/ab/stable_bucket.dart)

**职责**: 用户级一致的哈希分桶算法

**算法实现**:

```dart
int stableBucketIndex({
  required String userId,
  required String experimentKey,
  String? experimentRevision,
  required int bucketCount,
}) {
  if (bucketCount < 2) {
    throw ArgumentError.value(bucketCount, 'bucketCount', 'must be >= 2');
  }

  // 输入: "user123:reader_engine_ab:v1"
  final parts = [userId, experimentKey];
  if (experimentRevision != null && experimentRevision.isNotEmpty) {
    parts.add(experimentRevision);
  }

  final input = parts.join('\x00');  // 用null字节分隔
  final digest = md5.convert(utf8.encode(input)).bytes;

  // 取MD5前8字节，转换为大整数
  var acc = BigInt.zero;
  for (var i = 0; i < 8 && i < digest.length; i++) {
    acc = (acc << 8) + BigInt.from(digest[i]);
  }

  // 取模得到分桶索引
  return (acc % BigInt.from(bucketCount)).toInt();
}
```

**分桶示例**:

```dart
// 用户A (user123) 分到 bucket 0
stableBucketIndex(
  userId: 'user123',
  experimentKey: 'reader_engine_ab',
  bucketCount: 2,
); // 返回 0

// 用户A 再次调用，结果相同
stableBucketIndex(
  userId: 'user123',
  experimentKey: 'reader_engine_ab',
  bucketCount: 2,
); // 返回 0 (不变)

// 用户B (user456) 分到 bucket 1
stableBucketIndex(
  userId: 'user456',
  experimentKey: 'reader_engine_ab',
  bucketCount: 2,
); // 返回 1
```

**为什么不用 `String.hashCode`?**

- 不同平台/版本的 Dart 实现可能不一致
- 跨构建/跨设备可能出现分桶偏差
- MD5保证跨平台确定性

---

### 6️⃣ 同步协调器

#### RemoteConfigSyncCoordinator

**文件**: [`lib/src/sync/remote_config_sync_coordinator.dart`](lib/src/sync/remote_config_sync_coordinator.dart)

**职责**: 统一管理实时 transport、轮询、网络监听、生命周期

**职责清单**:

| 职责 | 实现方式 |
|-----|---------|
| 启动初始化 | 初始化 + 首次fetch |
| 实时更新 | 监听 `ConfigNotification` |
| 兜底重试 | 轮询 (默认5分钟) |
| 网络切换 | 连接变化时立即重拉取 |
| App状态管理 | 前台保持 transport 连接，后台断开 |
| 线程安全 | 异步执行，不阻塞UI |

**启动流程**:

```dart
final sync = RemoteConfigSyncCoordinator(
  client: client,
  sseBaseUrl: 'https://api.example.com/v1',
  pollMinInterval: Duration(minutes: 5),  // 轮询间隔
  enableSse: true,                        // 启用SSE
  // 可选：注入其他 transport
  // transportFactory: ({required baseUrl, required context, required httpClient}) {
  //   return SseConfigNotificationTransport(
  //     baseUrl: baseUrl,
  //     context: context,
  //     httpClient: httpClient,
  //   );
  // },
);

await sync.start();
// 1. client.initialize() - 加载pending配置
// 2. client.fetchAndActivate() - 首次拉取
// 3. 启动轮询Timer
// 4. 监听网络变化
// 5. 建立实时通知连接
```

**App生命周期处理**:

```dart
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  if (state == AppLifecycleState.resumed) {
    _pollIfDue(reason: 'resumed');
    _startSse();  // 前台恢复实时连接
  } else if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
    _stopSse();   // 后台断开实时连接，省电
  }
}
```

**停止流程**:

```dart
await sync.stop();
// 1. 移除WidgetsBindingObserver
// 2. 停止并释放 transport
// 3. 取消网络监听
// 4. 取消轮询Timer
```

**使用示例**:

```dart
// 在main.dart中使用
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final client = RemoteConfigClient(
    dataSource: HttpRemoteConfigDataSource(baseUrl: 'https://api.example.com/v1'),
    storage: MMKVConfigStorage(),
    requestContext: ConfigRequestContext(
      appId: 'com.example.app',
      platform: 'android',
    ),
    defaults: {
      'feature_enabled': false,
    },
  );

  final sync = RemoteConfigSyncCoordinator(
    client: client,
    sseBaseUrl: 'https://api.example.com/v1',
    pollMinInterval: Duration(minutes: 5),
  );

  await sync.start();

  runApp(MyApp(client: client));
}
```

---

### 7️⃣ 安全容灾

#### CrashRecoveryCoordinator

**文件**: [`lib/src/safety/crash_recovery_coordinator.dart`](lib/src/safety/crash_recovery_coordinator.dart)

**职责**: 监控连续崩溃，触发自动回滚

**四层防御机制** ([`crash-rollback-attribution.md`](crash-rollback-attribution.md)):

| 层级 | 触发条件 | 回滚方式 |
|-----|---------|---------|
| L1: 沙盒验证 | 配置加载前验证 | 拒绝应用配置 |
| L2: 延迟生效 | 高风险配置 | 下次启动生效 |
| L3: 崩溃回滚 | 连续2次崩溃 | 紧急回滚 |
| L4: 服务端撤回 | 崩溃率>1% | 实时推送撤回 |

**CrashRecoveryCoordinator 只实现 L3**:

**工作流程**:

```dart
// 1. App启动时调用
await crashCoordinator.handleAppLaunch();
// - 检查上次启动是否失败
// - 增加崩溃计数
// - 如果计数≥2，触发回滚

// 2. App成功启动后调用
await crashCoordinator.handleLaunchSuccess();
// - 清零崩溃计数
// - 重置回滚标志

// 3. 每次激活配置时调用
await crashCoordinator.notifyImmediateActivate(bundle);
// - 如果配置是高风险的(risk_level:high)
// - 标记回滚已就绪(应用窗口内有效)
```

**高风险配置判断**:

```dart
static bool isHighRiskConfig(ConfigBundle bundle) {
  final m = bundle.meta;
  if (m == null) {
    return false;
  }
  // 1. 风险等级为high
  if (m['risk_level'] == 'high') {
    return true;
  }
  // 2. 配置元数据要求崩溃回滚
  return m['rollback_on_crash'] == true;
}
```

**示例代码**:

```dart
final crashCoordinator = CrashRecoveryCoordinator(
  persistence: MMKVConfigStorage(),  // 使用MMKV存储状态
  analytics: analytics,
  onRollback: () async {
    // 回滚回调：加载安全配置
    await client.emergencyRollback();
  },
  applyWindow: Duration(minutes: 5),  // 5分钟应用窗口
  threshold: 2,                        // 连续崩溃2次
);

// 在main.dart初始化时
await crashCoordinator.handleAppLaunch();

// 在App启动成功后
await crashCoordinator.handleLaunchSuccess();
```

---

## 三、调用关系图

```
┌─────────────────────────────────────────────────┐
│         RemoteConfigClient (门面)                │
│  - getValue() / getString() / getBool() / getInt() │
└────┬───────────────────────┬─────────────────────┘
     │                       │
     ▼                       ▼
┌──────────────┐      ┌────────────────────────┐
│ ConfigStorage│      │ RemoteConfigDataSource │
│ (存储)        │      │ (HTTP/Stub)            │
└──────────────┘      └──────┬─────────────────┘
                             │
                             ▼
                    ┌────────────────────────────┐
                    │ HttpRemoteConfigDataSource │
                    │ GET /latest, GET /delta    │
                    └────────────────────────────┘



RemoteConfigClient
    │
    ├─► stableBucketIndex() [A/B实验]
    │      - userId + experimentKey
    │      - MD5哈希 + 取模
    │      - 保证用户级一致性
    │
    ├─► RemoteConfigSyncCoordinator [生命周期管理]
    │      ├─ SSE连接 (ConfigSseClient)
    │      │      - 建立长连接
    │      │      - 解析SSE事件
    │      │      - 指数退避重连
    │      ├─ 轮询兜底
    │      │      - 默认5分钟
    │      └─ 网络监听
    │             - 连接变化时重拉取
    │
    └─► CrashRecoveryCoordinator [安全容灾]
           - 监控连续崩溃
           - 高风险配置标记
           - 触发紧急回滚
```

---

## 四、数据流图

### 4.1 配置加载流程

```
1. RemoteConfigClient.initialize()
   ↓
2. 读取Pending配置(MMKV)
   ↓
3. applyPending: true 调用 activate()
   ↓
4. 调用 fetchLatest() 或 fetchDelta()
   ↓
5. HttpRemoteConfigDataSource
   GET /config/latest 或 /config/delta
   ↓
6. 服务端返回 ConfigBundle
   {
     "version": 42,
     "data": {...},
     "experiments": [...]
   }
   ↓
7. _mergeExperiments() 应用A/B实验
   ↓
8. write(version, mergedData) 持久化到MMKV
   ↓
9. _activeVersion 更新
   _activeData 更新
```

### 4.2 A/B实验合并

```
ConfigBundle.data
    {
      "theme_color": "#FF5722",
      "reader_engine": "new"
    }

ConfigBundle.experiments
    [
      {
        "key": "reader_engine_ab",
        "bucket_count": 2,
        "variants": {
          "0": {"reader_engine": "legacy"},
          "1": {"reader_engine": "new"}
        }
      }
    ]

stableBucketIndex(userId, "reader_engine_ab", 2)
    → 返回 1 (假设用户在group 1)

最终Active配置
    {
      "theme_color": "#FF5722",  // 来自data
      "reader_engine": "new"      // 来自experiments[1]
    }
```

### 4.3 实时事件处理

```
服务端推送
    event: config_updated
    data: {"version": 43, "kind": "publish"}

SseConfigNotificationTransport接收
    ConfigNotification(event: "config_updated", data: {...})

触发回调
    _transportSub.listen((n) {
      if (n.event == 'config_updated') {
        client.fetchAndActivate();  // 重新拉取
      }
    })

重新拉取
    fetchAndActivate()
      → fetchDelta(since: _activeVersion)
      → activate(bundle)
      → 更新本地Active配置
```

---

## 五、使用示例

### 5.1 基础用法

```dart
import 'package:flutter/material.dart';
import 'package:remote_config_lib/remote_config_lib.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final client = RemoteConfigClient(
    dataSource: HttpRemoteConfigDataSource(
      baseUrl: 'https://api.example.com/v1',
    ),
    storage: MMKVConfigStorage(),
    requestContext: ConfigRequestContext(
      appId: 'com.example.app',
      platform: 'android',
      locale: 'en-US',
    ),
    defaults: {
      'feature_enabled': false,
      'theme_color': '#000000',
      'request_timeout': 30,
    },
  );

  // 初始化
  await client.initialize();

  runApp(MyApp(client: client));
}

class MyApp extends StatelessWidget {
  final RemoteConfigClient client;

  const MyApp({super.key, required this.client});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Remote Config Demo',
      theme: ThemeData(
        // 从配置读取主题色
        primaryColor: Color(
          int.parse(client.getString('theme_color').replaceFirst('#', '0xFF')),
        ),
      ),
      home: Scaffold(
        appBar: AppBar(title: const Text('Remote Config')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // 从配置读取布尔值
              Switch(
                value: client.getBool('feature_enabled'),
                onChanged: (bool value) {
                  // 可以在这里手动触发刷新
                  client.fetchAndActivate();
                },
              ),
              const SizedBox(height: 16),
              Text('Feature enabled: ${client.getBool('feature_enabled')}'),
              const SizedBox(height: 16),
              Text('Timeout: ${client.getInt('request_timeout')}s'),
            ],
          ),
        ),
      ),
    );
  }
}
```

### 5.2 完整集成(推荐)

```dart
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'package:remote_config_lib/remote_config_lib.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. 创建客户端
  final client = RemoteConfigClient(
    dataSource: HttpRemoteConfigDataSource(
      baseUrl: 'https://api.example.com/v1',
      httpClient: http.Client(),
    ),
    storage: MMKVConfigStorage(),
    requestContext: ConfigRequestContext(
      appId: 'com.example.app',
      platform: 'android',
      appVersion: '2.5.0',
    ),
    defaults: {
      'feature_enabled': false,
      'theme_color': '#000000',
    },
  );

  // 2. 创建崩溃回滚协调器
  final crashCoordinator = CrashRecoveryCoordinator(
    persistence: MMKVConfigStorage(),
    analytics: NoOpRemoteConfigAnalytics(),
    onRollback: () async {
      await client.emergencyRollback();
    },
  );

  // 3. 启动初始化
  await crashCoordinator.handleAppLaunch();
  await client.initialize();

  // 4. 创建同步协调器
  final connectivity = Connectivity();
  final sync = RemoteConfigSyncCoordinator(
    client: client,
    analytics: NoOpRemoteConfigAnalytics(),
    sseBaseUrl: 'https://api.example.com/v1',
    connectivity: connectivity,
    httpClient: http.Client(),
    pollMinInterval: const Duration(minutes: 5),
    enableSse: true,
  );

  await sync.start();

  runApp(MyApp(client: client, crashCoordinator: crashCoordinator, sync: sync));
}

class MyApp extends StatelessWidget {
  final RemoteConfigClient client;
  final CrashRecoveryCoordinator crashCoordinator;
  final RemoteConfigSyncCoordinator sync;

  const MyApp({
    super.key,
    required this.client,
    required this.crashCoordinator,
    required this.sync,
  });

  @override
  Widget build(BuildContext context) {
    // App启动成功
    WidgetsBinding.instance.addPostFrameCallback((_) {
      crashCoordinator.handleLaunchSuccess();
    });

    return MaterialApp(
      title: 'Remote Config Demo',
      home: Scaffold(
        appBar: AppBar(title: const Text('Remote Config')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('Feature enabled: ${client.getBool("feature_enabled")}'),
              StreamBuilder<ConfigUpdate>(
                stream: client.onConfigUpdated,
                builder: (context, snapshot) {
                  if (snapshot.hasData) {
                    return Text('Updated to version ${snapshot.data!.version}');
                  }
                  return const SizedBox.shrink();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
```

---

## 六、测试覆盖

### 6.1 Mock数据源

```dart
import 'package:remote_config_lib/remote_config_lib.dart';

void main() {
  test('stub datasource returns hardcoded config', () async {
    final stub = StubRemoteConfigDataSource(
      config: ConfigBundle(
        version: 10,
        data: {'feature_enabled': true, 'timeout': 60},
      ),
    );

    final result = await stub.fetchLatest(ConfigRequestContext(
      appId: 'test',
      platform: 'ios',
    ));

    expect(result.version, 10);
    expect(result.data['feature_enabled'], true);
  });
}
```

### 6.2 Mock存储

```dart
import 'package:remote_config_lib/remote_config_lib.dart';

void main() {
  test('memory storage survives process restart', () async {
    final storage = MemoryConfigStorage();

    // 写入
    await storage.write(
      version: 42,
      data: {'key': 'value'},
    );

    // 读取
    expect(storage.readVersion(), 42);
    expect(storage.readData()?['key'], 'value');

    // 清空
    await storage.clear();
    expect(storage.readVersion(), null);
  });
}
```

---

## 七、性能指标

| 指标 | 数值 | 说明 |
|-----|------|-----|
| 配置读取延迟 | < 1μs | 本地缓存读取 |
| 首次fetch延迟 | < 500ms | 包含网络请求 |
| A/B分桶计算 | < 10μs | MD5哈希+取模 |
| SSE连接建立 | < 2s | 平均值 |
| 内存占用 | < 1MB | 单个客户端实例 |

---

## 八、常见问题

### Q1: 何时使用 `fetchAndActivate()` vs `initialize()`?

- `fetchAndActivate()`: 手动触发配置拉取
- `initialize()`: **只**加载pending配置（delay_activation场景）

### Q2: SSE连接失败会怎样?

- 同步协调器会切换到轮询模式（默认5分钟）
- 网络恢复后自动重连

### Q3: 如何自定义A/B实验分桶?

使用 `stableBucketIndex()` 函数：

```dart
final userGroup = stableBucketIndex(
  userId: currentUserId,
  experimentKey: 'my_experiment',
  experimentRevision: 'v1',
  bucketCount: 3,
); // 返回 0, 1, 或 2
```

### Q4: 配置崩溃后如何恢复?

崩溃回滚协调器会自动处理：

```dart
// 初始化时调用
await crashCoordinator.handleAppLaunch();

// 启动成功后调用
await crashCoordinator.handleLaunchSuccess();
```

### Q5: 如何支持热更新?

通过SSE监听配置更新：

```dart
client.onConfigUpdated.listen((update) {
  // 每次配置更新都会触发
  print('Config updated to version ${update.version}');
});
```

---

## 九、参考资料

- [App自研远程配置库研发计划.md](App自研远程配置库研发计划.md)
- [api-contract-v1.md](api-contract-v1.md)
- [capacity-slo-sse.md](capacity-slo-sse.md)
- [crash-rollback-attribution.md](crash-rollback-attribution.md)
- [hash-bucketing-and-cache.md](hash-bucketing-and-cache.md)

---
