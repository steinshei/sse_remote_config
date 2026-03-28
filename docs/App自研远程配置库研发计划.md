# App自研远程配置库研发计划

**文档版本**: v1.0   
**优先级**: P0（基础设施）

---

## 一、项目背景与目标

### 1.1 为什么自研？
| 痛点 | 说明 |
|------|------|
| **数据合规** | 出海项目需规避GDPR/数据主权问题，Firebase数据出境风险 |
| **定制化需求** | App需按阅读标签、付费分层等复杂维度做A/B测试 |
| **成本可控** | 长期看自研成本低于第三方，且无用量限制 |
| **技术自主** | 不受第三方服务稳定性影响，故障可控 |

### 1.2 核心目标
- 实现配置实时下发（SSE）+ 离线兜底（拉模式）
- 支持A/B测试分桶（用户级一致性）
- 支持灰度发布、功能开关、个性化运营
- **零故障**：配置错误不导致App崩溃或变砖

---

## 二、技术架构

### 2.1 整体架构

```

┌─────────────────────────────────────────┐
│              客户端（Flutter）            │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  │
│  │ SSE长连接│  │ 配置管理  │  │ A/B引擎  │ │
│  │(实时通知)│   │(三级缓存)│  │ (哈希分桶)│ │
│  └────┬────┘  └─────┬────┘ └────┬────┘  │
│       └─────────────┴─────────────┘     │
│               ↓ 安全验证层                │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  │
│  │ 沙盒验证 │  │ 崩溃回滚  │  │ 延迟生效 │  │
│  └─────────┘  └─────────┘  └─────────┘  │
└─────────────────────────────────────────┘
│
▼ HTTPS/SSE
┌─────────────────────────────────────────┐
│              服务端（Node.js）            │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  │
│  │ Config  │  │  Rule   │  │  Admin  │  │
│  │  API    │  │ Engine  │  │ Dashboard│ │
│  │(REST+SSE)│ │(条件匹配) │ │(运营后台) │  │
│  └────┬────┘  └────┬────┘  └────┬────┘  │
│       └─────────────┴─────────────┘     │
│  ┌──────────┐  ┌─────────┐  ┌─────────┐ │
│  │PostgreSQL│  │   Redis │  │ClickHouse││
│  │(配置存储) │  │(Pub/Sub)│  │(数据上报) │ │
│  └──────────┘  └─────────┘  └─────────┘ │
└─────────────────────────────────────────┘
```


### 2.2 关键技术选型

| 组件 | 选型 | 理由 |
|------|------|------|
| 传输协议 | **SSE (Server-Sent Events)** | 基于HTTP，穿透性好，自动重连，比WebSocket简单 |
| 本地存储 | **MMKV** (腾讯开源) | 性能优于SharedPreferences，支持加密，跨平台 |
| 服务端 | **Node.js + Express** | 快速开发，SSE支持完善，团队技术栈匹配 |
| 数据库 | **PostgreSQL** | 支持JSONB存储配置，版本控制方便 |
| 实时推送 | **Redis Pub/Sub** | 多节点SSE广播，解耦配置发布与推送 |

---

## 三、核心功能模块

### 3.1 模块一：配置管理（基础）

#### 三级缓存架构（同Firebase）
| 层级 | 存储位置 | 作用 | 优先级 |
|------|---------|------|--------|
| Default Config | 代码内置 | 首次启动默认值 | 最低 |
| Active Config | MMKV持久化 | 当前生效配置 | 中 |
| Fetched Config | 内存 | 刚获取未激活 | 等待激活 |

#### 核心API设计
```dart
// 取值（零延迟，本地读取）
String getString(String key, {String defaultValue = ''});
bool getBool(String key, {bool defaultValue = false});
int getInt(String key, {int defaultValue = 0});

// 拉取与激活
Future<void> fetchAndActivate();      // 手动拉取
Stream<ConfigUpdate> get onConfigUpdated; // 实时监听
```

### 3.2 模块二：实时推送（SSE）

⚠️ 【重点】线程安全

- SSE连接必须在子线程/Isolate执行
- 回调通过Handler/Looper切回主线程更新UI
- 禁止在主线程直接调用同步SSE请求

#### 实现要点

```dart
// ✅ 正确：异步执行，不阻塞UI

_httpClient.send(request).then((response) {
  response.stream
    .transform(utf8.decoder)
    .transform(const LineSplitter())
    .listen(_handleLine);
});

// 错误处理：指数退避重连
void _scheduleReconnect() {
  _reconnectTimer?.cancel();
  _delay = min(_delay * 2, 30000); // 最大30秒
  _reconnectTimer = Timer(Duration(milliseconds: _delay), _connect);
}
```

⚠️ 【重点】生命周期管理

