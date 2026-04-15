# Clicky 端到端验证清单

> 创建：2026-04-15
> 目标：验证 Auth → 邀请码 → 限额 → 支付完整商业化链路

---

## 前置步骤（一次性）

### Supabase 迁移（按顺序执行）

在 Supabase Dashboard → SQL Editor 中依次执行：

| # | 文件 | 内容 | 状态 |
|---|------|------|------|
| 1 | `schema_migration_01.sql` | `invitation_verified` 列 + 更新 `use_invitation_code()` RPC + 测试邀请码种子 | [ ] |
| 2 | `schema_migration_02.sql` | Stripe 列（`stripe_customer_id`, `stripe_subscription_id`）| [ ] |
| 3 | `schema_migration_03.sql` | 100 个一次性邀请码种子数据 | [ ] |
| 4 | `schema_migration_04.sql` | 原子限额 RPC `check_and_increment_chat_quota()` | [ ] |

### Worker 部署

```bash
cd worker
npx wrangler deploy
```

确认 Worker secrets 已配置：
- [ ] `SILICONFLOW_API_KEY`
- [ ] `SUPABASE_URL`
- [ ] `SUPABASE_SERVICE_ROLE_KEY`

### Xcode 构建

在 Xcode 中 Cmd+R 构建运行（**不要用 xcodebuild**）。

---

## 验证流程

### 1. 注册与邮件确认

- [ ] 打开 app，菜单栏图标出现
- [ ] 点击图标，面板显示登录/注册表单
- [ ] 输入邮箱和密码，点击注册
- [ ] UI 切换到"等待邮件确认"状态
- [ ] 收到确认邮件，点击 `clicky://` 链接
- [ ] App 自动确认，UI 切换到邀请码输入界面

### 2. 邀请码门禁

- [ ] 确认未验证用户看到邀请码输入界面（不能使用 push-to-talk）
- [ ] 输入错误码 → 显示错误反馈
- [ ] 输入已用完的码 → 显示错误反馈
- [ ] 输入有效码（如 migration_03 中的任一码）→ 验证成功
- [ ] 成功后 UI 自动过渡到已登录主界面
- [ ] 确认大小写不敏感（输入小写也能通过）

### 3. 基本功能（已登录后）

- [ ] Push-to-talk (ctrl+option) 正常录音
- [ ] 语音转文字正常（WhisperKit 或 Apple Speech fallback）
- [ ] 截屏正常（Screen Recording 权限）
- [ ] Claude/Qwen 回复正常（SSE 流式）
- [ ] TTS 语音播放正常
- [ ] 蓝色光标指向动画正常（如果回复包含 POINT 标签）

### 4. 用量计量

- [ ] `signedInRow` 显示今日用量进度条
- [ ] 每次对话后，用量计数递增
- [ ] GET `/quota` 返回正确的 `used_today` / `remaining`
- [ ] 接近限额时显示警告
- [ ] Supabase `api_usage_logs` 表有对应记录

### 5. 限额拦截

- [ ] 手动在 Supabase 将 `daily_chat_count` 设为 19（接近 free 的 20 限额）
- [ ] 再发一次对话 → 成功（计数变 20）
- [ ] 再发一次 → 收到 429，UI 显示"额度已用完"
- [ ] 显示升级引导

### 6. 微信支付升级（如适用）

- [ ] 点击升级按钮，选择 Pro/Premium
- [ ] QR 码正确生成并显示
- [ ] 扫码支付后，轮询检测到支付成功
- [ ] UI 切换到付费用户视图
- [ ] `user_profiles.plan` 更新为 `pro` 或 `premium`
- [ ] 限额提升到新套餐额度

### 7. 邀请码分享

- [ ] 已登录用户在 `signedInRow` 中看到个人邀请码
- [ ] 点击复制按钮，邀请码复制到剪贴板
- [ ] UserCenterView 中显示已邀请人数
- [ ] 用此码注册新用户 → 邀请人的 `invited_count` +1

### 8. 登出与重新登录

- [ ] 点击登出，UI 回到登录表单
- [ ] 重新登录，session 恢复，不需要重新输入邀请码
- [ ] 用量数据保持一致

---

## 跨日重置验证

- [ ] 手动修改 Supabase 中 `daily_chat_reset_at` 为昨天的日期
- [ ] 发送一次对话 → `daily_chat_count` 应重置为 1（而非累加）
- [ ] `daily_chat_reset_at` 更新为今天

---

## 已知限制

- **微信支付需要商户证书配置** — 如未配置则跳过 Phase 6 验证
- **WhisperKit 首次使用需下载模型**（~800MB）— 下载期间 fallback 到 Apple Speech
- **邮件确认链接中的 `clicky://` scheme** — 需要 app 已安装并注册 URL scheme
