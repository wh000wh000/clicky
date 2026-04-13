# 实时语音转文字（STT）方案调研

> 调研日期：2026-04-12
> 目的：为 Clicky 选定替代 AssemblyAI 的 STT 方案

---

## 背景

Clicky 当前使用 AssemblyAI 实时流式 WebSocket（`u3-rt-pro` 模型），体验很好但存在两个问题：

1. **国内可用性存疑** — AssemblyAI 没有中国区数据中心，从国内访问延迟高且不稳定
2. **额外 API Key** — 不符合"统一 SiliconFlow 一个 key"的架构目标

用户提出的核心观察：**飞书、微信等产品的录音转写已经非常成熟，应该有现成的方案可以直接用。**

---

## 方案总览

| 方案 | 类型 | 实时流式 | 中英双语 | 延迟 | 成本 | macOS 友好度 | 推荐度 |
|------|------|---------|---------|------|------|-------------|--------|
| **WhisperKit** | 本地 Swift 包 | ✅ | ✅ | **0.46s** | 免费 | ⭐⭐⭐⭐⭐ | **🏆 强烈推荐** |
| Apple Speech | 本地系统 API | ✅ | ✅ | ~0.3s | 免费 | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ |
| 阿里云 ISI | 云端 WebSocket | ✅ | ✅ | ~0.3s | 按量 | ⭐⭐⭐ | ⭐⭐⭐⭐ |
| 腾讯云 ASR | 云端 WebSocket | ✅ | ✅ | ~0.2s | 按量 | ⭐⭐⭐ | ⭐⭐⭐⭐ |
| SiliconFlow SenseVoice | 云端上传式 | ❌ | ✅ | ~1-2s | 按量 | ⭐⭐⭐ | ⭐⭐⭐ |
| FunASR（本地） | 本地 Python/C++ | ✅ | ✅(中文为主) | ~0.5s | 免费 | ⭐⭐ | ⭐⭐⭐ |
| AssemblyAI | 云端 WebSocket | ✅ | ⚠️(英文为主) | ~0.15s | 按量 | ⭐⭐⭐⭐ | ⭐⭐(国内) |
| Deepgram | 云端 WebSocket | ✅ | ⚠️ | ~0.15s | 按量 | ⭐⭐⭐⭐ | ⭐⭐(国内) |

---

## 一、WhisperKit（🏆 强烈推荐）

### 为什么这是最佳方案

