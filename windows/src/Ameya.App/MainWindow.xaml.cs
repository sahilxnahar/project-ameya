using System.Diagnostics;
using Microsoft.UI.Xaml;
using Windows.Graphics;

namespace Ameya.App;

public sealed partial class MainWindow : Window
{
    private bool _quitting;

    public MainWindow()
    {
        InitializeComponent();
        Converter.HostWindow = this;
        OutputFolderRun.Text = App.Current.Jobs.OutputFolder;
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Ameya.ico"));
        AppWindow.Resize(new SizeInt32(560, 760));
        // Closing hides the window; Ameya stays in the notification area until Quit.
        AppWindow.Closing += (sender, args) =>
        {
            if (_quitting) return;
            args.Cancel = true;
            sender.Hide();
        };
    }

    public void ShowAndActivate(bool settings)
    {
        if (settings) SettingsExpander.IsExpanded = true;
        AppWindow.Show();
        Activate();
    }

    public void CloseForQuit()
    {
        _quitting = true;
        Close();
    }

    private void OnOpenOutputFolder(object sender, RoutedEventArgs e)
    {
        var folder = App.Current.Jobs.OutputFolder;
        Directory.CreateDirectory(folder);
        using var _ = Process.Start(new ProcessStartInfo("explorer.exe", $"\"{folder}\""));
    }

    private void OnQuit(object sender, RoutedEventArgs e) => App.Current.Quit();
}
