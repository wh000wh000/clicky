# SiliconFlow 模型生态调研

> 调研日期：2026-04-12
> 目的：为 Clicky 生产环境（Proxy 模式）选定 SiliconFlow 模型替代方案

---

## 背景

Clicky 当前的 Proxy 模式（Cloudflare Worker）硬编码转发到三个上游：

| 功能 | 当前上游 | API Key |
|------|---------|---------|
| Chat（含截图分析） | Anthropic Claude | `ANTHROPIC_API_KEY` |
| TTS 语音合成 | ElevenLabs | `ELEVENLABS_API_KEY` |
| STT 语音识别 | AssemblyAI（实时流式 WebSocket） | `ASSEMBLYAI_API_KEY` |

**目标：全部替换为 SiliconFlow 统一平台，一个 API Key 覆盖所有能力。**

---

## 一、Chat 模型（多模态/视觉）

### Clicky 需求

- 接收屏幕截图（base64 JPEG）+ 用户文本 prompt
- 支持多轮对话
- 流式 SSE 输出
- 支持 `[POINT:x,y:label:screenN]` 元素定位标签（通过 system prompt 引导）

### Qwen 3.5 系列（推荐 — 统一多模态）

Qwen 3.5 于 2026 年 2 月发布，采用**统一视觉-语言基础架构**，在数万亿多模态 token 上进行了早期融合训练。不需要单独的 VL 变体，基础模型本身即支持图像理解。

| 模型 ID | 参数量 | 类型 | 多模态 | 适用场景 |
|---------|--------|------|--------|---------|
| `Qwen/Qwen3.5-397B-A17B` | 397B (激活 17B) | MoE | ✅ 视觉 | 旗舰，质量最高，成本最高 |
| `Qwen/Qwen3.5-122B-A10B` | 122B (激活 10B) | MoE | ✅ 视觉 | 中杯，性价比推荐 |
| `Qwen/Qwen3.5-35B-A3B` | 35B (激活 3B) | MoE | ✅ 视觉 | 轻量，响应快，适合日常 |
| `Qwen/Qwen3.5-27B` | 27B | Dense | ✅ 视觉 | 稠密架构，稳定性好 |

**API 格式：** OpenAI-compatible（`/v1/chat/completions`），支持 `image_url` 类型的 content block。

**建议：** Worker 默认使用 `Qwen/Qwen3.5-122B-A10B`（性价比），客户端可在请求 body 中指定 model，Worker 只做转发不覆盖。用户可在面板中选择不同模型体验。

### 其他备选（仅供参考）

| 模型系列 | 视觉 | 音频 | 视频 | 备注 |
|---------|------|------|------|------|
| Qwen3-Omni-30B-A3B | ✅ | ✅ | ✅ | 全模态，可做 STT 替代方案 |
| Qwen3-VL-235B-A22B | ✅ | ❌ | ✅ | 专门视觉模型，OpenRouter 图像处理排名 #1 |
| Qwen3-VL-8B | ✅ | ❌ | ✅ | 小型 VL，成本极低 |
| Kimi-K2.5 | ✅ | ❌ | ❌ | 1T MoE，竞品参考 |

---

## 二、TTS 语音合成（替代 ElevenLabs）

### Clicky 需求

- 将 Claude/Qwen 的文本回复转为语音
- 低延迟流式输出
- 自然表现力（用于伴侣型语音助手场景）
- OpenAI-compatible API 格式（客户端 `OpenAICompatibleTTSClient.swift` 已支持）

### 可用模型

| 模型 ID | 特点 | 语言 | 流式 | 推荐度 |
|---------|------|------|------|--------|
| `FunAudioLLM/CosyVoice2-0.5B` | 跨语言、情感控制、声音克隆 | 中/英/日/韩/粤语等方言 | ✅ | ⭐⭐⭐⭐⭐ |
| `fnlp/MOSS-TTSD-v0.5` | 双人对话合成、声音克隆 | 中/英 | ✅ | ⭐⭐⭐ |

### CosyVoice2-0.5B 详情（推荐）

**API 端点：** `POST /v1/audio/speech`（OpenAI-compatible）

**系统预置音色（8 种）：**
- 男声：`alex`（沉稳）、`benjamin`（低沉）、`charles`（磁性）、`david`（欢快）
- 女声：`anna`（沉稳）、`bella`（激情）、`claire`（温柔）、`diana`（欢快）

**使用方式：** voice 参数格式为 `FunAudioLLM/CosyVoice2-0.5B:alex`

**输出格式：** mp3、opus、wav、pcm

