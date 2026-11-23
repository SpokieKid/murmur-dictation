# Murmur Windows

原生 WinForms 托盘客户端，.NET 10 自包含分发，目标为 Windows 10/11 x64。安装、使用说明见 [使用说明](使用说明.txt)。

## 实现范围

- WinMM 麦克风录音，16 kHz、单声道 PCM16；专用工作线程处理音频缓冲，原生回调仅入队和通知。
- DashScope Fun-ASR 实时识别与批量回退，或 OpenAI 兼容批量 ASR；可选文字整理、自定义词汇。
- 三种可选全局组合快捷键；录音浮窗；Esc 取消；单次录音上限 220 秒。
- 首次引导：设备和隐私检查、服务与快捷键、真实试说、完成。未成功试说不能标记引导完成。
- UI Automation 核验原输入框、内容和选择范围后粘贴；切换窗口、移动光标、控件不可核验或密码框时，结果只复制。与 macOS 版不同，本版本不会在后台向已切走的窗口回填。
- 自定义 API 密钥使用当前 Windows 用户 DPAPI 保护。录音和最近结果只保留在内存中，不持久保存历史。
- NSIS 当前用户安装、开始菜单入口与系统卸载登记；卸载保留用户配置。

首版不包含电脑声音混录、并行多段录音、按住说话模式、持久化历史或自动更新。公开安装包不含 API 密钥，首次使用需在设置中填写自己的语音服务密钥；文字整理可另行配置或关闭。

## 构建

准备 .NET 10 SDK 和 NSIS。在根目录执行：

```sh
Windows/build-installer.sh
```

支持在 macOS 交叉编译。`DOTNET_BIN` 可指定 SDK 的 dotnet 路径。默认构建公开包，只从 Windows 源码读取模型和提示词，生成空密钥配置，不读取 Mac 密钥。产物目录为 `build/windows/public/`。

产物：`build/windows/public/Murmur-0.6.0-Windows-x64-Setup.exe` 与 `.sha256`。自带运行时，无需用户安装 .NET。当前无 Authenticode 签名证书。

仅在已获得内部共享凭据分发授权时，可显式设置 `MURMUR_WINDOWS_BUILD_KIND=internal` 构建带本机 Swift 内置密钥的内部包，产物进入单独的 `build/windows/internal/`。内部包及生成配置均不可上传公开仓库或公开 Release。

## 验证

```sh
build/tools/dotnet/dotnet run --project Windows/Murmur.Core.Tests -c Release
# 显式启用真实接口测试，仅使用合成语音（可能消耗共享服务余额）
build/tools/dotnet/dotnet run --project Windows/Murmur.Core.Tests -c Release -- \
  --live /path/to/synthetic.wav /path/to/private-service-config.json
python3 Windows/verify-package.py
```

跨平台检查覆盖 WAV、协议解析、服务错误与恢复提示、整理失败保留原文、取消和凭据序列化。编译、安装包提取与接口检查不能代替 Windows 上的 WinMM、UI Automation、全局快捷键、实际安装和卸载验收。

包校验包含 CRC、提取程序与 publish 结果的哈希对照、内嵌运行时和程序集解压后的凭据检查。实机验收应逐项检查使用说明中的流程。模型服务的 `FreeTierOnly` 限制需要在对应账户中处理。
