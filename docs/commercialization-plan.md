# Clicky 商业化路线图

> 最后更新：2026-04-15
> 状态：Phase 1-3 代码完成，Supabase 迁移已执行，Worker 已部署。Qwen 元素指向（tool calling）已实现，待端到端验证。

---

## 架构定位

| 模式 | 用途 | API Key | 对应代码 |
|------|------|---------|---------|
| **Proxy（生产）** | 面向最终用户。Worker 持有 API key，用户零配置 | Worker 端 `SILICONFLOW_API_KEY` | `OpenAICompatibleChatAPI` + `OpenAICompatibleTTSClient` |
| **Direct（开发）** | 开发者调试用，本地填 key 测试 | 用户自行配置 | 同上（直连 SiliconFlow） |

**核心原则：** 用户永远不配置 API key。Proxy 模式 + Auth + 限额 是收费商业模式的基础。Direct 模式仅供内部工程测试。

---

## 当前进度概览

| 阶段 | 状态 | 说明 |
|------|------|------|
| Phase 0: 数据库 Schema | ✅ 已完成 | Supabase 表结构、RLS、触发器、函数 |
| Phase 0.5: SiliconFlow 模型替换 | ✅ 已完成 | 客户端可配置 API 层 + Qwen 3.5 Preset |
| Phase 1a: Supabase Auth 集成 | ✅ 已完成 | Swift 端认证 + Worker JWT 验证 + 邮件确认流程 |
| Phase 1b: Worker 改造为 SiliconFlow 代理 | ✅ 已完成 | 提交 `fa70d6a`，已部署，国际站 api.siliconflow.com |
| Phase 2: 邀请码准入 | ✅ 代码完成 | Swift 端 + Worker + UI 已实现，待 Supabase 迁移执行 + 端到端验证 |
| Phase 3: 用量计量与限额 | ✅ 代码完成 | Worker 限额（已改为原子 RPC）+ 客户端用量展示，待 Supabase 迁移执行 + 端到端验证 |
| Phase 4: 套餐与支付 | 🔶 部分完成 | 微信支付已实现（QR 码 + 轮询），Stripe 代码保留但未启用，Schema 迁移 02 已写（Stripe 列） |
| Phase 5: 用户中心 | ✅ 代码完成 | UserCenterView 已实现：套餐展示、用量统计、邀请码管理、微信支付升级流程 |

---

## Phase 0: 数据库 Schema ✅

**已完成** — 提交 `4c23413`

已建表：
- `user_profiles` — 用户配置，含套餐、用量统计、邀请码字段
- `invitation_codes` — 邀请码（多次使用、过期控制）
- `invitation_uses` — 邀请使用记录
- `api_usage_logs` — API 调用计量（chat/tts/stt）
- `plans` — 套餐定义（free 20次/日, pro 200次/日, premium 无限）

已实现：
- RLS 策略（用户只能读写自己的数据）
- `handle_new_user()` 触发器：注册时自动创建 profile + 生成 8 位邀请码
- `use_invitation_code()` 函数：验证并消耗邀请码，更新邀请人计数

Schema 文件：`scripts/schema.sql`

---

## Phase 0.5: SiliconFlow 模型替换 ✅

**已完成** — 提交 `4618de9`

- 客户端已支持 proxy / direct 双模式
- `APIConfiguration.swift` 新增 `ChatAPIFormat`（anthropic / openai_compatible）
- `OpenAICompatibleChatAPI.swift` — OpenAI 格式 Chat 客户端
- `OpenAICompatibleTTSClient.swift` — OpenAI 格式 TTS 客户端
- SiliconFlow preset 已配置 Qwen 3.5 全系模型
- Direct 模式可直连 `api.siliconflow.cn/v1`

详见：[SiliconFlow 模型生态调研](./siliconflow-model-research.md)

---

## Phase 1a: Supabase Auth 集成 ✅

**已完成** — 提交 `fa70d6a`

### 已完成的内容

| 文件 | 说明 |
|------|------|
| `SupabaseAuthManager.swift` | 邮箱/密码认证，Keychain 持久化，token 自动刷新，邮件确认流程，resend 支持 |
| `worker/src/index.ts` | JWKS/ES256 JWT 验证（Supabase P-256 签名） |
| `OpenAICompatibleChatAPI.swift` | `bearerToken` 参数，proxy 模式传递 Supabase JWT |
| `OpenAICompatibleTTSClient.swift` | `bearerToken` 参数支持 |
| `CompanionManager.swift` | proxy 模式下从 SupabaseAuthManager 获取 JWT 并传递 |
| `CompanionPanelView.swift` | 三态 auth UI（已登录 / 等待邮件确认 / 表单），注册/登录视觉区分 |
| `Info.plist` | `SupabaseProjectURL` + `SupabaseAnonKey` |
| `leanring_buddyApp.swift` | 启动时 `restoreSession()` |

### 技术决策

