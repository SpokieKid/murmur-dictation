# 本地语音能力调研 — VibeVoice-ASR-BitNet 与 Inflect v2

_调研日期：2026-07-28。来源列在文末。已确认事实与推测分开标注。_

## 0. 一句话结论

**这次调整的收益不在"更快"，在"不再失败"。**

本地 ASR 的价值是把 Murmur 从"单点依赖网络"变成"三级降级链"；本地 TTS（Inflect v2）
对 Murmur 的边际价值很低，因为它给的东西 macOS 系统 TTS 白送，而且它不支持中文。

---

## 1. 两个项目的事实核查

### VibeVoice-ASR-BitNet（已确认）

| 项 | 值 |
|---|---|
| 发布方 / 时间 | Microsoft，2026-07-23 |
| Runtime | `microsoft/VibeASR.cpp`（ggml） |
| 模型 | HF `microsoft/VibeVoice-ASR-BitNet` |
| 体积 | 4.62 GB → **1.58 GB**（VAE INT8，LM 用 BitNet 风格 I2_S） |
| 性能 | Apple M4，3 线程，**RTF 0.52** |
| License | MIT |
| **关键限制** | **技术报告明确：当前实现只支持 offline / batch inference，不支持 streaming** |
| 成熟度 | 很新，VibeASR.cpp 仅数十 commit；官方 README 提示未经充分测试不建议商用 |

### Inflect v2（已确认 — 注意：不是微软）

截图里写的"Inflect 发布"容易被误读成大厂发布。实际是个人开源项目。

| 项 | 值 |
|---|---|
| 发布方 | Owen Song（个人开源），非 Microsoft |
| 项目 | `owenawsong/Inflect` |
| 模型 | `owensong/Inflect-Micro-v2`（9,356,513 参数 / 37.53 MB FP32）<br>`owensong/Inflect-Nano-v2`（3,966,721 参数 / 15.97 MB FP32） |
| 输出 | 24 kHz mono |
| 运行 | 本地 PyTorch 或 ONNX Runtime |
| License | Apache-2.0 |
| **关键限制** | **纯英文、固定男声、非 voice cloning、非流式** |

---

## 2. Murmur 现状：这次调整能治哪些病

以下每条都对应代码里能指出来的具体位置，不是泛泛而谈。

### A. 断网 / 弱网 = 用户白说一遍 ← **最大痛点**

- `Transcriber.requestTimeout = 25`（`Sources/Murmur/Transcriber.swift:45`）
- `send()` 失败后用 `.ephemeral` session 重试一次（`Transcriber.swift:52`）——
  这个 hack 存在本身就是网络脆弱性的证据：休眠/长闲置后连接池里的 socket 是死的
- `stallWatchdog` 120 秒兜底（`AppDelegate.swift:343`）
- 失败路径是 `notify(error)` 弹模态 alert（`AppDelegate.swift:250` → `:502`），
  **刚说完的那段话直接丢掉，只能重说**

**加本地 ASR 后**：`endDictation` 的 catch 分支不再弹窗，而是把手上那份 WAV 喂给本地引擎，
HUD 切成"离线转写中…"，字照样出来。体验从"白说了"变成"慢一点但有结果"。

### B. 内置共享 key 的配额会被用爆

- `Defaults.defaultAPIKey` 是随 App 分发的共享 key（`Defaults.swift:10`）
- `migrate()` 里的注释白纸黑字写着：
  _"The bundled key's free quota for qwen-flash is exhausted (403s)"_（`Defaults.swift:113`）

本地路径没有 key、没有配额、不会 403。DMG 发出去给别人用，不会因为共享 key 被用爆而变砖。

### C. 220 秒硬上限

- `maxRecordingSeconds()` 对 DashScope 返回 **220 秒**（`Defaults.swift:191`），
  因为 qwen3-asr-flash 同步端点的 10 MB base64 限制先于 5 分钟限制触发
- 到点会弹"⚠️ N 秒后自动停止录音"+ Funk 提示音（`AppDelegate.swift:288`）

本地路径走 `default` 分支返回 `0`（不限时）。开会记录、长口述、读整段文档可以一口气说完。
VibeASR 的官方定位就是长音频 offline batch，正好对上这个场景。

### D. 隐私

音频现在是 base64 塞进 JSON 发到 dashscope（`Transcriber.swift:126`）。本地路径音频不出机器。

可以进一步做成按前台 App 自动切换：在 1Password / 终端 / 公司代码库窗口前自动走本地。

### E. 延迟——必须诚实：本地在好网络下是**退步**

- VibeASR **不支持 streaming**（官方技术报告）
- 当前 realtime path 是边说边传（`AppDelegate.swift:171` / `:221`），松手后只等尾包
- RTF 0.52 意味着 20 秒音频 ≈ 10 秒转写，**再加进程冷启动**

所以：**本地 ASR 不能当默认**。它是 fallback、隐私模式、长录音模式。
唯一延迟占优的场景是坏网络——本地 10 秒出结果，好过网络等 25 秒超时后还是失败。

