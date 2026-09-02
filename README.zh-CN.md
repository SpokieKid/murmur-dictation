# Murmur 🎙️

[English](README.md)

[![CI](https://github.com/SpokieKid/Murmur/actions/workflows/ci.yml/badge.svg)](https://github.com/SpokieKid/Murmur/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black.svg)](https://www.apple.com/macos/)

Murmur 是一款轻量的 macOS 菜单栏语音输入工具。按下快捷键说话，松开后由你配置的语音识别服务转成文字，并粘贴到当前光标位置。

项目完全开源、不绑定订阅，支持 OpenAI 兼容接口、Groq、本地 Whisper 服务和阿里云百炼 FunASR。

## 为什么做 Murmur

- **处理时也能继续说**：上一段正在转录或润色时，直接按 Fn 录下一段。多个任务并行执行，最后严格按照录音顺序粘贴。
- **电脑里的声音也能转文字**：可将麦克风和 Mac 正在播放的声音合并识别，适合 Zoom、Meet、Teams、飞书会议和浏览器视频。听歌时可从菜单栏一键关闭「收录电脑声音」。
- **堆叠任务浮窗**：每一段录音和转录都有独立卡片，并行任务的进度一目了然。
- **简体中文 / English**：可跟随系统语言，也可在应用内即时切换，无需重启。
- **自带服务**：由你填写 API Key、端点和模型，不锁定供应商。
- **语音自编辑**：直接说“删掉上一句”或“把张三改成李四”，润色模型会应用修改，而不是把修改命令原样输入。

## 快速开始

需要 macOS 13 或更高版本、Xcode 和 Swift 6 工具链。

```bash
git clone https://github.com/SpokieKid/Murmur.git
cd Murmur
SIGN_IDENTITY=- ./build.sh release
open build/Murmur.app
```

打开 **菜单栏 → 设置…**，选择语音识别服务并填写你自己的 API Key。

## macOS 权限

在菜单栏点击 **授予权限…**，根据需要开启：

| 权限 | 用途 |
|---|---|
| 麦克风 | 收录你的声音 |
| 辅助功能 | 将结果自动粘贴到光标位置 |
| 输入监控 | 在其他应用中识别全局触发键 |
| 屏幕与系统音频录制 | 收录线上会议对方或电脑正在播放的声音 |

Murmur 只处理音频，不保存屏幕画面。电脑声音仅在你主动开始听写且开启「收录电脑声音」时采集；Murmur 自己的提示音会被排除。

## 使用方式

1. 按触发键（默认右 Option，也可改为 Fn）开始听写。
2. 再按一次停止；也可在设置中切换为“按住说话”。
3. 转录处理中无需等待，可立刻继续录制下一段。
4. 结果即使完成顺序不同，也会按照录制顺序输入。
5. 按 Esc 可取消当前录音或最新的未交付任务。

## 电脑声音

在 **通用 → 会议与电脑声音** 中开启，首次使用时 macOS 会请求「屏幕与系统音频录制」权限。完成授权后，日常可直接使用菜单栏中的 **收录电脑声音** 快捷开关。

## 开发与测试

```bash
swift test
swift build -c release -Xswiftc -warnings-as-errors
SIGN_IDENTITY=- ./build.sh release
```

本地签名的构建可能需要重新授予 macOS 隐私权限。用于分发时，请使用自己的 Developer ID 签名并完成公证。

## 参与贡献

欢迎提交 Issue、翻译和 Pull Request。隐私与数据流说明见 [PRIVACY.md](PRIVACY.md)；参与贡献前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)、[SECURITY.md](SECURITY.md) 和 [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)。

## 许可证

[MIT License](LICENSE) © 2026 Arvin Chen and Murmur contributors.
