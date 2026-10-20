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
            MessageBox.Show("wrgent はすでに起動しています。タスクトレイを確認してください。", "wrgent");
            return 1;
        }
        ApplicationConfiguration.Initialize();
        Application.ThreadException += (_, e) => Log.Write($"ui exception: {e.Exception}");
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Log.Write($"unhandled: {e.ExceptionObject}");
        Application.Run(new MainForm());
        return 0;
    }
}
