namespace WrgentWin;

static class Log
{
    private static readonly object Gate = new();

    public static string FilePath => Path.Combine(Settings.AppDataDir, "wrgent_log.txt");

    public static void Write(string message)
    {
        try
        {
            lock (Gate)
            {
                Directory.CreateDirectory(Settings.AppDataDir);
                File.AppendAllText(FilePath, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {message}{Environment.NewLine}");
            }
        }
        catch
        {
            // ログ書き込みの失敗で録音を止めない。
        }
    }
}