- **纯 URLSession 而非 supabase-swift SPM** — 避免 xcodeproj 改动，KISS 原则
- **JWKS/ES256 验证** — Supabase 使用 ECC P-256 签名（非 HS256）
- **邮箱/密码而非 Apple Sign In** — 无付费 Apple Developer 账号
- **emailConfirmationRequired 错误类型** — 注册成功但邮件确认开启时，UI 切换到等待确认视图而非显示错误

---

## Phase 1b: Worker 改造为 SiliconFlow 代理 ✅

**已完成** — 提交 `fa70d6a`，已部署到 Cloudflare

### 已完成路由

| 路由 | 上游 | 说明 |
|------|------|------|
| `POST /chat` | `api.siliconflow.com/v1/chat/completions` | OpenAI 格式，SSE 流式，Qwen3.5-397B 默认 |
| `POST /tts` | `api.siliconflow.com/v1/audio/speech` | OpenAI 格式，CosyVoice2-0.5B alex 声音 |
| `POST /transcribe-token` | — | **已废弃**（WhisperKit 本地推理替代） |

### Worker Secrets（已配置）

| 变量 | 状态 |
|------|------|
| `SILICONFLOW_API_KEY` | ✅ 已设置 |
| `SUPABASE_URL` | ✅ 已设置，JWT JWKS 验证用 |
| `ANTHROPIC_API_KEY` | 已移除 |
| `ELEVENLABS_API_KEY` | 已移除 |
| `ASSEMBLYAI_API_KEY` | 已移除 |

### wrangler.toml [vars]

```toml
SILICONFLOW_BASE_URL = "https://api.siliconflow.com/v1"   # 国际站（国内站从 CF edge 超时）
DEFAULT_CHAT_MODEL = "Qwen/Qwen3.5-397B-A17B"
DEFAULT_TTS_MODEL = "FunAudioLLM/CosyVoice2-0.5B"
DEFAULT_TTS_VOICE = "FunAudioLLM/CosyVoice2-0.5B:alex"
```

> ⚠️ **关键决策**：使用国际站 `api.siliconflow.com`，国内站 `api.siliconflow.cn` 从 Cloudflare Worker 边缘节点访问超时（exit code 28）。

### 模型选项（供用户体验）

| 模型 ID | 参数量 | 类型 | 适用场景 |
|---------|--------|------|---------|
| `Qwen/Qwen3.5-397B-A17B` | 397B (激活 17B) | MoE | 旗舰质量（默认） |
| `Qwen/Qwen3.5-122B-A10B` | 122B (激活 10B) | MoE | 均衡 |
| `Qwen/Qwen3.5-35B-A3B` | 35B (激活 3B) | MoE | 轻量快速 |
| `Qwen/Qwen3.5-27B` | 27B | Dense | 稳定可靠 |

以上均为统一多模态模型，原生支持图像理解（截图分析）。

---

## Phase 2: 邀请码准入 ✅

> 依赖：Phase 1 完成 — **代码已完成，待执行 Supabase 迁移 + 端到端验证**

### 2.1 注册后邀请码验证

- [x] 新用户首次登录后，检查是否已通过邀请码验证（`isInvitationGated` in `CompanionPanelView`）
- [x] 未验证用户进入邀请码输入界面（`invitationCodeEntrySection`）
- [x] 调用 `use_invitation_code()` RPC 验证码（`SupabaseAuthManager.useInvitationCode()`）
- [x] 验证成功后解锁 app 功能（`invitationVerified` 自动刷新）

### 2.2 邀请码输入 UI

- [x] 在 CompanionPanelView 中添加邀请码输入界面
- [x] 8 位大写字母/数字输入框
- [x] 实时验证反馈（成功/失败/已过期/已用完）
- [x] 成功后自动过渡到主界面

### 2.3 用户邀请码分享

- [x] 在面板中显示当前用户的个人邀请码（`signedInRow` + `UserCenterView.inviteSection`）
- [x] 一键复制邀请码
- [x] 显示已邀请人数（`invited_count`）

### 待执行

- [ ] 在 Supabase 执行 `schema_migration_01.sql`（添加 `invitation_verified` 列 + 更新 RPC）
- [ ] 在 Supabase 执行 `schema_migration_03.sql`（100 个一次性邀请码种子数据）
- [ ] 端到端验证

### 技术决策

- **为什么需要邀请码**: 控制早期用户增长，避免 API 成本失控
- **验证时机**: 注册后首次使用时验证，不阻断注册流程本身
- **大小写不敏感**: RPC 自动 `upper()` 输入码，用户不需要手动切大写

---

## Phase 3: 用量计量与限额 ✅

> 依赖：Phase 1 完成 — **代码已完成，待执行 Supabase 迁移 + 端到端验证**

### 3.1 Worker 端用量记录

- [x] `/chat` 路由：解析响应中的 `usage` 字段（`recordChatUsage()` via `ctx.waitUntil()`）
- [x] 每次成功调用写入 `api_usage_logs` 表
- [x] Worker 使用 Supabase `service_role` key 写入日志