### F. 采样率不匹配

`AudioRecorder` 固定 16 kHz mono（`AudioRecorder.swift:15-17`），VibeASR 偏 24 kHz。
要么 wrapper 里重采样，要么给 `AudioRecorder` 加按 provider 切换采样率。

---

## 3. Inflect v2：诚实的否定判断

**结论：暂缓，性价比不够。**

理由：

1. Murmur 是中文优先的（HUD 文案、polish prompt 全是中文场景）。
   Inflect **纯英文固定男声**，朗读中文转写结果这条路直接走不通。
2. 它能念的英文短提示（"pasted" / "timed out" / "no speech"），
   macOS `AVSpeechSynthesizer` 白送——零依赖、零打包体积、中英通吃、系统级音色。
3. 换来的成本是：10–40 MB 模型 + Python/ONNX sidecar + 冷启动 + 分发体积。

**但"语音反馈"这个功能本身有真实价值，只是不该用 Inflect 实现：**

- 现在所有结果反馈都只在 HUD 上闪一下（`finishWorking(flash:)`，`AppDelegate.swift:321`）。
  按完热键人已经切回去盯代码了，"✓ 已粘贴" / "未检测到语音" / "转录超时" 往往是事后才发现的。
- 更值得做的一个：`voiceEdit`（`Defaults.swift:84`）现在是 LLM **静默地**把
  "把张三改成李四"应用掉，用户无法确认到底改没改。
  播报一句"已应用：张三 → 李四"，这个功能才真正可信。

这两个都需要中文 → `AVSpeechSynthesizer`，不是 Inflect。

---

## 4. 推荐优先级

| 优先级 | 事项 | 改动面 | 风险 |
|---|---|---|---|
| **P0** | 本地 ASR 作为降级链第三级（realtime → cloud batch → local） | `Transcriber.transcribe` 加 `providerVibeASRLocal` 分支；`AppDelegate.endDictation` catch 里加 fallback | 低（默认关闭，只在网络失败时触发） |
| **P1** | 长录音 / 隐私模式：`maxRecordingSeconds()` 按 provider 解绑 + "本地模式"开关 | `Defaults` + `SettingsView` ASR tab | 低 |
| **P2** | 语音反馈用 `AVSpeechSynthesizer`（**不是 Inflect**），只在异常路径 + voiceEdit 确认时发声 | 新增 `SpeechFeedback.swift`（~50 行） | 极低 |
| **P3** | Inflect v2 | — | 暂缓 |

### 最小可行集成（P0）

新增配置项：`providerVibeASRLocal`、`localVibeASRPath`、`localVibeASRModelDir`、`localVibeASRThreads`。

第一版用 `Process` 直接调 `vibeasr` CLI；第二版包成 localhost 的 OpenAI-compatible
`/audio/transcriptions`，这样能直接复用 `Transcriber.openAICompatible` 那条路径，
UI 和配置都不用动。

需要改的文件：
- `Sources/Murmur/Transcriber.swift` — 新 provider 分支
- `Sources/Murmur/Defaults.swift` — provider 常量、默认值、`maxRecordingSeconds()`
- `Sources/Murmur/AppDelegate.swift` — `endDictation` 的 fallback 逻辑、HUD 文案
- `Sources/Murmur/SettingsView.swift` — ASR tab 新增本地引擎配置
- `Sources/Murmur/AudioRecorder.swift` — 仅当决定原生出 24 kHz 时才改

---

## 5. 必须先量的数（决定架构，不是可选）

1. **VibeASR.cpp 在目标 mini-mac 上的冷启动耗时。**
   如果 > 3 秒，就必须做 launchd 常驻 daemon，而不是每次 `Process` 起一个。
   否则 fallback 触发的那一刻用户要等：25 秒网络超时 + 3 秒冷启动 + 15 秒转写 = 体验反而更差。
2. 30 秒中文 / 英文样本的 CER / WER，对比现有 qwen3-asr-flash。
3. 16 kHz WAV 能否直接喂，还是必须重采样到 24 kHz。
4. CPU 占用与内存峰值（1.58 GB 模型常驻的代价）。
5. 打包分发体积是否可接受（当前 DMG 很小，加 1.58 GB 模型是数量级变化 → 大概率要做首次启动按需下载）。

---

## 6. 风险

- **VibeVoice-ASR-BitNet 很新**，VibeASR.cpp 仅数十 commit，官方 README 明确提示
  未经充分测试不建议用于商业/真实应用。只适合做实验 provider，不适合当默认生产路径。
- **模型体积 1.58 GB** 与当前"小巧菜单栏 App"的定位冲突，必须走按需下载。
- **无 streaming** 是硬限制，短期内不会变。

---

## 来源

- https://github.com/microsoft/VibeVoice
- https://github.com/microsoft/VibeASR.cpp
- https://arxiv.org/html/2607.21075v1
- https://github.com/owenawsong/Inflect
- https://huggingface.co/owensong/Inflect-Micro-v2
- https://huggingface.co/owensong/Inflect-Nano-v2
