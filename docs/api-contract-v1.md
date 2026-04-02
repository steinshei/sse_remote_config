# 远程配置客户端—服务端契约（v1 冻结）

**状态**: 冻结（客户端先行基线，可与后端评审修订后再 bump 版本）  
**对齐文档**: `App自研远程配置库研发计划.md` §4  
**Base path**: `/v1`（所有路径均相对于 `{origin}/v1`）

---

## 1. 通用约定

| 项 | 约定 |
|----|------|
| 传输 | HTTPS only |
| 字符集 | UTF-8 |
| 时间 | ISO 8601 UTC（如 `2026-03-29T12:00:00Z`），仅用于可选字段（如 ack） |
| JSON | 字段含义以本文档为准；**客户端对未知字段必须忽略**（宽松演进） |
| 版本号 | `version` 为**单调递增**非负整数；同一 `app_id` + 环境维度下全局递增 |
| Content-Type | REST 请求/响应：`application/json`；SSE：见 §4 |

### 1.1 公共查询参数（REST + SSE 建立连接时）

客户端应在拉取/订阅时尽量带齐，便于服务端规则引擎与审计。

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `app_id` | string | 是 | 应用标识（与运营后台一致） |
| `platform` | string | 是 | `ios` \| `android` |
| `app_version` | string | 建议 | 原生semver或构建号，如 `2.5.0` |
| `locale` | string | 否 | BCP 47，如 `id-ID` |
| `region` | string | 否 | 国家/大区，如 `ID` |

### 1.2 可选鉴权（Movable）

若未启用鉴权：省略即可。若启用：

- Header：`Authorization: Bearer <token>`  
- 或：`X-App-Key: <key>`（具体选型由后端评审定案，**客户端仅用抽象配置注入 header**）

### 1.3 错误响应（统一信封）

HTTP 4xx/5xx 时，响应体优先使用 JSON（502/504 等网关错误可能无 body）。

```json
{
  "error": {
    "code": "INVALID_ARGUMENT",
    "message": "since must be a non-negative integer",
    "request_id": "550e8400-e29b-41d4-a716-446655440000"
  }
}
```

| `error.code`（示例） | HTTP | 含义 |
|----------------------|------|------|
| `UNAUTHORIZED` | 401 | 鉴权失败 |
| `FORBIDDEN` | 403 | 无权限 |
| `INVALID_ARGUMENT` | 400 | 参数非法 |
| `NOT_FOUND` | 404 | 资源不存在 |
| `RATE_LIMITED` | 429 | 限流 |
| `INTERNAL` | 500 | 服务端错误 |

---

## 2. GET `/config/latest`

全量拉取**当前对客户端可见**的配置包（服务端已按规则解析后的快照；若服务端一期只做静态包，仍为同一 JSON 形状）。

### 2.1 请求

- **Path**: `/v1/config/latest`
- **Query**: §1.1 公共参数

### 2.2 响应

**200 OK** — Body 为 **配置包**（见 §5  schema 与 §6 样例）。

**304 Not Modified**（可选实现）— 若客户端发送 `If-None-Match: "<etag>"` 且配置未变，可无 body。客户端无此能力时可忽略。

---

## 3. GET `/config/delta`

断线补偿 / 节省流量：基于客户端已有 `since` 版本判断是否有更新。

### 3.1 请求

- **Path**: `/v1/config/delta`
- **Query**: §1.1 公共参数 **+**  
  - `since`（**必填**）— 非负整数；客户端本地记录的已确认 `version`  

### 3.2 响应（v1 冻结）

| 情况 | HTTP | Body |
|------|------|------|
| 服务端当前版本 **>** `since` | **200** | 与 `/config/latest` **完全相同**的包结构（全量快照）；客户端用响应整体覆盖本次 fetch 结果，再进入 activate 流程 |
| 服务端当前版本 **≤** `since` | **204 No Content** | 无 body；可选响应头 `X-Config-Version: <int>` 便于调试 |

