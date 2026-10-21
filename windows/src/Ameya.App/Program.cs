using System.Runtime.InteropServices;
using Ameya.Core.Testing;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace Ameya.App;

public static class Program
{
    /// <summary>
    /// --self-test runs before any XAML or Windows App SDK code, so it works from a plain build
    /// folder on a CI runner as well as from the installed package ("Ameya.exe --self-test").
    /// Otherwise Ameya runs as a single instance: a second launch just shows the first one.
    /// </summary>
    [STAThread]
    public static int Main(string[] args)
    {
        if (args.Contains("--self-test", StringComparer.OrdinalIgnoreCase))
        {
            return RunSelfTest();
        }

        WinRT.ComWrappersSupport.InitializeComWrappers();
        var instance = AppInstance.FindOrRegisterForKey("Ameya");
        if (!instance.IsCurrent)
        {
            var activation = AppInstance.GetCurrent().GetActivatedEventArgs();
            // Redirecting waits on another thread: blocking the STA thread itself can deadlock.
            Task.Run(() => instance.RedirectActivationToAsync(activation).AsTask()).Wait();
            return 0;
        }

        Application.Start(_ =>
        {
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            var app = new App();
            instance.Activated += (_, _) => app.ShowMainWindowFromAnyThread();
        });
        return 0;
    }

    public static string WorkerPath => Path.Combine(AppContext.BaseDirectory, "Ameya.Worker.exe");

    private static int RunSelfTest()
    {
        // A windowed app has no console of its own: borrow the terminal's unless output is redirected.
        if (!Console.IsOutputRedirected) AttachConsole(AttachParentProcess);
        var exitCode = SelfTest.RunAsync(WorkerPath, Console.Out).GetAwaiter().GetResult();
        Console.Out.Flush();
        return exitCode;
    }

    private const int AttachParentProcess = -1;

    [DllImport("kernel32.dll")]
    private static extern bool AttachConsole(int processId);
}
