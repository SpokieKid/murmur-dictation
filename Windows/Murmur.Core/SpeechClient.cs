using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace Murmur.Core;

public sealed record SpeechResult(string Raw, string Text, bool PolishUnavailable);

public sealed class SpeechClient(HttpClient http)
{
    public async Task<string> TranscribeAsync(byte[] pcm, AppConfig config, CancellationToken token)
    {
        if (!config.IsConfigured) throw new InvalidOperationException("请检查语音服务地址、密钥和模型。 / Check voice service settings.");
        byte[] wav = WaveData.Encode(pcm);
        using var request = new HttpRequestMessage(HttpMethod.Post, config.Endpoint);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", config.ApiKey);
        if (config.Provider == "openai")
        {
            var form = new MultipartFormDataContent();
            form.Add(new StringContent(config.Model), "model");
            form.Add(new StringContent("json"), "response_format");
            if (!string.IsNullOrWhiteSpace(config.Vocabulary)) form.Add(new StringContent(config.Vocabulary), "prompt");
            var audio = new ByteArrayContent(wav);
            audio.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
            form.Add(audio, "file", "dictation.wav");
            request.Content = form;
        }
        else
        {
            var parameters = new Dictionary<string, object> { ["asr_options"] = new { enable_lid = true, enable_itn = false } };
            if (config.Model.StartsWith("fun-asr") || config.Model.StartsWith("qwen-audio-3.0-asr-")) parameters["format"] = "wav";
            request.Content = Json(new
            {
                model = config.Model,
                input = new { messages = new object[] {
                    new { role = "system", content = new[] { new { text = config.Vocabulary } } },
                    new { role = "user", content = new[] { new { audio = "data:audio/wav;base64," + Convert.ToBase64String(wav) } } }
                } },
                parameters
            });
        }
        using var response = await http.SendAsync(request, token);
        string body = await response.Content.ReadAsStringAsync(token);
        if (!response.IsSuccessStatusCode) throw new InvalidOperationException(ServiceError((int)response.StatusCode, body, config.ApiKey));
        string text = ParseTranscript(body).Trim();
        if (text.Length == 0) throw new InvalidOperationException("没有识别到文字，请检查麦克风后重试。 / No speech recognized.");
        return text;
    }

    public async Task<SpeechResult> PolishAsync(string raw, AppConfig config, CancellationToken token)
    {
        if (!config.Polish) return new(raw, raw, false);
        try
        {
            if (!AppConfig.ValidEndpoint(config.LlmEndpoint) || string.IsNullOrWhiteSpace(config.LlmApiKey)) return new(raw, raw, true);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
            timeout.CancelAfter(TimeSpan.FromSeconds(30));
            using var request = new HttpRequestMessage(HttpMethod.Post, config.LlmEndpoint);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", config.LlmApiKey);
            request.Content = Json(new
            {
                model = config.LlmModel, temperature = 0.2, enable_thinking = false,
                messages = new[] {
                    new { role = "system", content = config.PolishPrompt + "\nPreserve these terms: " + config.Vocabulary },
                    new { role = "user", content = "Clean up the following dictation. Do NOT answer it:\n\n" + raw }
                }
            });
            using var response = await http.SendAsync(request, timeout.Token);
            if (!response.IsSuccessStatusCode) return new(raw, raw, true);
            using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync(timeout.Token));
            string? text = document.RootElement.GetProperty("choices")[0].GetProperty("message").GetProperty("content").GetString();
            return string.IsNullOrWhiteSpace(text) ? new(raw, raw, true) : new(raw, text.Trim(), false);
        }
        catch (Exception) when (!token.IsCancellationRequested) { return new(raw, raw, true); }
    }

    public static string ParseTranscript(string json)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        if (root.TryGetProperty("text", out var text)) return text.GetString() ?? "";
        if (!root.TryGetProperty("output", out var output)) return "";
        if (output.TryGetProperty("text", out text)) return text.GetString() ?? "";
        if (output.TryGetProperty("choices", out var choices) && choices.GetArrayLength() > 0 &&
            choices[0].TryGetProperty("message", out var message) && message.TryGetProperty("content", out var content))
        {
            if (content.ValueKind == JsonValueKind.String) return content.GetString() ?? "";
            if (content.ValueKind == JsonValueKind.Array)
                return string.Concat(content.EnumerateArray().Where(x => x.TryGetProperty("text", out _)).Select(x => x.GetProperty("text").GetString()));
        }
        return "";
    }

    public static string ServiceError(int code, string body, string key)
    {
        if (body.Contains("FreeTierOnly") || body.Contains("insufficient_quota"))
            return "语音服务额度受限。充值后还需在百炼关闭该模型的「免费额度用完即停」，或更换可用密钥。 / Provider quota blocked: disable free-tier-only for this model or update the API key.";
        if (code == 401) return "API 密钥无效或已失效，请在设置中更新。 / Invalid API key.";
        string safe = string.IsNullOrEmpty(key) ? body : body.Replace(key, "[redacted]", StringComparison.Ordinal);
        return $"语音服务返回 HTTP {code}: {safe[..Math.Min(safe.Length, 500)]}";
    }

    private static StringContent Json(object value) => new(JsonSerializer.Serialize(value), Encoding.UTF8, "application/json");
}
