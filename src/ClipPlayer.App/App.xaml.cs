using System.Windows;

namespace ClipPlayer.App;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        var window = new MainWindow(new MainViewModel(new WpfPlaybackPort()));
        MainWindow = window;
        window.Show();
        _ = window.ViewModel.InitializeAsync(e.Args);
    }
}
