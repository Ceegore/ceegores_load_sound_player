using System.Windows;
using System.Windows.Input;
using System.Windows.Threading;

namespace ClipPlayer.App;

public partial class MainWindow : Window
{
    private readonly DispatcherTimer _positionTimer = new() { Interval = TimeSpan.FromMilliseconds(100) };
    public MainViewModel ViewModel { get; }

    public MainWindow(MainViewModel viewModel)
    {
        InitializeComponent();
        ViewModel = viewModel;
        DataContext = viewModel;
        _positionTimer.Tick += (_, _) => viewModel.RefreshPosition();
        _positionTimer.Start();
    }

    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        if (Keyboard.Modifiers != ModifierKeys.None || e.OriginalSource is System.Windows.Controls.Primitives.TextBoxBase or System.Windows.Controls.Slider)
            return;
        if (e.Key is Key.Left or Key.Right or Key.Space)
        {
            e.Handled = true;
            if (e.Key == Key.Left) ViewModel.PreviousCommand.Execute(null);
            else if (e.Key == Key.Right) ViewModel.NextCommand.Execute(null);
            else ViewModel.TogglePauseCommand.Execute(null);
        }
    }

    private void OnSelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (e.AddedItems.Count == 1 && e.AddedItems[0] is ClipItem item)
        {
            var index = ViewModel.Items.IndexOf(item);
            if (index >= 0 && index != ViewModel.SelectedIndex) _ = ViewModel.SelectFromUiAsync(index);
        }
    }

    private void OnPositionReleased(object sender, MouseButtonEventArgs e) =>
        _ = ViewModel.SeekToRatioAsync(PositionSlider.Value);

    private async void OnClosing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        _positionTimer.Stop();
        await ViewModel.DisposeAsync();
    }
}
