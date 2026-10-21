using System.Diagnostics;
using Ameya.Core.Formats;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;

namespace Ameya.App;

public sealed partial class ConverterView : UserControl
{
    private string _announced = "";

    public ConverterView()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            Jobs.Changed += OnJobsChanged;
            Refresh();
        };
        Unloaded += (_, _) => Jobs.Changed -= OnJobsChanged;
    }

    /// <summary>The window hosting this view; the file picker needs it.</summary>
    public Window? HostWindow { get; set; }

    private static Jobs Jobs => App.Current.Jobs;

    private void OnJobsChanged(object? sender, EventArgs e) => Refresh();

    private void Refresh()
    {
        StatusText.Text = Jobs.Status;
        Announce(Jobs.Status);
        JobProgress.Visibility = CancelButton.Visibility = Jobs.IsRunning ? Visibility.Visible : Visibility.Collapsed;
        JobProgress.Value = Jobs.Progress;
        ChooseButton.IsEnabled = !Jobs.IsRunning;

        PendingSection.Visibility = Jobs.Pending.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        PendingList.ItemsSource = Jobs.Pending.Select(p => $"{p.Name} ({p.Format.DisplayName})").ToList();

        TargetButtons.Children.Clear();
        IReadOnlyList<FileFormat> targets = Jobs.Pending.Count > 0 ? Jobs.Targets : Array.Empty<FileFormat>();
        TargetSection.Visibility = targets.Count > 0 && !Jobs.IsRunning ? Visibility.Visible : Visibility.Collapsed;
        foreach (var target in targets) TargetButtons.Children.Add(TargetButton(target));

        ResultSection.Visibility = Jobs.Results.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        ResultList.Children.Clear();
        foreach (var result in Jobs.Results.Take(50)) ResultList.Children.Add(ResultRow(result));
    }

    private Button TargetButton(FileFormat target)
    {
        var losses = Jobs.PossibleLosses(target);
        var help = losses.Count == 0 ? "Nothing is lost." : string.Join(" ", losses);
        var button = new Button
        {
            Content = target.DisplayName,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Margin = new Thickness(0, 0, 8, 8),
        };
        AutomationProperties.SetName(button, $"Convert to {target.DisplayName}");
        AutomationProperties.SetHelpText(button, help);
        ToolTipService.SetToolTip(button, help);
        button.Click += async (_, _) => await Jobs.ConvertAsync(target);
        return button;
    }

    private static Grid ResultRow(JobResult result)
    {
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var text = new TextBlock { TextWrapping = TextWrapping.Wrap };
        text.Text = result.Notes.Count == 0
            ? $"{result.SourceName}: {result.Message}"
            : $"{result.SourceName}: {result.Message}\n{string.Join("\n", result.Notes)}";
        AutomationProperties.SetName(text, text.Text);
        row.Children.Add(text);

        if (result.OutputPath is { } path)
        {
            var name = Path.GetFileName(path);
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            var open = new Button { Content = "Open" };
            AutomationProperties.SetName(open, $"Open {name}");
            AutomationProperties.SetHelpText(open, "Opens the converted file in its usual app.");
            open.Click += (_, _) => Launch(path, select: false);
            var show = new Button { Content = "Show in folder" };
            AutomationProperties.SetName(show, $"Show {name} in folder");
            AutomationProperties.SetHelpText(show, "Opens File Explorer with the converted file selected.");
            show.Click += (_, _) => Launch(path, select: true);
            buttons.Children.Add(open);
            buttons.Children.Add(show);
            Grid.SetColumn(buttons, 1);
            row.Children.Add(buttons);
        }
        return row;
    }

    private static void Launch(string path, bool select)
    {
        if (!File.Exists(path)) return;
        var start = select
            ? new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"")
            : new ProcessStartInfo(path) { UseShellExecute = true };
        try
        {
            using var _ = Process.Start(start);
        }
        catch (System.ComponentModel.Win32Exception)
        {
            // No app is set to open this kind of file; Windows already told the person.
        }
    }

    /// <summary>Tells Narrator about a new status without moving focus.</summary>
    private void Announce(string message)
    {
        if (message == _announced) return;
        _announced = message;
        FrameworkElementAutomationPeer.FromElement(StatusText)?.RaiseNotificationEvent(
            AutomationNotificationKind.ActionCompleted, AutomationNotificationProcessing.ImportantMostRecent, message, "AmeyaStatus");
    }

    private void OnDragOver(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(StandardDataFormats.StorageItems) || Jobs.IsRunning) return;
        e.AcceptedOperation = DataPackageOperation.Copy;
        e.DragUIOverride.Caption = "Add to Ameya";
    }

    private async void OnDrop(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(StandardDataFormats.StorageItems) || Jobs.IsRunning) return;
        var items = await e.DataView.GetStorageItemsAsync();
        Jobs.Add(items.OfType<StorageFile>().Select(file => file.Path).Where(path => !string.IsNullOrEmpty(path)));
    }

    private async void OnChoose(object sender, RoutedEventArgs e)
    {
        if (HostWindow is null) return;
        var picker = new FileOpenPicker { ViewMode = PickerViewMode.List };
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(HostWindow));
        IsShowingDialog = true;
        try
        {
            var files = await picker.PickMultipleFilesAsync();
            if (files.Count > 0) Jobs.Add(files.Select(file => file.Path));
        }
        finally
        {
            IsShowingDialog = false;
        }
    }

    /// <summary>True while the file picker is open, so the tray panel doesn't hide under it.</summary>
    public bool IsShowingDialog { get; private set; }

    private async void OnPasteAccelerator(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        if (!Jobs.IsRunning) await Jobs.AddFromClipboardAsync();
    }

    private void OnCancel(object sender, RoutedEventArgs e) => Jobs.CancelAll();

    private void OnClearPending(object sender, RoutedEventArgs e) => Jobs.ClearPending();

    private void OnClearResults(object sender, RoutedEventArgs e) => Jobs.ClearResults();
}
