using System.Runtime.InteropServices;
using System.Windows.Automation;
using System.Windows.Automation.Text;

namespace Murmur.Windows;

internal sealed record InputTarget(IntPtr Window, uint Process, AutomationElement Field, int[] RuntimeId,
                                  TextPatternRange Selection, string OriginalText);

internal static class NativeInput
{
    [StructLayout(LayoutKind.Sequential)] private struct KeyboardInput
    { public ushort Vk, Scan; public uint Flags, Time; public UIntPtr Extra; }
    [StructLayout(LayoutKind.Explicit)] private struct InputUnion
    {
        [FieldOffset(0)] public KeyboardInput Keyboard;
        [FieldOffset(0)] public MouseInput Mouse;
    }
    [StructLayout(LayoutKind.Sequential)] private struct MouseInput
    { public int X, Y; public uint Data, Flags, Time; public UIntPtr Extra; }
    [StructLayout(LayoutKind.Sequential)] private struct Input { public uint Type; public InputUnion Data; }
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")] private static extern uint SendInput(uint count, Input[] inputs, int size);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();

    public static InputTarget? Capture()
    {
        try
        {
            IntPtr window = GetForegroundWindow();
            GetWindowThreadProcessId(window, out uint process);
            var field = AutomationElement.FocusedElement;
            // Unverifiable fields and password controls are never auto-pasted into.
            if (field is null || !field.Current.IsEnabled || !field.Current.IsKeyboardFocusable || field.Current.IsPassword || field.Current.ControlType != ControlType.Edit ||
                !field.TryGetCurrentPattern(TextPattern.Pattern, out object pattern)) return null;
            if (field.TryGetCurrentPattern(ValuePattern.Pattern, out object valuePattern) && ((ValuePattern)valuePattern).Current.IsReadOnly) return null;
            var text = (TextPattern)pattern;
            var ranges = text.GetSelection();
            if (ranges.Length != 1) return null;
            string original = text.DocumentRange.GetText(1_000_001);
            if (original.Length > 1_000_000) return null;
            return new(window, process, field, field.GetRuntimeId(), ranges[0].Clone(), original);
        }
        catch (Exception error) when (error is ElementNotAvailableException or InvalidOperationException or COMException) { return null; }
    }

    public static bool CanPaste(InputTarget? target)
    {
        if (target is null || target.Window == IntPtr.Zero || target.Window != GetForegroundWindow()) return false;
        try
        {
            GetWindowThreadProcessId(target.Window, out uint process);
            var current = AutomationElement.FocusedElement;
            if (process != target.Process || current is null || !current.Current.IsEnabled || current.Current.IsPassword || current.Current.IsOffscreen ||
                !current.GetRuntimeId().SequenceEqual(target.RuntimeId) || !current.TryGetCurrentPattern(TextPattern.Pattern, out object pattern)) return false;
            if (current.TryGetCurrentPattern(ValuePattern.Pattern, out object valuePattern) && ((ValuePattern)valuePattern).Current.IsReadOnly) return false;
            var text = (TextPattern)pattern;
            var selected = text.GetSelection();
            return selected.Length == 1 && selected[0].Compare(target.Selection) && text.DocumentRange.GetText(1_000_001) == target.OriginalText;
        }
        catch (Exception error) when (error is ElementNotAvailableException or InvalidOperationException or COMException) { return false; }
    }

    public static bool Paste(InputTarget? target, CancellationToken token)
    {
        if (!CanPaste(target)) return false;
        token.ThrowIfCancellationRequested();
        // Do not release physical modifier keys owned by the user.
        if (new[] { 0x10, 0x11, 0x12, 0x5B, 0x5C }.Any(key => (GetAsyncKeyState(key) & 0x8000) != 0)) return false;
        Input Key(ushort key, bool up) => new() { Type = 1, Data = new InputUnion { Keyboard = new KeyboardInput { Vk = key, Flags = up ? 2u : 0u } } };
        Input[] inputs = [Key(0x11, false), Key(0x56, false), Key(0x56, true), Key(0x11, true)];
        uint sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Input>());
        if (sent > 0 && sent < inputs.Length)
        {
            Input[] release = [Key(0x56, true), Key(0x11, true)];
            SendInput((uint)release.Length, release, Marshal.SizeOf<Input>());
        }
        return sent == inputs.Length;
    }
}
