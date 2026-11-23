using System.Net;
using System.Text;
using System.Text.Json;
using Murmur.Core;

int passed = 0;
void Check(bool condition, string name) { if (!condition) throw new Exception("FAILED: " + name); passed++; Console.WriteLine("PASS " + name); }
void Throws(Action action, string name) { try { action(); } catch (InvalidDataException) { Check(true, name); return; } throw new Exception("FAILED: " + name); }
byte[] pcm = new byte[6400];
for (int i = 0; i < pcm.Length; i += 2) BitConverter.GetBytes((short)(Math.Sin(i / 20.0) * 12000)).CopyTo(pcm, i);
byte[] wav = WaveData.Encode(pcm);
Check(wav.Length == pcm.Length + 44, "WAV length");
Check(BitConverter.ToInt32(wav, 24) == 16000 && BitConverter.ToInt16(wav, 22) == 1, "Mono 16 kHz");
Check(BitConverter.ToInt32(wav, 4) == wav.Length - 8, "RIFF size");
Check(WaveData.ReadPcm(wav).SequenceEqual(pcm), "PCM roundtrip");
Throws(() => WaveData.ReadPcm([1, 2, 3]), "Reject malformed WAV");
byte[] truncated = wav[..^2]; Throws(() => WaveData.ReadPcm(truncated), "Reject truncated chunk");
byte[] stereo = (byte[])wav.Clone(); stereo[22] = 2; Throws(() => WaveData.ReadPcm(stereo), "Reject stereo fixture");
Check(AppConfig.ValidEndpoint("https://example.com/asr"), "HTTPS endpoint");
Check(AppConfig.ValidEndpoint("http://localhost:8000/asr"), "Local server allowed");
Check(!AppConfig.ValidEndpoint("http://example.com/asr") && !AppConfig.ValidEndpoint("file:///secret"), "Reject plaintext remote/file endpoints");
var config = new AppConfig { ApiKey = "test-secret", LlmApiKey = "polish-secret" };
Check(config.IsConfigured, "Configured ASR");
Check(!new AppConfig().IsConfigured, "Empty key blocks setup");
Check(!JsonSerializer.Serialize(config).Contains("test-secret") && !JsonSerializer.Serialize(config).Contains("polish-secret"), "Settings model never serializes credentials");
var snapshot = config.Snapshot(); config.Model = "changed"; Check(snapshot.Model != config.Model, "Capture immutable settings snapshot");
Check(SpeechClient.ParseTranscript("{\"text\":\"Hello\"}") == "Hello", "OpenAI response");
Check(SpeechClient.ParseTranscript("{\"output\":{\"text\":\"你好\"}}") == "你好", "Fun-ASR response");
Check(SpeechClient.ParseTranscript("{\"output\":{\"choices\":[{\"message\":{\"content\":[{\"text\":\"你\"},{\"text\":\"好\"}]}}]}}") == "你好", "Qwen response segments");
Check(SpeechClient.ParseTranscript("{\"output\":{\"choices\":[{\"message\":{\"content\":\"Hi\"}}]}}") == "Hi", "Qwen string response");
Check(SpeechClient.ParseTranscript("{}") == "", "Missing transcript stays empty");
Check(SpeechClient.ServiceError(403, "AllocationQuota.FreeTierOnly", "key").Contains("免费额度用完即停"), "Quota recovery message");
Check(!SpeechClient.ServiceError(500, "echo test-secret", "test-secret").Contains("test-secret"), "Server diagnostics redact key");
Check(SpeechClient.ServiceError(401, "", "x").Contains("API"), "Invalid key message");

var handler = new FakeHandler(async request => {
    var body = await request.Content!.ReadAsStringAsync();
    Check(request.Headers.Authorization?.Parameter == "test-secret", "ASR authorization header");
    Check(body.Contains("data:audio/wav;base64,") && body.Contains("\"format\":\"wav\""), "DashScope WAV payload");
    return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("{\"output\":{\"text\":\"Hello\"}}") };
});
config.Model = "fun-asr-flash-2026-06-15";
var client = new SpeechClient(new HttpClient(handler));
Check(await client.TranscribeAsync(pcm, config, CancellationToken.None) == "Hello", "Batch pipeline parses response");
var bad = new SpeechClient(new HttpClient(new FakeHandler(_ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.Forbidden) { Content = new StringContent("AllocationQuota.FreeTierOnly") }))));
try { await bad.TranscribeAsync(pcm, config, CancellationToken.None); throw new Exception("Quota response accepted"); }
catch (InvalidOperationException error) { Check(error.Message.Contains("免费额度用完即停"), "Batch failure preserves recovery action"); }
var fallback = await bad.PolishAsync("原文", config, CancellationToken.None);
Check(fallback.Text == "原文" && fallback.PolishUnavailable, "Polish failure preserves raw transcript");
config.Polish = false;
Check(!(await bad.PolishAsync("原文", config, CancellationToken.None)).PolishUnavailable, "Disabled polish is not a failure");
using var cancellation = new CancellationTokenSource(); cancellation.Cancel(); config.Polish = true;
try { await bad.PolishAsync("原文", config, cancellation.Token); throw new Exception("Cancellation swallowed"); }
catch (OperationCanceledException) { Check(true, "User cancellation is never silently downgraded"); }
Console.WriteLine($"{passed} checks passed.");

if (args.Length == 3 && args[0] == "--live")
{
    using var defaults = JsonDocument.Parse(File.ReadAllText(args[2]));
    var root = defaults.RootElement;
    var live = new AppConfig { ApiKey = root.GetProperty("ApiKey").GetString()!, LlmApiKey = root.GetProperty("ApiKey").GetString()!,
        Model = root.GetProperty("Model").GetString()!, LlmModel = root.GetProperty("LlmModel").GetString()!, PolishPrompt = root.GetProperty("PolishPrompt").GetString()! };
    byte[] audio = WaveData.ReadPcm(File.ReadAllBytes(args[1]));
    using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(180));
    using var realHttp = new HttpClient { Timeout = TimeSpan.FromSeconds(120) };
    var speech = new SpeechClient(realHttp);
    bool failed = false;
    using (var realtime = new RealtimeSession(live.ApiKey, timeout.Token))
    {
        for (int offset = 0; offset < audio.Length; offset += 3200)
        {
            realtime.Append(audio.AsSpan(offset, Math.Min(3200, audio.Length - offset)).ToArray());
            await Task.Delay(100, timeout.Token);
        }
        string? text = await realtime.CompleteAsync(timeout.Token);
        Console.WriteLine(string.IsNullOrWhiteSpace(text) ? "LIVE realtime: FAILED (no transcript)" : "LIVE realtime: PASS");
        failed |= string.IsNullOrWhiteSpace(text);
    }
    try
    {
        string text = await speech.TranscribeAsync(audio, live, timeout.Token);
        Console.WriteLine(text.Length > 0 ? "LIVE batch: PASS" : "LIVE batch: FAILED");
    }
    catch (Exception error) { Console.WriteLine("LIVE batch: FAILED " + error.Message); failed = true; }
    var polished = await speech.PolishAsync("Tomorrow morning at ten um we will discuss a new idea together", live, timeout.Token);
    Console.WriteLine(polished.PolishUnavailable ? "LIVE polish: FAILED" : "LIVE polish: PASS");
    if (failed || polished.PolishUnavailable) Environment.ExitCode = 1;
}

sealed class FakeHandler(Func<HttpRequestMessage, Task<HttpResponseMessage>> respond) : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    { cancellationToken.ThrowIfCancellationRequested(); return respond(request); }
}
