using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;

namespace Murmur.Core;

public sealed class RealtimeSession : IDisposable
{
    private readonly ClientWebSocket socket = new();
    private readonly CancellationTokenSource cancel;
    private readonly Channel<byte[]> chunks = Channel.CreateBounded<byte[]>(4096);
    private readonly TaskCompletionSource done = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly StringBuilder text = new();
    private readonly string taskId = Guid.NewGuid().ToString("N");
    private readonly Task running;
    private int disposed;
    public string? Failure { get; private set; }

    public RealtimeSession(string key, CancellationToken token)
    {
        cancel = CancellationTokenSource.CreateLinkedTokenSource(token);
        socket.Options.SetRequestHeader("Authorization", "Bearer " + key);
        running = RunAsync();
    }

    public void Append(byte[] pcm) { if (!chunks.Writer.TryWrite(pcm)) Cancel(); }

    public async Task<string?> CompleteAsync(CancellationToken token)
    {
        chunks.Writer.TryComplete();
        try
        {
            await running.WaitAsync(TimeSpan.FromSeconds(20), token);
            return Failure is null && text.Length > 0 ? text.ToString() : null;
        }
        catch (Exception) when (!token.IsCancellationRequested) { Cancel(); return null; }
    }

    private async Task RunAsync()
    {
        try
        {
            using var handshake = CancellationTokenSource.CreateLinkedTokenSource(cancel.Token);
            handshake.CancelAfter(TimeSpan.FromSeconds(8));
            await socket.ConnectAsync(new Uri("wss://dashscope.aliyuncs.com/api-ws/v1/inference"), handshake.Token);
            await SendJson(new {
                header = new { action = "run-task", task_id = taskId, streaming = "duplex" },
                payload = new {
                    task_group = "audio", task = "asr", function = "recognition", model = "fun-asr-realtime",
                    parameters = new { format = "pcm", sample_rate = 16000, heartbeat = true }, input = new { }
                }
            }, handshake.Token);
            using (var first = JsonDocument.Parse(await Receive(handshake.Token)))
            {
                if (EventName(first.RootElement) != "task-started")
                    throw new InvalidOperationException("Realtime speech service did not start.");
            }
            Task receiver = ReceiveResults();
            try
            {
                await foreach (byte[] chunk in chunks.Reader.ReadAllAsync(cancel.Token))
                    await socket.SendAsync(chunk.AsMemory(), WebSocketMessageType.Binary, true, cancel.Token);
                await SendJson(new {
                    header = new { action = "finish-task", task_id = taskId, streaming = "duplex" },
                    payload = new { input = new { } }
                }, cancel.Token);
                await done.Task.WaitAsync(TimeSpan.FromSeconds(10), cancel.Token);
            }
            finally
            {
                cancel.Cancel();
                try { await receiver; } catch (OperationCanceledException) { }
            }
        }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            Failure = error is OperationCanceledException ? "Realtime connection cancelled or timed out." : "Realtime speech service unavailable.";
            cancel.Cancel();
        }
    }

    private async Task ReceiveResults()
    {
        while (!cancel.IsCancellationRequested)
        {
            using var document = JsonDocument.Parse(await Receive(cancel.Token));
            var root = document.RootElement;
            switch (EventName(root))
            {
                case "result-generated":
                    if (root.GetProperty("payload").TryGetProperty("output", out var output) &&
                        output.TryGetProperty("sentence", out var sentence) &&
                        sentence.TryGetProperty("sentence_end", out var end) && end.ValueKind == JsonValueKind.True &&
                        sentence.TryGetProperty("text", out var part)) text.Append(part.GetString());
                    break;
                case "task-finished": done.TrySetResult(); return;
                case "task-failed": done.TrySetException(new InvalidOperationException("Realtime speech service rejected the request.")); return;
            }
        }
    }

    private async Task<string> Receive(CancellationToken token)
    {
        using var buffer = new MemoryStream();
        byte[] data = new byte[8192];
        WebSocketReceiveResult received;
        do
        {
            received = await socket.ReceiveAsync(new ArraySegment<byte>(data), token);
            if (received.MessageType == WebSocketMessageType.Close) throw new IOException("Realtime socket closed.");
            buffer.Write(data, 0, received.Count);
            if (buffer.Length > 1024 * 1024) throw new InvalidDataException("Realtime response too large.");
        } while (!received.EndOfMessage);
        return Encoding.UTF8.GetString(buffer.ToArray());
    }

    private async Task SendJson(object data, CancellationToken token) =>
        await socket.SendAsync(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(data)).AsMemory(), WebSocketMessageType.Text, true, token);
    private static string? EventName(JsonElement root) => root.GetProperty("header").GetProperty("event").GetString();
    public void Cancel()
    {
        chunks.Writer.TryComplete();
        try { cancel.Cancel(); socket.Abort(); } catch (ObjectDisposedException) { }
    }
    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        Cancel();
        // Socket disposal waits for the reader/sender to unwind; cancellation may
        // race with a microphone callback, so keep the CTS alive until they stop.
        _ = running.ContinueWith(_ => { socket.Dispose(); cancel.Dispose(); }, TaskScheduler.Default);
    }
}
