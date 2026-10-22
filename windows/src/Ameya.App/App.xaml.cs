using Ameya.App.Tray;
using Ameya.Core.Files;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace Ameya.App;

/// <summary>
/// Tray-first: Ameya lives in the notification area. Clicking the icon opens a compact panel;
/// the main window is for bigger jobs, and closing it keeps Ameya running in the tray.
/// Nothing polls while idle: work happens only in response to clicks, drops and finished jobs.
/// </summary>
public partial class App : Application
{
    private DispatcherQueue? _dispatcher;
    private TrayIcon? _tray;
    private MainWindow? _mainWindow;
    private TrayPanelWindow? _panel;

    public App() => InitializeComponent();

    public Jobs Jobs { get; } = new();

    public static new App Current => (App)Application.Current;

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _dispatcher = DispatcherQueue.GetForCurrentThread();
        _tray = new TrayIcon("Ameya — convert files on this PC");
        _tray.Selected += (_, _) => TogglePanel();
        _tray.MenuItemChosen += (_, item) => OnTrayMenu(item);
        // Old leftovers from jobs that were killed (power cut, crash). Runs once, off the UI thread.
        _ = Task.Run(() =>
        {
            LeftoverCleanup.SweepPartials(Jobs.OutputFolder);
            LeftoverCleanup.SweepScratch(Jobs.ScratchFolder);
        });
        ShowMainWindow();
    }

    public void ShowMainWindowFromAnyThread() => _dispatcher?.TryEnqueue(() => ShowMainWindow());

    public void ShowMainWindow(bool settings = false)
    {
        _mainWindow ??= new MainWindow();
        _mainWindow.ShowAndActivate(settings);
    }

    private void TogglePanel()
    {
        _panel ??= new TrayPanelWindow();
        if (_panel.IsShown) _panel.HidePanel(); else _panel.ShowNearTray();
    }

    private async void OnTrayMenu(TrayMenuItem item)
    {
        switch (item)
        {
            case TrayMenuItem.Open:
                ShowMainWindow();
                break;
            case TrayMenuItem.Paste:
                await Jobs.AddFromClipboardAsync();
                _panel ??= new TrayPanelWindow();
                _panel.ShowNearTray();
                break;
            case TrayMenuItem.Settings:
                ShowMainWindow(settings: true);
                break;
            case TrayMenuItem.Quit:
                Quit();
                break;
        }
    }

    public void Quit()
    {
        Jobs.CancelAll();
        _tray?.Dispose();
        _tray = null;
        _panel?.CloseForQuit();
        _mainWindow?.CloseForQuit();
        Exit();
    }
}