> **说明**: v1 不冻结「按键增量」JSON；后续若引入 partial merge，应通过新增字段（如 `patch_format`）并 bump 契约版本，避免破坏旧客户端。

### 3.3 错误

- `since` 非法 → 400 + `INVALID_ARGUMENT`

---

## 4. GET `/config/stream`（SSE）

实时通知：**不通过 SSE 下发完整配置 JSON**，仅通知「有新版本或事件」；客户端收到后调用 `latest` 或 `delta`。

> 说明：本节描述的是当前远程配置库自己的实时通知协议，不是 MCP / JSON-RPC transport。若后续需要引入 MCP `Streamable HTTP`，请另见 [mcp-transport-adoption.md](mcp-transport-adoption.md)。

### 4.1 请求

- **Path**: `/v1/config/stream`
- **Query**: §1.1 公共参数（与 latest 一致）
- **Headers**:
  - `Accept: text/event-stream`
  - 鉴权同 §1（若启用）

### 4.2 SSE 行为（v1 冻结）

| 项 | 约定 |
|----|------|
| 媒体类型 | `text/event-stream` |
| 编码 | UTF-8 |
| 心跳 | 服务端应定期发送 **comment** 或 **ping 事件**（建议间隔 ≤ 30s），避免代理/ LB 空闲断开 |
| 重连 | 客户端断线后指数退避重连；恢复后**先** `delta?since=<本地version>` 再视情况 `latest` |

### 4.3 事件类型

每条事件可包含可选 `id:`、`event:`、`data:`（可多行 `data:`，按 SSE 规范拼接）。

#### `ping`（保活）

```text
event: ping
data: {"ts":"2026-03-29T12:00:00Z"}
```

#### `config_updated` — 有新配置

客户端应发起拉取（优先 `delta`）。

```text
event: config_updated
data: {"version":43,"kind":"publish"}
```

| `data` 字段 | 类型 | 说明 |
|-------------|------|------|
| `version` | integer | 新版本号 |
| `kind` | string | 固定枚举：`publish` \| `rollback`（扩展值客户端忽略，仅打日志） |

#### `config_revoke` — 紧急撤回信号

客户端应尽快拉取；服务端可能在拉取结果中体现回退版本或元数据。

```text
event: config_revoke
data: {"from_version":43,"to_version":42,"reason":"incident_20260329"}
```

| `data` 字段 | 类型 | 说明 |
|-------------|------|------|
| `from_version` | integer | 被撤回的发布版本 |
| `to_version` | integer | 目标安全版本（可与本地合并策略一起使用） |
| `reason` | string | 可选，运维/审计短语 |

---

## 5. 配置包 JSON Schema（逻辑）

与研发计划 §4.2 对齐并略作结构化说明。

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `version` | integer | 是 | 配置版本 |
| `data` | object | 是 | key → bool / number / string / object / array 的叶子约定由业务定义 |
| `conditions` | object | 否 | 本包适用条件描述（展示/调试为主；复杂求值仍以服务端为准） |
| `_meta` | object | 否 | 安全与生效策略提示 |
| `experiments` | array | 否 | A/B 实验定义块，见 §5.1 |

### 5.1 `experiments[]` 元素（可选）

用于服务端下发实验结构与变体参数；**分桶计算在客户端完成**（计划要求），服务端不下发用户级分组结果。

| 字段 | 类型 | 说明 |
|------|------|------|
| `key` | string | 实验唯一键 |
| `bucket_count` | integer | 分桶数 ≥ 2 |
| `variants` | object | 键为桶索引字符串 `"0".."n-1"`，值为该桶覆盖的 `data` 片段（浅层 object，客户端按约定 merge） |

### 5.2 `_meta` 建议字段

| 字段 | 类型 | 说明 |
|------|------|------|
| `risk_level` | string | 如 `low` \| `medium` \| `high` |
| `requires_validation` | boolean | 是否需要沙盒校验 |
| `rollback_on_crash` | boolean | 是否参与崩溃回滚策略 |
| `delay_activation` | string | 如 `immediate` \| `next_launch` |