| 场景    | 行为             | 原因              |
| ----- | -------------- | --------------- |
| App前台 | 保持SSE连接        | 实时接收配置          |
| App后台 | 断开SSE（可选）      | 省电，避免Doze模式被杀   |
| App恢复 | 立即重连 + 拉取delta | 补偿离线期间错过的配置     |
| 网络切换  | 自动重连           | WiFi↔4G切换时TCP中断 |


### 3.3 模块三：A/B测试引擎
分桶算法（用户级一致性）

```dart
/// 稳定的哈希分桶，保证同一用户始终在同一组
String getBucket(String userId, String experimentKey, int bucketCount) {
  final hash = md5('$userId:$experimentKey').hashCode.abs();
  return 'group_${hash % bucketCount}';
}
```

小说App特殊分桶维度

| 维度   | 字段示例                          | 用途         |
| ---- | ----------------------------- | ---------- |
| 阅读标签 | `favorite_tags: ["玄幻", "爽文"]` | 玄幻读者看短章节实验 |
| 付费分层 | `ltv_tier: "high" / "low"`    | 高价值用户免广告实验 |
| 阅读速度 | `avg_speed: 1200` 字/分钟        | 快速读者看密集爽点  |
| 地域语言 | `region: "ID", lang: "id"`    | 印尼区定价实验    |

⚠️ 【重点】分桶一致性

- 用户ID + 实验Key 哈希后取模，确保同一用户每次打开App分组不变
- 分组结果本地缓存，避免服务端计算压力

### 3.4 模块四：安全与容灾（⚠️ 核心重点）

**四层防御机制**

```
| 层级 | 机制     | 触发条件         | 回滚时间     |
| --- | -------- | -------------- | ----------- |
| L1 | 沙盒验证   | 新配置生效前       | 毫秒级     |
| L2 | 延迟生效   | 高风险配置（阅读器引擎） | 下次/下下次启动 |
| L3 | 崩溃自动回滚 | 连续崩溃2次      | 下次启动     |
| L4 | 服务端撤回  | 崩溃率>1%         | 实时推送撤回指令 |
```

⚠️ 【重点】崩溃自动回滚实现

```dart
class CrashRecoveryManager {
  static const int _crashThreshold = 2;
  
  Future<void> onAppLaunch() async {
    final crashCount = _storage.getInt('crash_count') ?? 0;
    
    if (crashCount >= _crashThreshold) {
      // 连续崩溃，强制回滚到安全配置
      await _rollbackToSafeConfig();
      _reportToServer('config_crash_rollback');
    }
    
    // 启动计数+1（成功启动后会清零）
    await _storage.setInt('crash_count', crashCount + 1);
  }
  
  Future<void> onLaunchSuccess() async {
    // 正常启动，清零计数
    await _storage.setInt('crash_count', 0);
  }
  
  Future<void> _rollbackToSafeConfig() async {
    final safeConfig = {
      'reader_engine': 'legacy',  // 强制旧版
      'use_safe_mode': true,
      'theme': 'default',
    };
    await _saveConfig(safeConfig);
  }
}
```

⚠️ 【重点】沙盒验证（高风险配置）

```dart
Future<bool> _validateInSandbox(Map<String, dynamic> config) async {
  try {
    // 1. 阅读器引擎能否初始化（不渲染UI）
    final sandbox = ReaderSandbox();
    await sandbox.initEngine(config['reader_engine']);
    
    // 2. 模拟加载章节数据
    await sandbox.loadDummyChapter();
    
    // 3. 检查资源完整性
    if (config['reader_engine'] == 'new' && 
        !await _checkNewReaderAssets()) {
      return false;
    }
    
    return true;
  } catch (e) {
    return false; // 验证失败，拒绝应用配置
  }
}
```

## 四、服务端API设计
### 4.1 核心接口

| 接口                              | 方法   | 说明                |
| ------------------------------- | ---- | ----------------- |
| `/config/latest`                | GET  | 全量拉取最新配置          |
| `/config/delta?since={version}` | GET  | 增量拉取，用于断线补偿       |
| `/config/stream`                | SSE  | 实时推送通知            |
| `/config/ack`                   | POST | 可选，ACK确认（如需要精确统计） |
| `/admin/config`                 | POST | 运营后台发布配置          |
| `/admin/rollback`               | POST | 紧急撤回配置            |

### 4.2 配置数据结构

```dart
{
  "version": 42,
  "data": {
    "reader_engine": "new",
    "theme_color": "#FF5722",
    "chapter_price": 100
  },
  "conditions": {
    "region": "ID",
    "app_version": ">=2.5.0",
    "user_segment": "paying_users",
    "rollout_percentage": 10
  },
  "_meta": {
    "risk_level": "high",
    "requires_validation": true,
    "rollback_on_crash": true,
    "delay_activation": "next_launch"
  }
}
```

