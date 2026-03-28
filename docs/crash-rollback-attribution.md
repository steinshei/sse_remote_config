# 崩溃回滚触发条件与归因规范

**状态**: 实现约束（与安全 OKR 一致）  
**对齐文档**: `App自研远程配置库研发计划.md` §3.4（崩溃自动回滚、四层防御）  
**相关文档**: `docs/capacity-slo-sse.md` §4.3（配置导致崩溃率 SLO）  
**可行性**: 对应「crash-attribution」待办：细化触发条件，**区分配置相关与非相关崩溃**，降低误回滚。

---

## 1. 问题陈述

朴素的「启动时崩溃计数 ≥ 2 即回滚配置」会把以下噪声算进去：

- OOM、系统强杀、厂商 ROM 问题  
- 与配置无关的必现 bug（引擎其它模块）  
- 用户侧「清数据 / 恢复出厂」导致的异常启动序列  

**目标**: 仅在**有足够证据表明最近一次生效的高风险配置**可能参与崩溃时，才触发 **L3 客户端自动回滚**；其它情况依赖常规崩溃修复与 L4 服务端撤回。

---

## 2. 术语

| 术语 | 含义 |
|------|------|
| **active_version** | 当前 MMKV 中已激活的配置 `version`（整数）。 |
| **activation_time** | 某 `active_version` 最近一次成功 `activate` 的单调时间或 UTC 时间戳（建议两者都存）。 |
| **config_apply_window** | 自 `activate` 完成起算的短时间窗口，用于判断崩溃是否与「新配置生效」时间相近。 |
| **high_risk** | 配置项或整包在 `_meta` 中标记 `risk_level: high` 或 `rollback_on_crash: true`（与研发计划一致）。 |

---

## 3. 推荐：分段式状态机（替代纯「连续两次启动崩溃」）

### 3.1 持久化字段（示例）

| 键 | 类型 | 说明 |
|----|------|------|
| `crash_lifecycle_generation` | int | 每次**成功冷启动进入主界面**后 +1；用于区分不同「启动代」。 |
| `pending_generation` | int? | 最近一次已进入 `launch_started` 的代。 |
| `consecutive_config_suspect_crashes` | int | 在当前**归因策略下**累计的「配置可疑」崩溃次数。 |
| `last_crash_signature` | string? | 可选；上一坠现场简短指纹（见 §5），用于去重同一崩溃打满计数。 |
| `rollback_armed` | bool | 是否当前处于「新激活高风险配置」观察期。 |

### 3.2 `onAppLaunch`（进程入口）

1. 读取 `pending_generation`：若与上一轮写盘的 `crash_lifecycle_generation` 对不上或启动流程异常，按排障日志记录，**不擅自加计数**。  
2. 若上次在 `launch_started` 后**未调用** `onLaunchSuccess`（进程非正常结束）：  
   - 若 `rollback_armed == true` 且在 `config_apply_window` 内 → `consecutive_config_suspect_crashes += 1`  
   - 否则 → **不增加**配置可疑计数（或增加「未归因」计数仅供监控，**不触发回滚**）。  
3. 若 `consecutive_config_suspect_crashes >= threshold`（见 §4）→ 执行 `_rollbackToSafeConfig()`，上报 `config_crash_rollback`，重置计数与 `rollback_armed`。  
4. 将 `launch_started` 写入，`pending_generation = crash_lifecycle_generation`。

### 3.3 `onConfigActivated`（新配置生效后）

- 若本包或变更的 keys 包含 **high_risk**：设 `rollback_armed = true`，记录 `activation_time` 与 `active_version`。  
- 否则：`rollback_armed = false`（或保持不变，由产品决定是否在低风险也做弱回滚）。

### 3.4 `onLaunchSuccess`（主界面就绪）

- `consecutive_config_suspect_crashes = 0`。  
- `rollback_armed = false`（观察期结束；或延长到 N 分钟由产品定，本文建议 **成功后立即解除**，避免长期误伤）。  
- `crash_lifecycle_generation += 1` 并持久化。

---

## 4. 阈值与窗口（建议初值）

| 参数 | 建议 | 调整依据 |
|------|------|----------|
| `config_apply_window` | **3～10 分钟**（单调钟优先） | 越短误报越少，越长越不漏配；需结合 activate 到首屏耗时 |
| `threshold` | **2**（与研发计划一致） | 可线上分级：high_risk=2，其它仅上报不计数 |
| 可选「同签名去重」 | 同一 `last_crash_signature` 在 24h 内只计 1 次 | 避免用户反复点击图标刷计数 |

---

## 5. 归因信号（增强信心，可选叠加）

在崩溃上报 SDK（如 Firebase Crashlytics）设置自定义键，便于事后验证 SLO：

| 键 | 值示例 | 用途 |
|----|--------|------|
| `rc_active_version` | `42` | 崩溃时刻最后已知的激活版本 |
| `rc_rollback_armed` | `true/false` | 是否处于高风险观察期 |
| `rc_last_activate_age_ms` | `8500` | 距上次 activate 时长 |
| `rc_changed_keys` | `reader_engine,...` | 最近一次激活相对上一版的 diff（截断） |

**服务端 L4**（崩溃率 > 1% 撤回）依赖统计平台能否按 `rc_active_version` 分桶；客户端字段命名应保持与 `docs/api-contract-v1.md` 可对照。

### 5.1 「配置可疑」的最低门槛（建议）

下面满足 **至少一条** 才把「启动后未成功」计为配置可疑：

- `rollback_armed == true` **且** 最后的 `activate` 在 `config_apply_window` 内；或  
- 崩溃栈顶落在 **已知与可配置模块** 白名单（如阅读器插件加载）**且** `rc_changed_keys` 与栈模块相交。

否则只记通用崩溃，不驱动 L3。

---

## 6. 与四层防御的边界

| 层级 | 与本文关系 |
|------|------------|
| L1 沙盒 | 先在沙盒失败则不应 `activate` high_risk；可减少进入 `rollback_armed` 的坏配置。 |
| L2 延迟生效 | 若 `delay_activation: next_launch`，则 `onConfigActivated` 应对「下一启动才真正切换」的版本置 `rollback_armed`，避免窗口算错。 |
| L3 客户端回滚 | 以本文状态机为准。 |
| L4 服务端撤回 | 与监控侧 SLO 对齐；不替代 L3。 |

---

## 7. 测试与演练

- [ ] 模拟：高风险 activate → 首屏前 kill → 重启两次 → 验证回滚与安全配置。  
- [ ] 模拟：无高风险 activate → 首屏前 kill → 重启多次 → **不得**回滚配置。  
- [ ] 模拟：`delay_activation` 与观察期对齐。  
- [ ] 线上小流量：**仅日志 / 影子模式**（计数到埋点但不真回滚）跑 1～2 个版本再全开。

---

## 8. 修订记录

| 版本 | 日期 | 说明 |
|------|------|------|
| v1 | 2026-03-29 | 首版：`rollback_armed`、apply 窗口、归因门槛与 Crashlytics 键 |

---

*文档版本: v1 / 2026-03-29*