---

## 6. JSON 样例

### 6.1 `GET /config/latest` 200 — 完整示例

```json
{
  "version": 42,
  "data": {
    "reader_engine": "new",
    "theme_color": "#FF5722",
    "chapter_price": 100,
    "home_banner": {
      "id": 1,
      "img": "https://cdn.example.com/banner/1.png"
    },
    "feature_flags": {
      "new_reader_enabled": true
    }
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
  },
  "experiments": [
    {
      "key": "reader_engine_ab",
      "bucket_count": 2,
      "variants": {
        "0": {
          "reader_engine": "legacy"
        },
        "1": {
          "reader_engine": "new"
        }
      }
    }
  ]
}
```

### 6.2 `GET /config/delta?since=41` 200 — 与 latest 同形（v1 全量快照）

```json
{
  "version": 42,
  "data": {
    "reader_engine": "new",
    "theme_color": "#FF5722",
    "chapter_price": 100,
    "home_banner": {
      "id": 1,
      "img": "https://cdn.example.com/banner/1.png"
    },
    "feature_flags": {
      "new_reader_enabled": true
    }
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
  },
  "experiments": [
    {
      "key": "reader_engine_ab",
      "bucket_count": 2,
      "variants": {
        "0": {
          "reader_engine": "legacy"
        },
        "1": {
          "reader_engine": "new"
        }
      }
    }
  ]
}
```

### 6.3 `GET /config/delta?since=42` — 无更新

- HTTP **204 No Content**

### 6.4 错误示例 — 400

```json
{
  "error": {
    "code": "INVALID_ARGUMENT",
    "message": "since must be a non-negative integer",
    "request_id": "7c9e6679-7425-40de-944b-e07fc1f90ae7"
  }
}
```

### 6.5 SSE 片段示例（同一连接内多事件）

```text
: keep-alive

event: ping
data: {"ts":"2026-03-29T12:00:00Z"}

event: config_updated
data: {"version":43,"kind":"publish"}

event: config_revoke
data: {"from_version":43,"to_version":42,"reason":"crash_rate_spike"}
```

---

## 7. POST `/config/ack`（可选，v1 保留）

精确送达/统计时使用；未接入前客户端可不调用。

- **Path**: `/v1/config/ack`
- **Body**:

```json
{
  "app_id": "com.example.reader",
  "platform": "android",
  "device_id": "opaque-installation-id",
  "version_ack": 42,
  "received_at": "2026-03-29T12:00:05Z"
}
```

- **200**：

```json
{
  "ok": true
}
```

---

## 8. 与客户端实现的兼容承诺

1. **解析宽松**：新增 JSON 字段不得导致客户端崩溃。  
2. **Delta v1**：有更新即返回与 `latest` 同结构的**全量** `data` 快照（在 `version` 维度上）。  
3. **SSE**：仅作通知；**权威状态仍以 REST 拉取为准**。  
4. **分桶哈希**：客户端实现**不得**依赖语言内置 `String.hashCode` 做跨版本/跨平台稳定分桶；应采用对摘要字节或标准算法的固定取模（与研发计划可行性备注一致，实现见 SDK 而非本契约正文）。

---

## 9. 评审检查清单（后端 / 客户端）

- [ ] `version` 单调性与 204 语义是否在压测环境验证  
- [ ] SSE 心跳间隔与网关 / LB 超时对齐  
- [ ] 鉴权方式（Bearer vs App Key）与灰度环境  
- [ ] `conditions` 由服务端解析 vs 原样下发给客户端的范围  
- [ ] 管理端接口（`/admin/*`）是否独立鉴权、不在 App 内暴露  

定稿评审通过后，修订本文件顶部的**状态**与**版本号**（如 `v1.1`），并避免静默更改 v1 已冻结语义。