**高级功能：**
- 情感控制：通过 input 文本中的标签控制，如 `你能用高兴的情感说吗？<|endofprompt|>今天真开心！`
- 语速控制：`speed` 参数，范围 0.25–4.0
- 音量控制：`gain` 参数，-10 到 +10 dB
- 自定义声音克隆：上传参考音频（8-10 秒）创建自定义音色

**计费：** 按输入文本的 UTF-8 字节数计费

**对比 ElevenLabs：**
| 维度 | ElevenLabs | CosyVoice2-0.5B |
|------|-----------|-----------------|
| 中文质量 | 一般 | 优秀（原生中文支持） |
| 英文质量 | 优秀 | 良好 |
| 方言支持 | 无 | 粤语、四川话等 |
| 价格 | 较高 | 较低 |
| API 兼容 | 自有格式 | OpenAI-compatible |

---

## 三、STT 语音识别（替代 AssemblyAI）

### Clicky 需求

- Push-to-talk：按住快捷键录音，松开后获取转写文本
- 当前方案：AssemblyAI 实时流式 WebSocket（`u3-rt-pro` 模型）
- 延迟敏感：用户期望松开按键后立即看到文本

### SiliconFlow 可用 STT 模型

| 模型 ID | 类型 | 特点 |
|---------|------|------|
| `FunAudioLLM/SenseVoiceSmall` | 上传式 | 多语言识别，文件上传后返回文本 |
| `TeleAI/TeleSpeechASR` | 上传式 | 电信场景优化 |

**API 端点：** `POST /v1/audio/transcriptions`（multipart/form-data 上传音频文件）

**限制：**
- ❌ **不支持实时流式 WebSocket** — 这是与 AssemblyAI 最大的差异
- 文件限制：时长 ≤ 1 小时，大小 ≤ 50MB
- 仅支持上传完整音频文件后返回转写结果

### 替代方案评估

| 方案 | 延迟 | 成本 | 统一性 | 质量 | 推荐度 |
|------|------|------|--------|------|--------|
| **A. SiliconFlow 上传式 STT** | 中（录完后上传+处理） | 低 | ✅ 统一 key | 良好 | ⭐⭐⭐⭐ |
| **B. Apple Speech 本地** | 低（实时本地） | 免费 | ✅ 无需 key | 中等 | ⭐⭐⭐ |
| **C. Qwen3-Omni 音频输入** | 中 | 较高 | ✅ 统一 key | 良好 | ⭐⭐⭐ |
| **D. 保留 AssemblyAI** | 极低（实时流式） | 较高 | ❌ 额外 key | 优秀 | ⭐⭐⭐ |

### 方案详解

**方案 A：SiliconFlow 上传式 STT（推荐）**
- 改造点：录音期间在本地缓冲 PCM 音频，松开按键后打包为 WAV 上传到 Worker
- Worker 新增 `/transcribe` 路由，转发到 `POST /v1/audio/transcriptions`
- 延迟估算：上传 5 秒录音（~80KB WAV）+ SenseVoice 处理 ≈ 1-2 秒总延迟
- 优势：统一一个 SiliconFlow key，架构最简
- 客户端已有 `OpenAIAudioTranscriptionProvider.swift` 支持此模式

**方案 B：Apple Speech 本地转写**
- 完全本地，零网络延迟，零成本
- 客户端已有 `AppleSpeechTranscriptionProvider.swift`
- 但中文识别质量不如专业 ASR 模型
- 适合作为离线 fallback

**方案 C：Qwen3-Omni 音频理解**
- 将录音作为 `audio_url` 发送给 Qwen3-Omni-30B-A3B
- 模型直接理解音频内容，跳过 STT 步骤
- 但 token 成本较高（音频每秒 ~13 token）
- 架构变化较大，暂不推荐

**方案 D：保留 AssemblyAI**
- 维持实时流式最佳体验
- 但需要额外的 API key，不符合"统一 SiliconFlow"目标
- 可作为 premium 套餐的差异化特性

### STT 建议

**生产环境默认：方案 A（SiliconFlow SenseVoice 上传式）**
- 统一 API key，架构简单
- 客户端已有上传式转写的基础代码
- 1-2 秒延迟对 push-to-talk 场景可接受

**备选：方案 B（Apple Speech）作为离线 fallback / 免费套餐方案**

---

## 四、国内站 vs 海外站对比

