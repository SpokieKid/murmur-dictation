namespace Murmur.Windows;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        using var instance = new Mutex(true, @"Local\Murmur.Dictation", out bool first);
        if (!first)
        {
            try { using var signal = EventWaitHandle.OpenExisting(@"Local\Murmur.Show"); signal.Set(); }
            catch (WaitHandleCannotBeOpenedException) { }
            return;
        }
        ApplicationConfiguration.Initialize();
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
        Application.ThreadException += (_, e) => MessageBox.Show(e.Exception.Message, "Murmur", MessageBoxButtons.OK, MessageBoxIcon.Error);
        try
        {
            var config = ConfigStore.Load();
            using var main = new MainForm(config);
            using var signal = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\Murmur.Show");
            var registration = ThreadPool.RegisterWaitForSingleObject(signal, (_, _) => {
                if (main.IsHandleCreated && !main.IsDisposed) main.BeginInvoke(main.ShowWindow);
            }, null, Timeout.Infinite, false);
            try { Application.Run(main); }
            finally { registration.Unregister(null); }
        }
        catch (Exception error) { MessageBox.Show(error.Message, "Murmur", MessageBoxButtons.OK, MessageBoxIcon.Error); }
    }
}
