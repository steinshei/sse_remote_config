# MCP Transport 接入预案

本文档描述如何在 **不破坏当前远程配置协议** 的前提下，为本库后续接入 MCP transport 做准备。

## 1. 当前状态

当前实时链路不是 MCP：

- 线协议：自定义远程配置通知协议
- 入口：`GET /v1/config/stream`
- 载荷：SSE `event` + `data`
- 客户端动作：收到事件后重新调用 `fetchAndActivate()`

当前代码层已经具备最小演进抽象：

- `RealtimeNotificationTransport`
- `ConfigNotification`
- `SseConfigNotificationTransport`
- `RemoteConfigSyncCoordinator.transportFactory`

这层抽象的作用是把“实时通知传输”从“远程配置业务协议”里拆开。

## 2. 为什么不直接迁移

MCP 官方当前推荐的是 `Streamable HTTP`，而不是旧的独立 `HTTP+SSE` transport。

官方参考：

- MCP transports: https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
- MCP legacy transports: https://modelcontextprotocol.io/legacy/concepts/transports
- MCP changelog: https://modelcontextprotocol.io/specification/2025-03-26/changelog

需要注意两点：

- 被替代的是 MCP 里的独立 `HTTP+SSE transport`
- `SSE` 本身没有消失，它仍然可以作为 `Streamable HTTP` 的服务端流式返回机制

因此，对本项目来说，“切到 MCP transport”不是简单替换底层连接类，而是一次协议升级：

- 需要引入 JSON-RPC/MCP 消息模型
- 需要服务端暴露单 MCP endpoint，而不只是 `/config/stream`
- 需要处理会话、POST/GET、协议版本头、认证、恢复和重投递语义

## 3. 推荐接入路径

推荐分两阶段推进。

### 阶段一：保留现协议，补齐客户端扩展点

当前已完成：

- 同步协调器依赖 transport 抽象，而非写死 SSE 客户端
- 当前 SSE 实现作为默认 transport 保留
- 可通过 `transportFactory` 注入新 transport

阶段一不改：

- `RemoteConfigClient`
- `/config/latest`
- `/config/delta`
- `/config/stream`
- 远程配置包 JSON 结构

### 阶段二：新增 MCP transport 实现

新增一个 MCP transport 适配层，例如：

```dart
class McpStreamableHttpNotificationTransport
    implements RealtimeNotificationTransport {
  @override
  Stream<ConfigNotification> get notifications => ...;

  @override
  Future<void> start() async { ... }

  @override
  Future<void> stop() async { ... }
}
```

职责边界建议如下：

- transport 层：负责 MCP 握手、POST/GET、SSE 流、恢复、认证头
- adapter 层：把 MCP JSON-RPC 消息映射为库内 `ConfigNotification`
- 业务层：继续只关心 `ConfigNotification.event`

这样可以保证 `RemoteConfigSyncCoordinator` 不感知 MCP 细节。

## 4. 客户端需要补的能力

如果后续实现 MCP `Streamable HTTP`，客户端至少需要补这些能力。

### 4.1 协议层

- 发送 `InitializeRequest`
- 携带 `MCP-Protocol-Version` 请求头
- 支持 HTTP `POST` 发送 JSON-RPC 消息
- 支持 HTTP `GET` 建立 SSE 流式接收
- 支持服务端返回单次 JSON 或 SSE 流

### 4.2 会话与恢复

- 保存 `Mcp-Session-Id`
- 断线后按服务端能力决定是否复用会话
- 若服务端 SSE 事件带 `id`，支持 `Last-Event-ID`
- 当会话失效时重新初始化

### 4.3 安全与鉴权

- 认证头透传到 MCP endpoint
- HTTPS only
- 明确本地调试与生产的 Origin / Session 安全要求

## 5. 服务端需要补的能力

如果远程配置服务端要升级到 MCP，不能只把 `/config/stream` 改名。

至少需要：

- 单一 MCP endpoint，同时支持 `POST` 和 `GET`
- JSON-RPC 请求/响应处理
- 初始化协商
- 可选会话管理
- 可选 SSE 流式返回
- 可选断线恢复与事件重投递

对于远程配置场景，建议先把 MCP 只用于“通知”，不要把完整配置包直接塞进流里。当前模型更稳妥：

- MCP 消息只表达“有更新”或“撤回”
- 真正的权威配置仍然走 `latest` / `delta`

这样可以继续保留：

- 缓存语义
- 版本语义
- 容灾和回滚流程
- 现有 REST 契约的调试与观测能力

## 6. 推荐消息映射

如果后续要把 MCP 消息映射成库内通知，建议保持与现有事件语义一致：

| MCP 消息 | 映射后的 `ConfigNotification.event` | 客户端动作 |
|----------|-------------------------------------|------------|
| 心跳/keepalive | `ping` | 仅统计与保活 |
| 有新版本 | `config_updated` | 调用 `fetchAndActivate()` |
| 紧急撤回 | `config_revoke` | 调用 `fetchAndActivate()` |

`ConfigNotification.data` 里可以继续承载：

- `version`
- `kind`
- `from_version`
- `to_version`
- `reason`

这样能最大程度复用现有 coordinator 逻辑。

## 7. 兼容策略

推荐双栈兼容，而不是直接替换。

### 客户端

- 默认仍使用 `SseConfigNotificationTransport`
- 通过配置或依赖注入切换到 `McpStreamableHttpNotificationTransport`

### 服务端

- 保留 `/config/stream`
- 新增 MCP endpoint
- 等新客户端稳定后，再决定是否下线旧协议

## 8. 最小实现清单

后续真正实现 MCP transport 时，建议按这个顺序推进：

1. 新增 `McpStreamableHttpNotificationTransport`
2. 抽出 MCP 消息到 `ConfigNotification` 的映射器
3. 为 transport 增加 contract tests
4. 为 coordinator 增加 MCP transport 集成测试
5. 补文档：接入方式、协议头、兼容策略
6. 服务端联调：初始化、断线恢复、鉴权、重投递

## 9. 验收标准

MCP transport 接入完成后，至少应满足：

- `RemoteConfigSyncCoordinator` 无需修改业务逻辑即可切换 transport
- 收到 MCP 通知后仍然只触发 `fetchAndActivate()`
- 断线重连后不会丢失关键更新通知
- 认证头与请求上下文可正常透传
- 与现有 SSE transport 可并行共存