| 维度 | 国内站 (siliconflow.cn) | 海外站 (siliconflow.com) |
|------|------------------------|------------------------|
| API 地址 | `api.siliconflow.cn/v1` | `api.siliconflow.com/v1` |
| Chat 模型 | Qwen3.5、Qwen3-Omni、Qwen3-VL、DeepSeek-V3、GLM 等 | 较少，Qwen2-VL、DeepseekVL2 |
| Vision 模型 | Qwen3.5（统一多模态）、Qwen3-VL 全系 | 仅 Qwen2-VL-72B、deepseek-vl2 |
| TTS | CosyVoice2-0.5B、MOSS-TTSD-v0.5 | fishaudio/fish-speech-1.5、CosyVoice2-0.5B |
| STT | SenseVoiceSmall、TeleSpeechASR | SenseVoiceSmall、TeleSpeechASR |
| 实名认证 | 需要（使用自定义音色等功能） | 不需要 |
| 计费货币 | CNY | USD |

**结论：国内站模型更丰富（尤其是 Qwen3.5 全系），推荐 Worker 代理到国内站 API。**

海外站适合海外用户部署场景，但当前 Qwen3.5 和 Qwen3-VL 等最新模型尚未完全同步。

---

## 五、Worker 改造方案

### 新的 Secret / Env 变量

| 变量 | 值 | 说明 |
|------|-----|------|
| `SILICONFLOW_API_KEY` | `sk-...` | SiliconFlow API Key（替代 3 个独立 key） |
| `SILICONFLOW_BASE_URL` | `https://api.siliconflow.cn/v1` | API 基地址（默认国内站） |
| `SUPABASE_URL` | 已配置 | Supabase JWT 验证 |
| `DEFAULT_CHAT_MODEL` | `Qwen/Qwen3.5-122B-A10B` | 默认 chat 模型（可选 env 配置） |
| `DEFAULT_TTS_MODEL` | `FunAudioLLM/CosyVoice2-0.5B` | 默认 TTS 模型 |
| `DEFAULT_TTS_VOICE` | `FunAudioLLM/CosyVoice2-0.5B:alex` | 默认音色 |

### 路由改造

| 路由 | 改造前 | 改造后 |
|------|--------|--------|
| `POST /chat` | 转发 Anthropic（x-api-key header） | 转发 SiliconFlow `/v1/chat/completions`（Bearer token） |
| `POST /tts` | 转发 ElevenLabs（xi-api-key header） | 转发 SiliconFlow `/v1/audio/speech`（Bearer token） |
| `POST /transcribe-token` | 获取 AssemblyAI WebSocket token | **废弃**，改为 `POST /transcribe` 上传式 |
| `POST /transcribe`（新） | — | 转发 SiliconFlow `/v1/audio/transcriptions`（Bearer token） |

### Chat 格式转换

客户端在 proxy 模式下需要发送 OpenAI-compatible 格式（不再是 Anthropic 格式）：

```
// 客户端 → Worker（OpenAI format）
{
  "model": "Qwen/Qwen3.5-122B-A10B",
  "messages": [
    {
      "role": "user",
      "content": [
        { "type": "image_url", "image_url": { "url": "data:image/jpeg;base64,..." } },
        { "type": "text", "text": "用户 prompt" }
      ]
    }
  ],
  "stream": true
}

// Worker → SiliconFlow（直接转发，加 Auth header）
```

**关键决策：** 客户端在 proxy 模式下也使用 OpenAI-compatible 格式发送请求，Worker 只做鉴权 + 转发 + header 替换，不做格式转换。这意味着 proxy 模式的 Chat 需要走 `OpenAICompatibleChatAPI`（客户端已有）。

---

## 六、客户端改造要点

1. **Proxy 模式 Chat API**：从 `ClaudeAPI` 切换到 `OpenAICompatibleChatAPI`
2. **Proxy 模式 TTS**：从 `ElevenLabsTTSClient` 切换到 `OpenAICompatibleTTSClient`
3. **Proxy 模式 STT**：从 `AssemblyAI 实时流式` 切换到上传式转写（复用 `OpenAIAudioTranscriptionProvider` 逻辑）
4. **模型选择器**：面板中的模型选项改为 Qwen 3.5 系列（已有 preset）

---

## 参考资料

- [SiliconFlow 国内站文档](https://docs.siliconflow.cn)
- [SiliconFlow 海外站文档](https://docs.siliconflow.com)
- [Qwen3.5 GitHub](https://github.com/QwenLM/Qwen3.5)
- [Qwen3-VL on SiliconFlow Blog](https://www.siliconflow.com/blog/qwen3-vl-on-siliconflow-next-gen-vlm-with-better-world-understanding)
- [SiliconFlow 模型广场](https://cloud.siliconflow.cn/models)
