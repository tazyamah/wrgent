namespace WrgentWin;

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        if (args.Length > 0 && args[0].StartsWith("--"))
            return Cli.Run(args);

        using var mutex = new Mutex(true, "wrgent-win-single-instance", out var isFirst);
        if (!isFirst)
        {
            System.Windows.MessageBox.Show("wrgent はすでに起動しています。タスクトレイのアイコンから開けます。", "wrgent");
            return 1;
        }
        var app = new System.Windows.Application { ShutdownMode = System.Windows.ShutdownMode.OnExplicitShutdown };
        app.DispatcherUnhandledException += (_, e) =>
        {
            Log.Write($"ui exception: {e.Exception}");
            e.Handled = true;
        };
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Log.Write($"unhandled: {e.ExceptionObject}");
        var window = new MainWindow();
        window.ShowPopover();
        app.Run();
        return 0;
    }
}
