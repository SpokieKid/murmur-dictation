using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Murmur.Core;

namespace Murmur.Windows;

internal static class ConfigStore
{
    private static string DirectoryPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Murmur");
    private static string FilePath => Path.Combine(DirectoryPath, "settings.json");
    private sealed record Stored(AppConfig Config, string ProtectedKey, string ProtectedLlmKey);
    private sealed record Trial(string ApiKey, string LlmModel, string Model, string PolishPrompt);

    public static AppConfig Load()
    {
        if (File.Exists(FilePath))
        {
            try
            {
                var stored = JsonSerializer.Deserialize<Stored>(File.ReadAllText(FilePath)) ?? throw new InvalidDataException();
                stored.Config.ApiKey = Crypt(stored.ProtectedKey, false);
                stored.Config.LlmApiKey = Crypt(stored.ProtectedLlmKey, false);
                return stored.Config;
            }
            catch (Exception error) when (error is JsonException or InvalidDataException or System.ComponentModel.Win32Exception or FormatException)
            {
                MessageBox.Show("无法读取本机配置，将使用初始配置。原文件已保留。 / Settings could not be read; the original file is preserved.", "Murmur");
                File.Copy(FilePath, FilePath + ".backup-" + DateTime.Now.ToString("yyyyMMdd-HHmmss"), false);
            }
        }
        var config = new AppConfig();
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("TrialDefaults.json");
        if (stream is not null)
        {
            var trial = JsonSerializer.Deserialize<Trial>(stream);
            if (trial is not null)
            {
                config.ApiKey = trial.ApiKey; config.LlmApiKey = trial.ApiKey;
                config.LlmModel = trial.LlmModel; config.Model = trial.Model; config.PolishPrompt = trial.PolishPrompt;
            }
        }
        return config;
    }

    public static void Save(AppConfig config)
    {
        Directory.CreateDirectory(DirectoryPath);
        var stored = new Stored(config, Crypt(config.ApiKey, true), Crypt(config.LlmApiKey, true));
        string temp = FilePath + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(stored, new JsonSerializerOptions { WriteIndented = true }));
        File.Move(temp, FilePath, true);
    }

    [StructLayout(LayoutKind.Sequential)] private struct Blob { public int Length; public IntPtr Data; }
    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CryptProtectData(ref Blob input, string description, IntPtr entropy, IntPtr reserved, IntPtr prompt, uint flags, out Blob output);
    [DllImport("crypt32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CryptUnprotectData(ref Blob input, IntPtr description, IntPtr entropy, IntPtr reserved, IntPtr prompt, uint flags, out Blob output);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);

    private static string Crypt(string value, bool protect)
    {
        if (value.Length == 0) return "";
        byte[] bytes = protect ? Encoding.UTF8.GetBytes(value) : Convert.FromBase64String(value);
        var input = new Blob { Length = bytes.Length, Data = Marshal.AllocHGlobal(bytes.Length) };
        Marshal.Copy(bytes, 0, input.Data, bytes.Length);
        Blob output = default;
        try
        {
            bool ok = protect ? CryptProtectData(ref input, "Murmur", IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output)
                : CryptUnprotectData(ref input, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output);
            if (!ok) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            byte[] result = new byte[output.Length]; Marshal.Copy(output.Data, result, 0, result.Length);
            return protect ? Convert.ToBase64String(result) : Encoding.UTF8.GetString(result);
        }
        finally { Marshal.FreeHGlobal(input.Data); if (output.Data != IntPtr.Zero) LocalFree(output.Data); }
    }
}
