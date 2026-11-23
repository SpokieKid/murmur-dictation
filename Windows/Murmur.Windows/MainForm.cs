using System.Diagnostics;
using System.Runtime.InteropServices;
using Murmur.Core;

namespace Murmur.Windows;

internal sealed class MainForm : Form
{
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool UnregisterHotKey(IntPtr window, int id);
    private static readonly string[] Shortcuts = ["Ctrl + Alt + Space", "Ctrl + Shift + Space", "Alt + Shift + Space"];
    private static readonly uint[] Modifiers = [3, 6, 5];
    private readonly AppConfig config;
    private readonly NotifyIcon tray;
    private readonly RecordingHud hud;
    private readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(180) };
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 100 };
    private readonly FlowLayoutPanel body = new() { Dock = DockStyle.Fill, AutoScroll = true, FlowDirection = FlowDirection.TopDown, WrapContents = false, Padding = new Padding(26) };
    private readonly FlowLayoutPanel navigation = new() { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, Padding = new Padding(24), BackColor = Color.FromArgb(237, 244, 255) };
    private WaveRecorder? recorder;
    private RealtimeSession? stream;
    private CancellationTokenSource? operation;
    private InputTarget? target;
    private enum State { Idle, Recording, Processing }
    private State state;
    private int stage, generation;
    private bool guide = true, quitting, shortcutReady, micChecked, trialPassed, recordingTrial, probeBusy;
    private string status = "", lastText = "", rawText = "";
    private Label? statusLabel;
    private ProgressBar? meter;
    private Button? trialButton, nextButton;
    private bool Busy => state != State.Idle || probeBusy;
    private string T(string zh, string en) => config.Language == "en" ? en : zh;
    private int ContentWidth => Math.Max(390, body.ClientSize.Width - body.Padding.Horizontal - 25);

    public MainForm(AppConfig config)
    {
        this.config = config;
        Text = "Murmur · Windows"; Font = new Font("Segoe UI", 10); AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(930, 690); MinimumSize = new Size(850, 650); StartPosition = FormStartPosition.CenterScreen;
        Icon = SystemIcons.Application;
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1 };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 215)); layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        layout.Controls.Add(navigation, 0, 0); layout.Controls.Add(body, 1, 0); Controls.Add(layout);
        var menu = new ContextMenuStrip();
        menu.Items.Add("开始 / 停止听写 · Dictate", null, (_, _) => Toggle());
        menu.Items.Add("新手引导与权限 · Setup", null, (_, _) => OpenGuide());
        menu.Items.Add("设置 · Settings", null, (_, _) => OpenSettings());
        menu.Items.Add("复制最近结果 · Copy last result", null, (_, _) => CopyLast());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("退出 · Quit", null, (_, _) => { quitting = true; Close(); });
        tray = new NotifyIcon { Icon = Icon, Text = "Murmur", Visible = true, ContextMenuStrip = menu };
        tray.DoubleClick += (_, _) => ShowWindow();
        hud = new RecordingHud(Cancel);
        timer.Tick += (_, _) => TickRecording(); timer.Start();
        Shown += (_, _) =>
        {
            DrawPage();
            if (config.SetupVersion >= 1 && config.IsConfigured && shortcutReady) { guide = false; Hide(); }
        };
        FormClosing += (_, e) =>
        {
            if (!quitting && e.CloseReason == CloseReason.UserClosing)
            {
                if (recordingTrial) Cancel();
                e.Cancel = true; Hide(); Balloon(T("Murmur 已留在系统托盘。", "Murmur is running in the system tray."));
            }
        };
        ResizeEnd += (_, _) => { if (!Busy) DrawPage(); };
        DrawPage();
    }

    protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); RegisterShortcut(); }
    protected override void WndProc(ref Message m)
    {
        if (m.Msg == 0x0312) { if (m.WParam.ToInt32() == 1) Toggle(); else if (m.WParam.ToInt32() == 2) Cancel(); }
        base.WndProc(ref m);
    }
    private void RegisterShortcut()
    {
        UnregisterHotKey(Handle, 1); config.Shortcut = Math.Clamp(config.Shortcut, 0, Shortcuts.Length - 1);
        shortcutReady = RegisterHotKey(Handle, 1, Modifiers[config.Shortcut] | 0x4000, 0x20);
    }
    public void ShowWindow() { if (Busy && !recordingTrial) return; Show(); if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal; Activate(); }
    private void OpenGuide() { if (Busy) { Balloon(T("请先结束当前录音或处理。", "Finish the current recording first.")); return; } guide = true; stage = 0; micChecked = false; trialPassed = false; DrawPage(); ShowWindow(); }
    private void OpenSettings() { if (Busy) return; guide = false; stage = 4; DrawPage(); ShowWindow(); }
    private void Balloon(string text) { tray.BalloonTipTitle = "Murmur"; tray.BalloonTipText = text; tray.ShowBalloonTip(5000); }

    private Label LabelText(string text, float size = 10, bool bold = false)
    {
        return new Label { Text = text, AutoSize = true, MaximumSize = new Size(ContentWidth, 0), Font = new Font("Segoe UI", size, bold ? FontStyle.Bold : FontStyle.Regular), Margin = new Padding(0, 0, 0, 16), ForeColor = Color.FromArgb(38, 46, 60) };
    }
    private Button ButtonText(string text, Action action, bool primary = false)
    {
        var button = new Button { Text = text, AutoSize = true, MinimumSize = new Size(135, 38), Padding = new Padding(10, 4, 10, 4), Margin = new Padding(0, 0, 10, 14), FlatStyle = FlatStyle.Flat, UseVisualStyleBackColor = !primary };
        if (primary) { button.BackColor = Color.FromArgb(25, 98, 211); button.ForeColor = Color.White; }
        button.Click += (_, _) => action(); return button;
    }
    private void Add(Control control) => body.Controls.Add(control);
    private void Title(string zh, string en, string zhBody, string enBody)
    { Add(LabelText(T(zh, en), 23, true)); Add(LabelText(T(zhBody, enBody))); }
    private void DrawPage()
    {
        body.SuspendLayout(); navigation.SuspendLayout();
        foreach (Control control in body.Controls.Cast<Control>().ToArray()) control.Dispose();
        foreach (Control control in navigation.Controls.Cast<Control>().ToArray()) control.Dispose();
        body.Controls.Clear(); navigation.Controls.Clear(); statusLabel = null; meter = null; trialButton = null; nextButton = null;
        navigation.Controls.Add(new Label { Text = "Murmur", AutoSize = true, Font = new Font("Segoe UI", 24, FontStyle.Bold), ForeColor = Color.FromArgb(25, 98, 211), Margin = new Padding(0, 0, 0, 30) });
        foreach (var item in new[] { ("1  权限与设备", "1  Permissions"), ("2  语音与快捷键", "2  Voice & shortcut"), ("3  首次试说", "3  Try a phrase"), ("4  准备完成", "4  Ready") }.Select((value, i) => (value, i)))
            navigation.Controls.Add(new Label { Text = T(item.value.Item1, item.value.Item2), AutoSize = true, MaximumSize = new Size(165, 0), Margin = new Padding(0, 0, 0, 24), ForeColor = stage == item.i ? Color.FromArgb(25, 98, 211) : Color.FromArgb(64, 75, 90), Font = new Font("Segoe UI", 11, stage == item.i ? FontStyle.Bold : FontStyle.Regular) });
        var language = ButtonText(config.Language == "en" ? "中文" : "English", () => { if (Busy) return; config.Language = config.Language == "en" ? "zh" : "en"; Save(); DrawPage(); });
        language.Enabled = !Busy; navigation.Controls.Add(language);
        var settingsButton = ButtonText(T("设置", "Settings"), OpenSettings); settingsButton.Enabled = !Busy; navigation.Controls.Add(settingsButton);
        if (stage == 0) DrawPermissions();
        else if (stage == 1) DrawService();
        else if (stage == 2) DrawTrial();
        else if (stage == 3) DrawDone();
        else DrawSettings();
        navigation.ResumeLayout(); body.ResumeLayout();
    }

    private void DrawPermissions()
    {
        Title("先让 Murmur 听到你", "Let Murmur hear you", "Windows 桌面应用需要麦克风访问权限。检查只在本机录音，不上传，也不保存音频。", "Windows needs microphone access for desktop apps. This check records locally without uploading or saving audio.");
        var devices = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = ContentWidth, Margin = new Padding(0, 0, 0, 16) };
        var inputs = WaveRecorder.Devices();
        foreach (var device in inputs) devices.Items.Add(device.Name);
        int selectedDevice = WaveRecorder.ResolveDevice(config.Microphone, config.MicrophoneName);
        devices.SelectedIndex = Math.Max(0, inputs.ToList().FindIndex(x => x.Id == selectedDevice));
        devices.SelectedIndexChanged += (_, _) => { config.Microphone = inputs[devices.SelectedIndex].Id; config.MicrophoneName = config.Microphone == -1 ? "" : inputs[devices.SelectedIndex].Name; micChecked = false; trialPassed = false; Save(); };
        devices.Enabled = !probeBusy; Add(devices);
        Add(LabelText(micChecked ? T("麦克风可访问 ✓", "Microphone is accessible ✓") : T("尚未检查麦克风", "Microphone not checked yet"), 12, true));
        var check = ButtonText(T("检查麦克风（1 秒）", "Check microphone (1 second)"), () => _ = ProbeMicrophone()); check.Enabled = !probeBusy; Add(check);
        Add(ButtonText(T("打开麦克风隐私设置", "Microphone privacy settings"), () => OpenUri("ms-settings:privacy-microphone")));
        Add(LabelText(T("若无法录音，请开启「麦克风访问权限」和「允许桌面应用访问麦克风」。Windows 不需要 macOS 的辅助功能或输入监控授权。", "If recording fails, enable Microphone access and Let desktop apps access your microphone. No macOS Accessibility or Input Monitoring permissions are needed.")));
        Add(LabelText(shortcutReady ? T("全局快捷键已注册：", "Global shortcut registered: ") + Shortcuts[config.Shortcut] : T("快捷键被其他软件占用，请在设置里更换。", "Shortcut is in use. Choose another in Settings.")));
        if (status.Length > 0) Add(LabelText(status));
        nextButton = ButtonText(T("继续", "Continue"), () => { stage = 1; DrawPage(); }, true); nextButton.Enabled = micChecked && shortcutReady && !probeBusy; Add(nextButton);
        Add(ButtonText(T("稍后设置，留在托盘", "Set up later"), Hide));
    }

    private async Task ProbeMicrophone()
    {
        if (Busy) return;
        probeBusy = true; status = T("正在检查…", "Checking…"); DrawPage();
        try
        {
            using var probe = new WaveRecorder(WaveRecorder.ResolveDevice(config.Microphone, config.MicrophoneName)); probe.Start(); await Task.Delay(1200);
            float peak = probe.Peak; byte[] audio = probe.Stop(); micChecked = audio.Length > 0;
            status = micChecked ? T(peak >= 0.006 ? "听到声音了，可以继续。" : "设备可用，目前没有检测到明显声音。试说时请靠近麦克风。", "Device is accessible. Speak clearly in the next step.") : T("没有收到音频，请检查设备和隐私设置。", "No audio received. Check your device and privacy settings.");
        }
        catch (Exception error) { status = error.Message; micChecked = false; }
        finally { probeBusy = false; if (!IsDisposed) DrawPage(); }
    }

    private void DrawService()
    {
        Title("用顺手的方式输入", "Make it feel like yours", "先在设置中填写自己的语音服务密钥，再确认快捷键并完成真实试说。", "Enter your own voice service API key in Settings, choose a shortcut, then try a real phrase.");
        Add(LabelText(config.IsConfigured ? T("配置已填写；下一步验证实际连接。", "Configuration is filled in; the next step checks the real service.") : T("请先在设置中填写有效服务地址、模型和密钥。", "Complete your voice service settings first."), 12, true));
        Add(LabelText(config.Model));
        var shortcuts = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = ContentWidth, Margin = new Padding(0, 0, 0, 18) };
        shortcuts.Items.AddRange(Shortcuts); shortcuts.SelectedIndex = config.Shortcut;
        shortcuts.SelectedIndexChanged += (_, _) => { config.Shortcut = shortcuts.SelectedIndex; RegisterShortcut(); Save(); DrawPage(); }; Add(shortcuts);
        if (!shortcutReady) Add(LabelText(T("此快捷键无法注册，请换一个。", "Could not register this shortcut. Choose another.")));
        Add(ButtonText(T("修改语音服务", "Edit voice settings"), OpenSettings));
        Add(LabelText(T("开始录音后，音频会发送至配置的识别服务。开启文字整理时，识别文本也会发送给配置的语言模型。", "Audio is sent to your speech provider while you record. If polish is enabled, transcripts are also sent to the configured language model.")));
        Add(ButtonText(T("上一步", "Back"), () => { stage = 0; DrawPage(); }));
        var next = ButtonText(T("开始试说", "Try a phrase"), () => { stage = 2; DrawPage(); }, true); next.Enabled = config.IsConfigured && shortcutReady; Add(next);
    }

    private void DrawTrial()
    {
        Title("试着说一句话", "Say your first phrase", "按快捷键或点击按钮开始，说完再按一次结束。这里显示真实结果，不填入其他应用。", "Use the shortcut or button to start, then again to finish. Real results appear here without being inserted into other apps.");
        Add(LabelText(T("“明天上午十点，我们一起聊聊这个新想法。”", "“Let's meet tomorrow at ten to talk about our new idea.”"), 16, true));
        Add(LabelText(Shortcuts[config.Shortcut]));
        meter = new ProgressBar { Width = ContentWidth, Height = 12, Maximum = 100, Margin = new Padding(0, 0, 0, 14) }; Add(meter);
        statusLabel = LabelText(status.Length == 0 ? T("准备好了。", "Ready when you are.") : status); Add(statusLabel);
        trialButton = ButtonText(state == State.Recording ? T("结束并识别", "Finish & recognize") : T("开始 / 再试一次", "Start / retry"), Toggle, true); trialButton.Enabled = state != State.Processing; Add(trialButton);
        var cancel = ButtonText(T("取消当前试说", "Cancel trial"), Cancel); cancel.Enabled = state != State.Idle; Add(cancel);
        if (lastText.Length > 0)
        {
            Add(LabelText(T("实际结果", "Actual result"), 12, true));
            Add(new TextBox { Text = lastText, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Width = ContentWidth, Height = 100, Margin = new Padding(0, 0, 0, 16) });
            if (rawText != lastText) Add(LabelText(T("原始识别：", "Raw transcript: ") + rawText));
        }
        var back = ButtonText(T("上一步", "Back"), () => { stage = 1; DrawPage(); }); back.Enabled = !Busy; Add(back);
        nextButton = ButtonText(T("完成引导", "Finish setup"), () => { if (!trialPassed || Busy) return; config.SetupVersion = 1; Save(); stage = 3; DrawPage(); }, true); nextButton.Enabled = trialPassed && !Busy; Add(nextButton);
    }

    private void DrawDone()
    {
        Title("准备好了，开口就行", "You're ready to speak", "Murmur 会留在系统托盘。关闭引导后，在常用应用里试一次。", "Murmur stays in your system tray. Close this guide, then try an input field in another app.");
        Add(LabelText(Shortcuts[config.Shortcut], 18, true));
        Add(LabelText(T("点击输入框 → 按快捷键开始说话 → 再按一次结束。", "Click an input field → press the shortcut → speak → press again to finish.")));
        Add(LabelText(T("处理时若切换窗口、移动光标或输入框无法确认，文字会复制到剪贴板。密码框不自动输入。管理员权限窗口可能无法回填，可手动粘贴。", "If you switch windows, move the caret or the field cannot be verified, the result is copied. Password fields are never auto-pasted into. Elevated apps may require manual paste.")));
        Add(LabelText(T("录音或处理时可按 Esc 取消；若 Esc 已被其他程序占用，请使用录音浮窗的取消按钮。托盘图标可重新打开引导和设置。", "Press Esc to cancel recording or processing. If Esc is unavailable, use the floating Cancel button. Reopen setup and settings from the tray.")));
        Add(ButtonText(T("开始使用 Murmur", "Start using Murmur"), () => { guide = false; Hide(); }, true));
    }

    private void DrawSettings()
    {
        Title("语音服务与偏好", "Voice settings", "设置保存在本机。自定义密钥使用当前 Windows 账户加密。", "Settings stay on this PC. Custom keys are encrypted for the current Windows user.");
        TextBox Field(string label, string value, bool secret = false, bool multiline = false)
        {
            Add(LabelText(label));
            var field = new TextBox { Text = value, Width = ContentWidth, UseSystemPasswordChar = secret, Multiline = multiline, Height = multiline ? 70 : 30, Margin = new Padding(0, 0, 0, 14) }; Add(field); return field;
        }
        var provider = new ComboBox { Width = ContentWidth, DropDownStyle = ComboBoxStyle.DropDownList, Margin = new Padding(0, 0, 0, 16) };
        provider.Items.AddRange(["DashScope", "OpenAI compatible"]); provider.SelectedIndex = config.Provider == "openai" ? 1 : 0; Add(provider);
        var endpoint = Field(T("识别服务地址", "ASR endpoint"), config.Endpoint);
        var model = Field(T("识别模型", "ASR model"), config.Model);
        var key = Field("ASR API Key", config.ApiKey, true);
        provider.SelectedIndexChanged += (_, _) => {
            key.Clear();
            endpoint.Text = provider.SelectedIndex == 1 ? "https://api.openai.com/v1/audio/transcriptions" : "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation";
            model.Text = provider.SelectedIndex == 1 ? "whisper-1" : "fun-asr-flash-2026-06-15";
        };
        var realtime = new CheckBox { Text = T("使用 DashScope 实时识别，失败后批量回退", "DashScope realtime ASR with batch fallback"), Checked = config.Realtime, AutoSize = true, Margin = new Padding(0, 0, 0, 16) }; Add(realtime);
        var polish = new CheckBox { Text = T("使用模型整理标点和口语", "Polish punctuation and fillers"), Checked = config.Polish, AutoSize = true, Margin = new Padding(0, 0, 0, 16) }; Add(polish);
        var llmEndpoint = Field(T("整理服务地址", "Polish endpoint"), config.LlmEndpoint);
        var llmModel = Field(T("整理模型", "Polish model"), config.LlmModel);
        var llmKey = Field("Polish API Key", config.LlmApiKey, true);
        var vocabulary = Field(T("自定义词汇（每行一个）", "Custom vocabulary (one term per line)"), config.Vocabulary, false, true);
        Add(ButtonText(T("保存并返回引导", "Save & return to setup"), () =>
        {
            var edited = config.Snapshot(); edited.Endpoint = endpoint.Text.Trim(); edited.ApiKey = key.Text.Trim(); edited.Model = model.Text.Trim();
            if (!edited.IsConfigured || (polish.Checked && (!AppConfig.ValidEndpoint(llmEndpoint.Text.Trim()) || string.IsNullOrWhiteSpace(llmKey.Text) || string.IsNullOrWhiteSpace(llmModel.Text))))
            { MessageBox.Show(T("请填写有效的 HTTPS 服务地址、模型和密钥。本机服务可以使用 HTTP localhost。", "Enter a valid HTTPS endpoint, model and API key. HTTP is allowed for localhost."), "Murmur"); return; }
            config.Provider = provider.SelectedIndex == 1 ? "openai" : "dashscope";
            config.Endpoint = edited.Endpoint; config.ApiKey = edited.ApiKey; config.Model = edited.Model;
            config.Realtime = realtime.Checked; config.Polish = polish.Checked;
            config.LlmEndpoint = llmEndpoint.Text.Trim(); config.LlmModel = llmModel.Text.Trim(); config.LlmApiKey = llmKey.Text.Trim(); config.Vocabulary = vocabulary.Text;
            trialPassed = false; config.SetupVersion = 0; Save(); guide = true; stage = micChecked ? 1 : 0; DrawPage();
        }, true));
        Add(ButtonText(T("返回新手引导", "Back to setup"), () => { guide = true; stage = micChecked ? 1 : 0; DrawPage(); }));
    }

    private async void Toggle()
    {
        if (probeBusy) return;
        if (state == State.Processing) { Balloon(T("正在识别，稍等一下。", "Transcription is in progress.")); return; }
        if (state == State.Recording) { await StopRecording(); return; }
        if (Visible && (stage != 2 || !guide)) { Balloon(T("请进入首次试说，或收起窗口后在输入框中使用快捷键。", "Use the trial page, or hide this window and focus an input field.")); return; }
        if (!config.IsConfigured || !shortcutReady) { OpenGuide(); return; }
        recordingTrial = Visible && guide && stage == 2;
        if (recordingTrial) { lastText = ""; rawText = ""; }
        target = recordingTrial ? null : NativeInput.Capture();
        generation++; operation = new CancellationTokenSource(); trialPassed = false;
        try
        {
            var captured = config.Snapshot();
            stream = captured.Realtime && captured.Provider == "dashscope" ? new RealtimeSession(captured.ApiKey, operation.Token) : null;
            recorder = new WaveRecorder(WaveRecorder.ResolveDevice(config.Microphone, config.MicrophoneName)); var activeStream = stream;
            recorder.OnChunk = data => activeStream?.Append(data);
            recorder.Start(); state = State.Recording;
            RegisterHotKey(Handle, 2, 0x4000, 0x1B);
            status = T("正在听… 说完后再次按快捷键。", "Listening… press the shortcut again to finish.");
            if (recordingTrial) DrawPage();
        }
        catch (Exception error) { Cancel(); status = error.Message; if (Visible) DrawPage(); else Balloon(error.Message); }
    }

    private async Task StopRecording()
    {
        if (state != State.Recording || recorder is null || operation is null) return;
        int id = generation; var cancel = operation; var activeStream = stream;
        bool trial = recordingTrial; var destination = target; var captured = config.Snapshot();
        try
        {
            float peak = recorder.Peak; double seconds = recorder.Seconds;
            byte[] pcm = recorder.Stop(); recorder.Dispose(); recorder = null;
            if (seconds < 0.4 || peak < 0.006) throw new InvalidOperationException(T("没听到完整语音，请靠近麦克风再试。", "No speech detected. Speak closer to the microphone and try again."));
            state = State.Processing; cancel.CancelAfter(TimeSpan.FromSeconds(180)); status = T("正在识别并整理…", "Recognizing and polishing…");
            if (trial) DrawPage(); else hud.UpdateStatus(status, 0);
            var speech = new SpeechClient(http);
            string? raw = activeStream is not null ? await activeStream.CompleteAsync(cancel.Token) : null;
            cancel.Token.ThrowIfCancellationRequested();
            raw = string.IsNullOrWhiteSpace(raw) ? await speech.TranscribeAsync(pcm, captured, cancel.Token) : raw;
            var result = await speech.PolishAsync(raw, captured, cancel.Token);
            cancel.Token.ThrowIfCancellationRequested(); if (id != generation) return;
            rawText = result.Raw; lastText = result.Text;
            status = result.PolishUnavailable ? T("识别成功；整理暂不可用，已保留原文。请检查整理模型和额度。", "Recognized; polish unavailable. The original text is preserved.") : T("识别成功。", "Speech recognized.");
            trialPassed = trial;
            if (!trial) await Deliver(destination, result.Text, result.PolishUnavailable, cancel.Token);
        }
        catch (OperationCanceledException) { if (id == generation) status = T("已取消或连接超时，请重试。", "Cancelled or timed out. Try again."); }
        catch (Exception error) { if (id == generation) { status = error.Message; if (!trial) Balloon(error.Message); } }
        finally
        {
            activeStream?.Dispose(); cancel.Dispose();
            if (id == generation)
            {
                recorder?.Dispose(); recorder = null; operation = null; stream = null; target = null;
                state = State.Idle; UnregisterHotKey(Handle, 2); hud.Hide(); tray.Text = "Murmur";
                if (trial && !IsDisposed) DrawPage();
            }
        }
    }

    private async Task Deliver(InputTarget? destination, string text, bool polishUnavailable, CancellationToken token)
    {
        IDataObject? previous = null;
        try { previous = Clipboard.GetDataObject(); } catch (ExternalException) { }
        for (int attempt = 0; ; attempt++)
        {
            token.ThrowIfCancellationRequested();
            try { Clipboard.SetText(text); break; }
            catch (ExternalException) when (attempt < 3) { await Task.Delay(80, token); }
        }
        uint sequence = NativeInput.GetClipboardSequenceNumber();
        bool pasted;
        try { token.ThrowIfCancellationRequested(); pasted = NativeInput.Paste(destination, token); }
        catch (OperationCanceledException)
        {
            try { if (previous is not null && NativeInput.GetClipboardSequenceNumber() == sequence) Clipboard.SetDataObject(previous, true); }
            catch (ExternalException) { }
            throw;
        }
        if (!pasted) Balloon(T("结果已复制。输入位置已改变或无法安全回填，请在目标位置按 Ctrl+V。", "Result copied. The original field changed or cannot be verified. Press Ctrl+V at your destination."));
        else if (polishUnavailable) Balloon(status);
        if (pasted && previous is not null) _ = RestoreClipboardLater(previous, sequence);
    }

    private static async Task RestoreClipboardLater(IDataObject previous, uint sequence)
    {
        await Task.Delay(1500);
        try { if (NativeInput.GetClipboardSequenceNumber() == sequence) Clipboard.SetDataObject(previous, true); }
        catch (ExternalException) { }
    }

    private void Cancel()
    {
        bool processing = state == State.Processing; generation++; operation?.Cancel(); stream?.Cancel();
        recorder?.Dispose(); recorder = null;
        if (!processing) { stream?.Dispose(); operation?.Dispose(); }
        stream = null; operation = null; target = null; state = State.Idle; trialPassed = false;
        status = T("已取消，没有发送结果。", "Cancelled. No result was inserted.");
        UnregisterHotKey(Handle, 2); hud.Hide(); tray.Text = "Murmur";
        if (Visible && stage == 2) DrawPage();
    }
    private void TickRecording()
    {
        if (state == State.Recording && recorder is not null)
        {
            float level = recorder.Level; double seconds = recorder.Seconds;
            if (recordingTrial) { if (meter is not null) meter.Value = Math.Clamp((int)(level * 100), 0, 100); }
            else hud.UpdateStatus(T("正在听", "Listening") + $"  {seconds:0}s / 220s", level);
            if (seconds >= 219.8) _ = StopRecording();
        }
    }
    private void CopyLast() { if (lastText.Length > 0) { try { Clipboard.SetText(lastText); } catch (ExternalException) { Balloon(T("剪贴板正忙，请重试。", "Clipboard is busy. Try again.")); } } }
    private void Save() { try { ConfigStore.Save(config); } catch (Exception error) { MessageBox.Show(error.Message, "Murmur settings"); } }
    private static void OpenUri(string uri) { try { Process.Start(new ProcessStartInfo(uri) { UseShellExecute = true }); } catch (Exception error) { MessageBox.Show(error.Message, "Murmur"); } }
    protected override void Dispose(bool disposing)
    {
        if (disposing && !IsDisposed)
        {
            generation++;
            operation?.Cancel(); stream?.Cancel(); recorder?.Dispose();
            UnregisterHotKey(Handle, 1); UnregisterHotKey(Handle, 2);
            timer.Dispose(); tray.Visible = false; tray.Dispose(); hud.Dispose(); http.Dispose();
        }
        base.Dispose(disposing);
    }
}
