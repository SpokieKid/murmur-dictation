using System.Runtime.InteropServices;
using System.Collections.Concurrent;
using Murmur.Core;

namespace Murmur.Windows;

internal sealed class WaveRecorder : IDisposable
{
    [StructLayout(LayoutKind.Sequential)] private struct Format
    {
        public ushort Tag, Channels; public uint SamplesPerSecond, BytesPerSecond; public ushort BlockAlign, Bits, Extra;
    }
    [StructLayout(LayoutKind.Sequential)] private struct Header
    {
        public IntPtr Data; public uint BufferLength, BytesRecorded; public UIntPtr User;
        public uint Flags, Loops; public IntPtr Next; public UIntPtr Reserved;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct Caps
    {
        public ushort Manufacturer, Product; public uint Version;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Name;
        public uint Formats; public ushort Channels, Reserved;
    }
    private delegate void Callback(IntPtr handle, uint message, UIntPtr instance, IntPtr header, IntPtr unused);
    [DllImport("winmm.dll")] private static extern uint waveInGetNumDevs();
    [DllImport("winmm.dll", CharSet = CharSet.Unicode)] private static extern uint waveInGetDevCapsW(UIntPtr id, out Caps caps, uint size);
    [DllImport("winmm.dll")] private static extern uint waveInOpen(out IntPtr handle, uint device, ref Format format, Callback callback, UIntPtr instance, uint flags);
    [DllImport("winmm.dll")] private static extern uint waveInPrepareHeader(IntPtr handle, IntPtr header, uint size);
    [DllImport("winmm.dll")] private static extern uint waveInAddBuffer(IntPtr handle, IntPtr header, uint size);
    [DllImport("winmm.dll")] private static extern uint waveInStart(IntPtr handle);
    [DllImport("winmm.dll")] private static extern uint waveInReset(IntPtr handle);
    [DllImport("winmm.dll")] private static extern uint waveInUnprepareHeader(IntPtr handle, IntPtr header, uint size);
    [DllImport("winmm.dll")] private static extern uint waveInClose(IntPtr handle);

    public static IReadOnlyList<(int Id, string Name)> Devices()
    {
        var devices = new List<(int, string)> { (-1, "系统默认 / System default") };
        for (uint i = 0; i < waveInGetNumDevs(); i++)
            if (waveInGetDevCapsW((UIntPtr)i, out var caps, (uint)Marshal.SizeOf<Caps>()) == 0) devices.Add(((int)i, caps.Name));
        return devices;
    }

    public static int ResolveDevice(int id, string name)
    {
        var devices = Devices();
        if (!string.IsNullOrWhiteSpace(name))
        {
            foreach (var device in devices) if (device.Name == name) return device.Id;
            return -1;
        }
        return devices.Any(x => x.Id == id) ? id : -1;
    }

    private readonly object gate = new();
    private readonly Callback callback;
    private readonly ConcurrentQueue<IntPtr> completed = new();
    private readonly AutoResetEvent ready = new(false);
    private readonly Thread worker;
    private GCHandle selfRoot;
    private volatile bool workerStopping;
    private bool disposed;
    private sealed class Buffer(IntPtr header, IntPtr data) { public IntPtr Header = header, Data = data; public bool Prepared; }
    private readonly List<Buffer> buffers = [];
    private readonly ManualResetEventSlim returned = new(false);
    private readonly MemoryStream pcm = new();
    private IntPtr handle;
    private bool stopping;
    private int pending;
    private float level, peak;
    public Action<byte[]>? OnChunk { get; set; }
    public float Level { get { lock (gate) return level; } }
    public float Peak { get { lock (gate) return peak; } }
    public double Seconds { get { lock (gate) return (double)pcm.Length / WaveData.BytesPerSecond; } }

    public WaveRecorder(int device)
    {
        callback = OnData;
        worker = new Thread(ProcessBuffers) { IsBackground = true, Name = "Murmur audio buffers" };
        selfRoot = GCHandle.Alloc(this);
        var format = new Format { Tag = 1, Channels = 1, SamplesPerSecond = 16000, BytesPerSecond = 32000, BlockAlign = 2, Bits = 16 };
        uint result = waveInOpen(out handle, unchecked((uint)device), ref format, callback, UIntPtr.Zero, 0x30000);
        if (result != 0) { selfRoot.Free(); throw new InvalidOperationException($"无法打开麦克风（{result}）。请允许桌面应用使用麦克风，并检查输入设备。 / Cannot open microphone. Check Windows microphone privacy and input device."); }
        worker.Start();
        try
        {
            for (int i = 0; i < 4; i++)
            {
                IntPtr data = Marshal.AllocHGlobal(3200), ptr = Marshal.AllocHGlobal(Marshal.SizeOf<Header>());
                var buffer = new Buffer(ptr, data); buffers.Add(buffer);
                Marshal.StructureToPtr(new Header { Data = data, BufferLength = 3200 }, ptr, false);
                Check(waveInPrepareHeader(handle, ptr, HeaderSize));
                buffer.Prepared = true;
                lock (gate) pending++;
                uint added = waveInAddBuffer(handle, ptr, HeaderSize);
                if (added != 0) { lock (gate) pending--; Check(added); }
            }
        }
        catch { Dispose(); throw; }
    }

    private static uint HeaderSize => (uint)Marshal.SizeOf<Header>();
    public void Start() => Check(waveInStart(handle));
    private static void Check(uint code) { if (code != 0) throw new InvalidOperationException($"Microphone driver error {code}."); }

    private void OnData(IntPtr wave, uint message, UIntPtr instance, IntPtr ptr, IntPtr unused)
    {
        if (message != 0x3C0) return;
        // WinMM forbids calling wave APIs from its callback. Only enqueue and
        // signal here; a dedicated worker processes and requeues each buffer.
        completed.Enqueue(ptr);
        ready.Set();
    }

    private void ProcessBuffers()
    {
        while (!workerStopping)
        {
            ready.WaitOne();
            while (completed.TryDequeue(out IntPtr ptr)) ProcessHeader(ptr);
        }
    }

    private void ProcessHeader(IntPtr ptr)
    {
        byte[]? chunk = null;
        bool drained = false;
        try
        {
            lock (gate)
            {
                var header = Marshal.PtrToStructure<Header>(ptr);
                if (header.BytesRecorded > 0 && pcm.Length < 220L * WaveData.BytesPerSecond)
                {
                    chunk = new byte[header.BytesRecorded]; Marshal.Copy(header.Data, chunk, 0, chunk.Length);
                    pcm.Write(chunk);
                    double sum = 0;
                    for (int i = 0; i + 1 < chunk.Length; i += 2) { double sample = BitConverter.ToInt16(chunk, i) / 32768.0; sum += sample * sample; }
                    float rms = (float)Math.Sqrt(sum / Math.Max(1, chunk.Length / 2));
                    level = Math.Min(1, rms * 6); peak = Math.Max(peak, rms);
                }
                pending--;
                if (!stopping)
                {
                    if (waveInAddBuffer(handle, ptr, HeaderSize) == 0) pending++;
                }
                drained = stopping && pending == 0;
            }
            if (chunk is not null) OnChunk?.Invoke(chunk);
        }
        catch { /* Never propagate an exception across an unmanaged audio callback. */ }
        finally { if (drained) returned.Set(); }
    }

    public byte[] Stop()
    {
        if (handle == IntPtr.Zero) return [];
        lock (gate) { stopping = true; if (pending == 0) returned.Set(); }
        Check(waveInReset(handle));
        if (!returned.Wait(TimeSpan.FromSeconds(3)))
            throw new InvalidOperationException("麦克风未能及时停止，请重新打开 Murmur。 / Microphone driver did not stop in time.");
        foreach (var buffer in buffers) if (buffer.Prepared) { Check(waveInUnprepareHeader(handle, buffer.Header, HeaderSize)); buffer.Prepared = false; }
        Check(waveInClose(handle)); handle = IntPtr.Zero;
        workerStopping = true; ready.Set(); worker.Join();
        foreach (var buffer in buffers) { Marshal.FreeHGlobal(buffer.Header); Marshal.FreeHGlobal(buffer.Data); }
        buffers.Clear();
        if (selfRoot.IsAllocated) selfRoot.Free();
        lock (gate) { byte[] result = pcm.ToArray(); pcm.SetLength(0); return result; }
    }

    public void Dispose()
    {
        if (disposed) return;
        if (handle != IntPtr.Zero) { try { Stop(); } catch { /* Do not free buffers still owned by the driver. */ } }
        if (handle == IntPtr.Zero) { disposed = true; returned.Dispose(); ready.Dispose(); pcm.Dispose(); }
        GC.KeepAlive(callback);
    }
}
