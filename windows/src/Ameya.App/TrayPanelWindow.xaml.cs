using System.Runtime.InteropServices;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;
using Windows.Graphics;
using Windows.System;

namespace Ameya.App;

/// <summary>
/// The compact panel that opens next to the notification-area icon: no title bar, always on top,
/// not in Alt+Tab, and it tucks itself away when it loses focus or Escape is pressed.
/// </summary>
public sealed partial class TrayPanelWindow : Window
{
    private const int Width96 = 380;
    private const int Height96 = 600;
    private bool _quitting;

    public TrayPanelWindow()
    {
        InitializeComponent();
        Converter.HostWindow = this;
        AppWindow.IsShownInSwitchers = false;
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Ameya.ico"));
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsResizable = false;
            presenter.IsMaximizable = false;
            presenter.IsMinimizable = false;
            presenter.IsAlwaysOnTop = true;
            presenter.SetBorderAndTitleBar(true, false);
        }
        Activated += (_, args) =>
        {
            // Picking files opens a dialog that takes focus; the panel stays for its answer.
            if (args.WindowActivationState == WindowActivationState.Deactivated && !Converter.IsShowingDialog) HidePanel();
        };
        AppWindow.Closing += (sender, args) =>
        {
            if (_quitting) return;
            args.Cancel = true;
            sender.Hide();
        };
        var escape = new KeyboardAccelerator { Key = VirtualKey.Escape };
        escape.Invoked += (_, args) =>
        {
            args.Handled = true;
            HidePanel();
        };
        if (Content is UIElement root) root.KeyboardAccelerators.Add(escape);
    }

    public bool IsShown => AppWindow.IsVisible;

    /// <summary>Opens the panel above (or beside) the notification area, on the screen with the pointer.</summary>
    public void ShowNearTray()
    {
        var scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        if (scale <= 0) scale = 1;
        var width = (int)(Width96 * scale);
        var height = (int)(Height96 * scale);
        GetCursorPos(out var cursor);
        var area = DisplayArea.GetFromPoint(new PointInt32(cursor.X, cursor.Y), DisplayAreaFallback.Primary).WorkArea;
        var margin = (int)(12 * scale);
        var x = Math.Clamp(cursor.X - width / 2, area.X + margin, Math.Max(area.X + margin, area.X + area.Width - width - margin));
        int y;
        if (cursor.Y >= area.Y + area.Height) y = area.Y + area.Height - height - margin; // taskbar at the bottom
        else if (cursor.Y <= area.Y) y = area.Y + margin; // taskbar at the top
        else y = Math.Clamp(cursor.Y - height / 2, area.Y + margin, Math.Max(area.Y + margin, area.Y + area.Height - height - margin));
        AppWindow.MoveAndResize(new RectInt32(x, y, width, height));
        AppWindow.Show();
        Activate();
    }

    public void HidePanel() => AppWindow.Hide();

    public void CloseForQuit()
    {
        _quitting = true;
        Close();
    }

    private void OnOpenWindow(object sender, RoutedEventArgs e)
    {
        HidePanel();
        App.Current.ShowMainWindow();
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Point
    {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out Point point);

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr window);
}
