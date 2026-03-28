# A/B 稳定分桶哈希与客户端缓存规范

**状态**: 实现约束（客户端 SDK 必须遵守）  
**对齐文档**: `App自研远程配置库研发计划.md` §3.3；可行性分析「hash-spec」待办  
**相关契约**: `docs/api-contract-v1.md`（配置载荷中的实验元数据）

---

## 1. 为什么禁止 `String.hashCode`

| 问题 | 说明 |
|------|------|
| 无稳定规范 | Dart `Object.hashCode` 不要求在版本、平台间保持稳定；不同运行模式或优化可能导致**分组漂移**。 |
| 跨端不一致 | 即便短期内观测到一致，也不应依赖**未文档化的哈希算法**做长期实验。 |
| 与 `md5(...).hashCode` 组合 | `hashCode` 作用在 `Digest` 或字符串上仍同上；**不能**用 `hashCode` 从摘要派生桶号。 |

**结论**: 分桶用的整数必须从 **密码学或标准摘要的字节** 按本文档的**固定 endian 与取模规则**派生。

---

## 2. 推荐算法（MD5 摘要 → 桶索引）

### 2.1 输入规范化

在计算摘要前，将输入拼接为 **UTF-8 字节**，规则必须固定：

```
bucketInput = UTF8("$userId\0$experimentKey")
```

- 使用**显式分隔**（示例为 `\0`）避免 `userId` / `experimentKey` 边界歧义；若选用其它分隔符，须在版本化常量中写死并 bump 规范版本。  
- `userId` 为空或未登录：使用约定占位（如 `"anonymous"`），并在文档与埋点中可区分；**禁止**用空字符串隐含多义。

### 2.2 摘要

- 算法：**MD5**（与本研发计划示例一致；若组织偏好 SHA-256，可替换为 SHA-256，但须**全系 bump `ab_algo_version`** 以免与历史实验混桶）。
- 输出：16 字节 `digest[]`。

### 2.3 无符号 64 位整数派生（固定 big-endian）

取摘要**前 8 字节**，按 **big-endian** 解释为无符号 64 位整数 \(H\)：

\[
H = \sum_{i=0}^{7} digest[i] \times 256^{7-i}
\]

桶数 \(N = \texttt{bucketCount}\)（正整数）。桶索引：

\[
\text{bucketIndex} = H \bmod N
\]

### 2.4 Dart 实现注意（含 `dart2js`）

Dart `int` 在原生 VM 可表示任意精度；在 **JavaScript** 上整数大于 \(2^{53}\) 会失精。实现 **必须**用以下之一，禁止裸写 8 字节移位到单一 `int` 再取模（Web 可能静默错桶）：

- **`BigInt`**: 按字节构造 \(H\)，再 `H % BigInt.from(N)`；或  
- **逐字节累加取模**（对任意 \(N\) 安全）：  
  `acc = (acc * 256 + digest[i]) % N`，\(i = 0..7\)（与 big-endian 顺序一致时从 `digest[0]` 开始）。

群标签字符串可与研发计划一致：`group_${bucketIndex}` 或 `group_${bucketIndex + 1}`，**全局选一种并在实验平台写死**。

---

## 3. 与盐（salt）或实验版本

若服务端下发 **实验定义版本** `experiment_revision`（建议字段），输入应扩展为：

```
bucketInput = UTF8("$userId\0$experimentKey\0$experiment_revision")
```

这样在**实验定义变更**（如改桶数、改分层规则）时，同一用户可能合理换桶；客户端应在缓存 key 中包含 `experiment_revision`（见 §4）。

---

## 4. 客户端缓存策略

目标：**减少重复计算**、在**离线或弱网**仍可读桶，同时避免脏读。

### 4.1 缓存内容

对每个 `(experimentKey, experiment_revision?, userId)` 缓存：

- `bucketIndex`（或群标签）  
- 可选：`computed_at`（墙钟，用于排障）

**不强制缓存** `digest` 原串。

### 4.2 存储介质

- **首选**: MMKV（与配置 SDK 一致）。  
- Key 命名示例：`ab:v1:{experimentKey}:{experiment_revision}:{hashUser(userId)}`  
  - `hashUser` 可为 **SHA-256 截断** 或原值（若可接受本机可逆）；与隐私政策一致即可。

### 4.3 失效与重建（必须实现）

| 事件 | 行为 |
|------|------|
| `userId` 变更（登出/切账号） | 删除与该设备上**上一用户**相关的 AB 缓存键，或对命名空间整体 `clear`（权衡其它实验）。 |
| 服务端 `experiment_revision` 变化 | 旧 revision 的缓存**不**再使用；新 revision 未命中时重算。 |
| 本地升级 SDK 且 `ab_algo_version` bump | 清空 AB 缓存或 bump key 前缀命名空间（如 `ab:v2:`）。 |
| `bucketCount` / 实验未变 | **禁止**仅因 App 重启而清缓存（保证用户级一致性）。 |

### 4.4 与服务端规则的关系

- 若服务端仍对某些用户**强制指定**组别（白名单），客户端应在合并规则后**以服务端强制结果覆盖**本地哈希桶，并可选写回缓存以免重复请求。  
- 若完全客户端分桶，则服务端不下发个体桶号，仅下发实验参数模板；缓存策略以本文为准。

---

## 5. 单元测试清单（最小集）

- [ ] 给定固定 `userId` / `experimentKey` / `N`，桶索引与 **golden 向量**一致（覆盖 `N = 2, 10, 100`）。  
- [ ] `experiment_revision` 变化后索引允许变化（与 golden 快照一致）。  
- [ ] **Web 与 VM**（若发布 Web）同一输入同一输出。  
- [ ] 不存在对 `hashCode` 的路径依赖（可在 CI 中 grep 禁止 `hashCode` 与 MD5 链）。  

---

## 6. 修订记录

| 版本 | 日期 | 说明 |
|------|------|------|
| v1 | 2026-03-29 | 首版：禁止 `hashCode`、MD5+取模、Dart Web 注意、MMKV 缓存键与失效 |

---

*文档版本: v1 / 2026-03-29*
