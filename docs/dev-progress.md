# Clicky 开发进度记录

> 最后更新：2026-04-16

---

## 2026-04-15 会话记录

### 完成的工作

#### 1. 仓库清理
- 移除 57 个误入 git 的临时文件（`.playwright-mcp/`、`.spec-workflow/`、`worker/.wrangler/`）
- 更新 `.gitignore` 覆盖工具产物和 `supabase/` 本地配置

#### 2. 数据库迁移（Supabase 远程执行完毕）
| 迁移文件 | 内容 | 状态 |
|----------|------|------|
| `schema_migration_01.sql` | `invitation_verified` 列 + 更新 `use_invitation_code()` RPC + 测试邀请码 | ✅ 已执行 |
| `schema_migration_02.sql` | Stripe 列（`stripe_customer_id`, `stripe_subscription_id`） | ✅ 已执行 |
| `schema_migration_03.sql` | 100 个一次性邀请码种子数据 | ✅ 已执行 |
| `schema_migration_04.sql` | 原子限额 RPC `check_and_increment_chat_quota()` | ✅ 已执行 |

#### 3. Worker 部署
- `checkAndIncrementChatQuota()` 从 read-then-write 改为原子 RPC 调用
- 已部署到 Cloudflare：`api.lingyuan.ai`（版本 `aba9a5e5`）

#### 4. Qwen 3.5 元素指向（核心功能）
**问题**: 切换到 Qwen 3.5 后蓝色光标不再飞向屏幕元素。Qwen 不可靠地遵循 `[POINT:x,y:label]` 文本标签格式。

**方案**: 通过 `qwen3_computer_use` 项目发现 Qwen 通过 OpenAI tool calling 可靠输出坐标。

**实现**:
- `OpenAICompatibleChatAPI.swift`: 新增 `ParsedToolCall` 结构体、`tools` 参数、SSE `tool_calls` delta 累积解析
- `CompanionManager.swift`: 定义 `point_at_element` 工具（0-1000 归一化坐标）、OpenAI 专用 system prompt、坐标转换、回退机制、空文本保护
- **curl 验证通过**: SiliconFlow + Qwen3.5-35B-A3B 正确返回 `tool_calls`

**双机制设计**:
```
Qwen 路径:  tools:[point_at_element] → tool_calls:{x,y,label} → 0-1000→AppKit坐标
Claude 路径: [POINT:x,y:label] text tag → 正则解析 → 像素→AppKit坐标（不变）
回退:        Qwen 输出 [POINT:] 文本标签 → 走 Claude 路径逻辑
```

#### 5. 文档更新
- `commercialization-plan.md`: Phase 2-5 标记为真实状态
- `AGENTS.md`: 双机制指向架构说明、新增 `OpenAICompatibleChatAPI.swift` 到 Key Files
- `e2e-verification-checklist.md`: 完整端到端验证清单

### Git 提交
```
683b047 chore: gitignore supabase/ local config directory
161e94d feat: Qwen element pointing via OpenAI tool calling
807682e fix: atomic chat quota RPC + schema sync + e2e checklist
2af1e2b chore: gitignore tool artifacts and remove tracked temp files
```

---

## 待验证（需 Xcode 环境）

### 优先级 1：Qwen 指向功能
- [ ] Xcode Cmd+R 构建运行
- [ ] 对屏幕说导航类问题（如"怎么提交代码"），观察光标是否飞向目标
- [ ] 说纯知识问题（如"什么是 HTML"），确认无指向
- [ ] Console.app 过滤 `🔧` 查看 Qwen tool call 日志
- [ ] Console.app 过滤 `🎯` 查看 Claude 指向日志（如切回 Claude 测试）

### 优先级 2：商业化链路
详见 `docs/e2e-verification-checklist.md`，涵盖：
- [ ] 注册 → 邮件确认 → 邀请码门禁 → 限额拦截 → 微信支付升级

---

## 下一阶段开发计划

### 近期（验证后）
1. **端到端验证** — 上述所有待验证项
2. **Qwen 指向调优** — 根据实测调整 tool description 措辞、坐标精度
3. **Apple IAP** — Phase 4 剩余：评估 RevenueCat vs StoreKit 2

### 中期
4. **用户中心扩展** — 个人资料编辑、周/月维度用量统计
5. **WhisperKit 模型管理** — 模型下载进度 UI、存储管理
6. **性能优化** — 截图压缩、SSE 首 token 延迟优化

### 长期
7. **App Store 上架** — 代码签名、沙盒适配、审核准备
8. **Stripe 国际支付** — 重新启用 Worker Stripe 路由

---

## 技术备忘

### SiliconFlow API Key
- 国内站 `api.siliconflow.cn`：API key 有效（直接测试用）
- 国际站 `api.siliconflow.com`：同一 key **无效**，Worker 使用独立的国际站 key（Cloudflare secret）

### Supabase CLI
- 已安装 v2.90.0，项目已链接（ref: `usymmyxhpfgpbgackhbm`）
- 非 TTY 环境需 `SUPABASE_ACCESS_TOKEN` 环境变量
- 执行 SQL：`export SUPABASE_ACCESS_TOKEN=xxx && supabase db query --linked < file.sql`

### Cloudflare Worker 部署
- 需 `CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID` 环境变量
- 账户 ID：`43c53e0513a4db803a6dddac2b295358`
