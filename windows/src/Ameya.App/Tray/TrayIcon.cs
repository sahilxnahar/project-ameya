using System.Runtime.InteropServices;
using static Ameya.App.Tray.TrayNative;

namespace Ameya.App.Tray;

public enum TrayMenuItem
{
    Open = 1,
    Paste = 2,
    Settings = 3,
    Quit = 4,
}

/// <summary>
/// The notification-area icon, through Shell_NotifyIcon (the Windows App SDK has no tray API, and
/// this keeps Ameya free of extra dependencies). A hidden window on the UI thread receives the
/// icon's messages, so nothing polls: it costs nothing while idle.
/// Keyboard users reach it with Win+B; Enter or Space opens the panel, Shift+F10 the menu.
/// </summary>
internal sealed class TrayIcon : IDisposable
{
    private const uint CallbackMessage = WmApp + 1;
    private const string ClassName = "AmeyaTrayWindow";

    private readonly WindowProcedure _procedure; // kept alive: Windows calls it for as long as the window exists
    private readonly uint _taskbarCreated;
    private readonly string _tooltip;
    private readonly IntPtr _instance;
    private IntPtr _window;
    private IntPtr _icon;

    public TrayIcon(string tooltip)
    {
        _tooltip = tooltip;
        _procedure = Procedure;
        _instance = GetModuleHandle(null);
        // Sent to every top-level window when Explorer restarts; the icon must then be added again.
        _taskbarCreated = RegisterWindowMessage("TaskbarCreated");
        var windowClass = new WindowClass
        {
            Size = (uint)Marshal.SizeOf<WindowClass>(),
            WindowProcedure = Marshal.GetFunctionPointerForDelegate(_procedure),
            Instance = _instance,
            ClassName = ClassName,
        };
        RegisterClassEx(ref windowClass);
        _window = CreateWindowEx(0, ClassName, "Ameya", 0, 0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, _instance, IntPtr.Zero);
        var iconPath = Path.Combine(AppContext.BaseDirectory, "Assets", "Ameya.ico");
        _icon = LoadImage(IntPtr.Zero, iconPath, ImageIcon, GetSystemMetrics(SmCxSmIcon), GetSystemMetrics(SmCySmIcon), LrLoadFromFile);
        Add();
    }

    /// <summary>Left click, or Enter/Space on the focused icon.</summary>
    public event EventHandler? Selected;

    public event EventHandler<TrayMenuItem>? MenuItemChosen;

    public void Dispose()
    {
        if (_window == IntPtr.Zero) return;
        var data = Data();
        ShellNotifyIcon(NimDelete, ref data);
        DestroyWindow(_window);
        _window = IntPtr.Zero;
        UnregisterClass(ClassName, _instance);
        if (_icon != IntPtr.Zero) DestroyIcon(_icon);
        _icon = IntPtr.Zero;
    }

    private NotifyIconData Data() => new()
    {
        Size = (uint)Marshal.SizeOf<NotifyIconData>(),
        Window = _window,
        Id = 1,
        Flags = NifMessage | NifIcon | NifTip | NifShowTip,
        CallbackMessage = CallbackMessage,
        Icon = _icon,
        Tip = _tooltip,
        Info = "",
        InfoTitle = "",
        Version = NotifyIconVersion4,
    };

    private void Add()
    {
        var data = Data();
        ShellNotifyIcon(NimAdd, ref data);
        // Version 4: keyboard selection and the context menu arrive as their own messages.
        ShellNotifyIcon(NimSetVersion, ref data);
    }

    private IntPtr Procedure(IntPtr window, uint message, IntPtr wParam, IntPtr lParam)
    {
        if (message == CallbackMessage)
        {
            // Version 4 packs the event in the low word of lParam and the anchor point in wParam.
            var notification = (uint)(lParam.ToInt64() & 0xFFFF);
            var x = (short)(wParam.ToInt64() & 0xFFFF);
            var y = (short)((wParam.ToInt64() >> 16) & 0xFFFF);
            switch (notification)
            {
                case NinSelect or NinKeySelect:
                    Selected?.Invoke(this, EventArgs.Empty);
                    break;
                case WmContextMenu:
                    ShowMenu(x, y);
                    break;
            }
            return IntPtr.Zero;
        }
        if (message == _taskbarCreated && _taskbarCreated != 0)
        {
            Add();
            return IntPtr.Zero;
        }
        return DefWindowProc(window, message, wParam, lParam);
    }

    private void ShowMenu(int x, int y)
    {
        var menu = CreatePopupMenu();
        try
        {
            AppendMenu(menu, MfString, (UIntPtr)(uint)TrayMenuItem.Open, "&Open Ameya");
            AppendMenu(menu, MfString, (UIntPtr)(uint)TrayMenuItem.Paste, "&Paste files");
            AppendMenu(menu, MfString, (UIntPtr)(uint)TrayMenuItem.Settings, "&Settings");
            AppendMenu(menu, MfSeparator, UIntPtr.Zero, null);
            AppendMenu(menu, MfString, (UIntPtr)(uint)TrayMenuItem.Quit, "&Quit Ameya");
            // The menu closes properly only if its owner is in the foreground.
            SetForegroundWindow(_window);
            var chosen = TrackPopupMenuEx(menu, TpmReturnCmd | TpmRightButton | TpmBottomAlign, x, y, _window, IntPtr.Zero);
            PostMessage(_window, WmNull, IntPtr.Zero, IntPtr.Zero);
            if (chosen != 0) MenuItemChosen?.Invoke(this, (TrayMenuItem)chosen);
        }
        finally
        {
            DestroyMenu(menu);
        }
    }
}