WhisperKit 是 [Argmax](https://www.argmaxinc.com) 开发的 **原生 Swift Package**，将 OpenAI Whisper 模型编译为 CoreML 格式，直接在 Apple Neural Engine 上运行。**Apple 官方已认可 WhisperKit**（SpeechAnalyzer 合作项目）。

**这正是"飞书、微信那种成熟的转写体验"在 macOS 原生端的最佳实现。**

### 性能基准（2026）

| 指标 | WhisperKit（本地） | OpenAI gpt-4o-transcribe（云端） | Deepgram nova-3（云端） |
|------|-------------------|-------------------------------|----------------------|
| **延迟** | **0.46s** ✅ 最低 | 更高 | 更高 |
| **词错误率（WER）** | **2.2%** ✅ 最低 | 更高 | 更高 |

WhisperKit 在延迟和准确率上**同时超越了主流云端服务**，而且完全在设备端运行。

### 核心特性

- ✅ **原生 Swift Package** — 通过 SPM 直接添加，无需桥接
- ✅ **实时流式转写** — 修改版音频编码器支持流式推理，不用等录音结束
- ✅ **Apple Neural Engine 加速** — M1/M2/M3/M4 全系优化，能效比极高
- ✅ **多语言支持** — 基于 Whisper，原生支持中英日韩等 99 种语言
- ✅ **中英混合** — Whisper 对 code-switching（中英混说）支持良好
- ✅ **完全离线** — 零网络依赖，零 API 成本，零隐私顾虑
- ✅ **异步 API** — 后台线程转写，UI 不卡
- ✅ **macOS + SwiftUI** — 官方示例和社区教程丰富

### 集成方式

```swift
// Package.swift 或 Xcode SPM
.package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0")
```

核心流程：
1. 初始化时下载/加载 Whisper 模型（一次性，约 50-150MB）
2. Push-to-talk 开始 → 开启实时音频流
3. WhisperKit 边收音频边输出转写文本
4. 松开按键 → 获取最终文本

### 与 Clicky 现有架构的契合度

| 维度 | WhisperKit | AssemblyAI（当前） |
|------|-----------|------------------|
| 协议 | 本地 Swift API | WebSocket 到云端 |
| Provider 模式 | 新建 `WhisperKitTranscriptionProvider` | `AssemblyAIStreamingTranscriptionProvider` |
| 音频格式 | PCM（已有 `AVAudioEngine` 管线） | PCM → WebSocket |
| Worker 依赖 | 无（不走 Worker） | 需要 `/transcribe-token` 路由 |
| API Key | 无 | `ASSEMBLYAI_API_KEY` |

**改造量小：** 只需新建一个 `WhisperKitTranscriptionProvider` 实现 `BuddyTranscriptionProvider` 协议，复用现有的 `AVAudioEngine` 音频管线。

### 模型选择建议

| 模型 | 大小 | 速度 | 质量 | 推荐场景 |
|------|------|------|------|---------|
| `whisper-large-v3-turbo` | ~800MB | 快 | 优秀 | **推荐默认** |
| `whisper-large-v3` | ~1.5GB | 中 | 最佳 | 高精度场景 |
| `whisper-base` | ~50MB | 极快 | 一般 | 存储受限 |

### 参考资料

- [WhisperKit GitHub](https://github.com/argmaxinc/WhisperKit)
- [WhisperKit arXiv 论文](https://arxiv.org/html/2507.10860v1)
- [WhisperKit on macOS: Integrating On-Device ML in SwiftUI](https://www.helrabelo.dev/blog/whisperkit-on-macos-integrating-on-device-ml)
- [Apple SpeechAnalyzer x Argmax](https://www.argmaxinc.com/blog/apple-and-argmax)
- [Swift Package Index](https://swiftpackageindex.com/argmaxinc/WhisperKit)

---

## 二、Apple Speech（内置 fallback）

### 概述

macOS 内置的 `SFSpeechRecognizer`，Clicky 已有 `AppleSpeechTranscriptionProvider.swift` 实现。

### 优势

- 零成本，零集成工作（已有代码）
- 实时流式，延迟极低
- macOS 14+ 中文识别质量有显著提升

### 劣势

- 中英混合识别质量不如 Whisper
- 需要网络连接才能获得最佳质量（离线模式质量下降）
- 无法自定义模型

### 建议

保留为 **fallback 方案**：当 WhisperKit 模型未下载完成时自动降级。

---

## 三、国内云厂商实时 STT

### 阿里云智能语音交互（ISI）

- **协议**：WebSocket 流式
- **中文质量**：优秀（阿里 DAMO 语音团队，同 FunASR 班底）
- **定价**：按量计费 + 资源包，有免费额度
- **接入**：WebSocket 协议，macOS 通过 `URLSessionWebSocketTask` 直接对接
- [官方文档](https://help.aliyun.com/zh/isi/developer-reference/websocket)

### 腾讯云实时语音识别

- **协议**：WebSocket 流式
- **响应速度**：业界评测排名第一
- **定价**：按量 + 资源包 + 按并发数，有月度免费额度
- **接入**：WebSocket 协议
- [官方文档](https://cloud.tencent.com/document/product/1093/48982)

### 科大讯飞

- **协议**：WebSocket 流式
- **语音技术积累**：国内最深（20+ 年）
- **音频要求**：16kHz/16bit/PCM，200ms 分片
- **适合场景**：中文为主的高精度场景

### 云厂商方案评估

| 维度 | 优势 | 劣势 |
|------|------|------|
| 质量 | 中文识别质量高，成熟稳定 | 英文可能不如 Whisper |
| 延迟 | 低（国内机房） | 需要网络 |
| 成本 | 有免费额度，按量计费合理 | 长期运营有成本 |
| 集成 | WebSocket 标准协议 | 需要额外的 API Key 管理 |
| 架构 | 需要 Worker 代理或客户端直连 | 增加系统复杂度 |

**结论：** 如果 WhisperKit 本地方案不满足需求（比如需要更高的中文识别精度），阿里云/腾讯云是最佳云端补充方案。但引入额外的云厂商 API Key 增加了架构复杂度。

---

## 四、FunASR（本地开源）

阿里达摩院开源的语音识别工具包，`paraformer-zh` 模型在中文 ASR 上表现优异。

### 优势
- 开源免费，中文识别效果极好
- 支持实时流式
- 有 ONNX Runtime 部署方案

### 劣势
- **主要面向 Linux/Docker**，macOS 原生支持弱
- Python/C++ 生态，不是 Swift 原生
- 集成到 macOS app 需要额外桥接工作
- 模型主要优化中文，英文支持较弱

### 结论
技术上很强，但 macOS Swift 应用的集成成本太高。WhisperKit 是更合适的本地方案。

---

## 五、AssemblyAI（现有方案评估）

### 国内可用性

- ❌ **无中国区数据中心**
- ❌ **无官方中国区可用性说明**
- ⚠️ 从国内访问需要翻墙或走国际线路，延迟不可控
- ⚠️ 数据出境合规风险

### 结论

AssemblyAI 在英文实时转写领域是最好的（150ms 延迟），但**不适合面向国内用户的生产环境**。

---

## 六、最终推荐

### 推荐方案：WhisperKit（本地） + Apple Speech（fallback）

```
用户说话 → AVAudioEngine 采集 PCM
         → WhisperKit 实时流式转写（Apple Neural Engine）
         → 转写文本 + 截图 → 发给 Qwen 3.5
```

#### 理由

1. **延迟最低（0.46s）**，甚至超过云端服务
2. **准确率最高（WER 2.2%）**
3. **零 API 成本，零网络依赖** — 完美契合商业模式（不消耗我们的 API 额度）
4. **原生 Swift Package** — 集成简单，与 Clicky 现有架构完美契合
5. **中英混合支持好** — Whisper 模型天然支持多语言 code-switching
6. **Apple 官方认可** — 长期维护有保障
7. **隐私友好** — 语音数据不出设备
8. **Worker 无需新增 STT 路由** — 架构更简

#### 改造计划

1. 添加 WhisperKit SPM 依赖
2. 新建 `WhisperKitTranscriptionProvider.swift` 实现 `BuddyTranscriptionProvider` 协议
3. 首次启动时异步下载 Whisper 模型（~800MB，一次性）
4. 模型下载完成前使用 Apple Speech 作为 fallback
5. Worker 删除 `/transcribe-token` 路由（不再需要）
6. `APIConfiguration` 中 STT provider 新增 `whisperKit` 选项

#### 对 Worker 的影响

- **删除** `ASSEMBLYAI_API_KEY` secret
- **删除** `/transcribe-token` 路由
- STT 完全在客户端本地完成，Worker 不参与

---

## 参考资料汇总

### WhisperKit / Whisper
- [WhisperKit GitHub](https://github.com/argmaxinc/WhisperKit)
- [WhisperKit arXiv 论文](https://arxiv.org/html/2507.10860v1)
- [whisper.cpp GitHub](https://github.com/ggml-org/whisper.cpp)

### 国内云厂商
- [腾讯云实时语音识别](https://cloud.tencent.com/document/product/1093/48982)
- [阿里云智能语音交互 WebSocket](https://help.aliyun.com/zh/isi/developer-reference/websocket)
- [FunASR GitHub](https://github.com/modelscope/FunASR)

### 海外云服务
- [AssemblyAI Streaming STT](https://www.assemblyai.com/products/streaming-speech-to-text)
- [Deepgram Nova-2](https://deepgram.com)
- [Soniox](https://soniox.com/)

### 综合评测
- [Top APIs for Real-Time Speech Recognition 2026 — AssemblyAI](https://www.assemblyai.com/blog/best-api-models-for-real-time-speech-recognition-and-transcription)
- [Best Open Source STT Model 2026 — Northflank](https://northflank.com/blog/best-open-source-speech-to-text-stt-model-in-2026-benchmarks)