### 3.2 每日限额检查

- [x] `/chat` 路由前置检查：`checkAndIncrementChatQuota()`
- [x] 超过 `plans.daily_chat_limit` 时返回 429 + 剩余额度信息
- [x] 每日重置逻辑：跨天时自动重置计数
- [x] 计数原子递增（`check_and_increment_chat_quota` RPC，`SELECT ... FOR UPDATE` 防竞态）

### 3.3 客户端用量展示

- [x] CompanionPanelView 显示今日已用/剩余次数（进度条）
- [x] 接近限额时警告提示
- [x] 达到限额时显示升级引导（`planUpgradeSection`）
- [x] 429 响应的 UI 反馈

### 待执行

- [ ] 在 Supabase 执行 `schema_migration_04.sql`（原子限额 RPC）
- [ ] 重新 deploy Worker（`npx wrangler deploy`）
- [ ] 端到端验证

### 技术决策

- **为什么 Worker 端计量**: 客户端不可信，所有计量必须在服务端
- **动态重置 vs Cron**: 优先用动态检查（读时重置），减少基础设施依赖
- **原子 RPC vs REST read-then-write**: 使用 `SELECT ... FOR UPDATE` 行锁防止并发请求绕过限额

---

## Phase 4: 套餐与支付 🔶

> 依赖：Phase 3 完成

> 部分完成 — 微信支付已实现，Stripe 代码保留，Apple IAP 未开始

### 4.1 支付方案选型

- [x] 微信支付 Native（QR 码扫码 + 轮询确认，`WeChatPayClient` + Worker 路由）
- [x] Stripe Checkout（代码保留在 `StripeCheckoutClient.swift`，Worker 路由已注释）
- [x] Schema 迁移 02 已写（`stripe_customer_id` / `stripe_subscription_id` 列）
- [ ] 评估 RevenueCat vs 直接 StoreKit 2（Apple IAP）

### 4.2 Apple IAP 商品配置

- [ ] App Store Connect 创建订阅商品
  - `clicky_pro_monthly` — ¥29/月
  - `clicky_premium_monthly` — ¥99/月
- [ ] RevenueCat Dashboard 配置 Offering

### 4.3 客户端购买流程

- [ ] 套餐展示页面（free/pro/premium 对比卡片）
- [ ] 购买按钮 → RevenueCat SDK 发起购买
- [ ] 购买成功后更新本地状态
- [ ] 恢复购买功能

### 4.4 服务端同步

- [ ] RevenueCat Webhook → Worker/Supabase Edge Function
- [ ] 购买/续费/取消/过期事件更新 `user_profiles.plan`
- [ ] Worker 端查询用户套餐时以 Supabase 数据为准

---

## Phase 5: 用户中心与仪表盘 ✅

> 依赖：Phase 1-3 完成 — **核心功能已实现**

- [x] 当前套餐 + plan 标签展示（`UserCenterView`）
- [x] 用量统计 — 今日对话数 / 限额进度条（免费用户 + 付费用户）
- [x] 邀请码管理 + 一键复制 + 已邀请人数
- [x] 微信支付升级流程（QR 码生成 + 3 秒轮询 + 成功状态）
- [ ] 个人资料设置（display_name、avatar）— 未实现
- [ ] 用量统计扩展（本周/本月维度）— 未实现
- [ ] 模型/语音/快捷键偏好设置 — 部分在 GeneralSettingsView / APISettingsView

---

## 技术依赖清单

| 依赖 | 用途 | 阶段 |
|------|------|------|
| SiliconFlow API | Chat + TTS（国际站） | Phase 1b ✅ |
| Supabase (SG region) | Auth + Database | Phase 1a ✅ |
| Cloudflare Worker | API 代理 + 鉴权 + 计量 | Phase 1 ✅ |
| WhisperKit (argmaxinc) | 本地 STT，Apple Neural Engine | Phase 1b ✅ |
| RevenueCat SDK | Apple IAP 管理 | Phase 4 |
| SwiftUI Charts | 用量图表 | Phase 5 |

## 风险与注意事项

1. **API 成本控制**: 邀请码是第一道防线，限额是第二道。Phase 1-3 应尽快串联完成
2. **STT 方案**: ✅ 已选用 WhisperKit（本地 Apple Neural Engine，0.46s 延迟，2.2% WER），优于 AssemblyAI 实时流式。~800 MB 模型按需下载，Apple Speech 作为未下载时的免费 fallback
3. **国内站 vs 海外站**: SiliconFlow 国内站（`api.siliconflow.cn`）从 Cloudflare Worker 访问超时，已改用国际站 `api.siliconflow.com`
4. **Qwen 3.5 多模态**: Qwen 3.5 统一多模态架构，原生支持图像，无需单独 VL 模型
5. **App Store 审核**: IAP 审核周期较长，Phase 4 需要提前准备商品配置
6. **TCC 权限**: 不要从终端 `xcodebuild`，会导致屏幕录制/辅助功能权限失效