## 五、应用场景规划
### 5.1 一期：基础配置（MVP）

| 场景         | 配置示例                                           | 优先级 |
| ---------- | ---------------------------------------------- | --- |
| 首页Banner运营 | `home_banner: {"id": 1, "img": "url"}`         | P0  |
| 功能开关       | `new_reader_enabled: true`                     | P0  |
| 多区域定价      | `pricing_tier: {"region": "ID", "price": 100}` | P0  |

### 5.2 二期：A/B测试
| 场景      | 实验组设计          | 指标       |
| ------- | -------------- | -------- |
| 阅读器引擎对比 | 旧版 vs 新版       | 崩溃率、阅读时长 |
| 章节长度优化  | 2000字 vs 3000字 | 完读率、付费转化 |
| 付费弹窗策略  | 3章触发 vs 5章触发   | 付费率、用户投诉 |

### 5.3 三期：个性化与风控

| 场景     | 配置维度                                           |
| ------ | ---------------------------------------------- |
| 合规动态关闭 | `disabled_features: ["comment", "share"]`      |
| 推荐算法切换 | `rec_algo: "collab_filter" vs "content_based"` |
| 容灾降级   | `api_endpoint: "backup-api.example.com"`       |

## 六、研发排期

| 阶段           | 周期    | 交付物                          | 负责人    |
| ------------ | ----- | ---------------------------- | ------ |
| **Week 1-2** | 基础SDK | 配置拉取、本地缓存、取值API              | 客户端    |
| **Week 3**   | SSE实时 | 长连接、重连机制、生命周期管理              | 客户端    |
| **Week 4**   | 服务端   | Config API、PostgreSQL存储、运营后台 | 后端     |
| **Week 5**   | 安全机制  | 沙盒验证、延迟生效、崩溃回滚               | 客户端    |
| **Week 6**   | A/B引擎 | 分桶算法、数据上报、对照组管理              | 客户端+数据 |
| **Week 7**   | 集成测试  | 灰度发布、压测、异常场景演练               | 全团队    |
| **Week 8**   | 上线    | 金丝雀发布、监控告警、文档完善              | 全团队    |

## 七、⚠️ 【重点】风险与注意事项

### 7.1 技术风险

| 风险        | 影响         | 缓解措施                         |
| --------- | ---------- | ---------------------------- |
| SSE大规模连接  | 服务端内存爆炸    | 连接数上限控制；心跳间隔30s+；HTTP/2多路复用  |
| 配置持久化导致崩溃 | App变砖，用户流失 | **四层防御机制**（沙盒/延迟/崩溃回滚/服务端撤回） |
| A/B分桶不一致  | 实验数据失真     | 用户ID+实验Key哈希，结果本地缓存          |
| 海外网络不稳定   | SSE频繁断连    | 指数退避重连；5分钟兜底轮询；delta补偿       |

### 7.2 运营风险
| 风险          | 影响       | 缓解措施                       |
| ----------- | -------- | -------------------------- |
| 运营误操作发布错误配置 | 线上故障     | 配置审核流程；金丝雀发布（5%→100%）；一键撤回 |
| 配置版本混乱      | 客户端配置不一致 | 单调递增版本号；服务端只保留最近100个版本     |
| 数据上报丢失      | A/B结果不准确 | 本地队列+批量上报；失败重试；去重机制        |

### 7.3 合规风险

| 风险        | 影响     | 缓解措施                  |
| --------- | ------ | --------------------- |
| 配置数据含敏感信息 | GDPR违规 | 配置数据脱敏；敏感配置加密存储       |
| 用户分桶数据出境  | 数据主权问题 | 分桶计算在客户端完成；服务端不存储用户标签 |


## 八、成功指标（OKR）

| 目标  | 关键结果    | 验收标准                |
| --- | ------- | ------------------- |
| 稳定性 | 配置下发成功率 | >99.9%              |
| 实时性 | 配置生效延迟  | P99 < 5秒（SSE在线时）    |
| 安全性 | 配置导致崩溃率 | <0.01%              |
| 效率  | 运营发版时间  | 从小时级降至分钟级           |
| 成本  | 基础设施成本  | 低于Firebase同用量成本的50% |

## 九、附录

### 9.1 参考实现（Flutter核心代码）
见前文提供的 RemoteConfigService 完整实现，包含：

- SSE长连接管理
- 三级缓存架构
- 崩溃自动回滚
- 断线delta补偿

### 9.2 服务端参考实现（Node.js）

见前文提供的 Express + PostgreSQL + Redis 架构。

### 9.3 关键依赖版本

# pubspec.yaml

```yaml
dependencies:
  http: ^1.2.0
  mmkv: ^1.3.0
  connectivity_plus: ^5.0.0
  crypto: ^3.0.0
```

 


