using System.Diagnostics;
using System.Runtime.InteropServices;

namespace WrgentWin;

/// <summary>動作確認用のコマンドライン。結果はログとファイルに書く。</summary>
static class Cli
{
    public static int Run(string[] args)
    {
        AttachConsole(-1);
        try
        {
            switch (args[0])
            {
                case "--transcribe" when args.Length >= 2:
                {
                    var settings = Settings.Load();
                    if (args.Length >= 3) settings.ModelQuantization = args[2];
                    using var t = new Transcriber(settings);
                    t.EnsureModelAsync((p, m) => { }, CancellationToken.None).GetAwaiter().GetResult();
                    var sw = Stopwatch.StartNew();
                    var text = t.TranscribeAsync(args[1], _ => { }, CancellationToken.None).GetAwaiter().GetResult();
                    var output = Path.ChangeExtension(args[1], $".{settings.ModelQuantization}.txt");
                    File.WriteAllText(output, text);
                    Console.WriteLine($"runtime={t.RuntimeName} seconds={sw.Elapsed.TotalSeconds:0.0} -> {output}");
                    return 0;
                }
                case "--record" when args.Length >= 3:
                {
                    using var r = new AudioRecorder();
                    var wav = Path.Combine(args[2], "recording.wav");
                    r.Start(wav, true, true, true);
                    Console.WriteLine($"mic={r.MicDeviceName} system={r.SystemDeviceName}");
                    float micMax = 0, sysMax = 0;
                    var until = DateTime.Now.AddSeconds(double.Parse(args[1]));
                    while (DateTime.Now < until)
                    {
                        micMax = Math.Max(micMax, r.MicLevel);
                        sysMax = Math.Max(sysMax, r.SystemLevel);
                        Thread.Sleep(50);
                    }
                    Console.WriteLine($"peak mic={micMax:0.000000} system={sysMax:0.000000} micMuted={r.MicMuted} unmutedByApp={r.MicUnmutedByApp}");
                    var elapsed = r.Stop();
                    AudioRecorder.EncodeToM4a(wav, Path.Combine(args[2], "mix.m4a"));
                    Console.WriteLine($"elapsed={elapsed.TotalSeconds:0.00}");
                    return 0;
                }
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine(ex);
            Log.Write($"cli: {ex}");
            return 1;
        }
        Console.WriteLine("usage: wrgent --transcribe <audio> [q5_0|q8_0] | --record <seconds> <dir>");
        return 2;
    }

    [DllImport("kernel32.dll")] private static extern bool AttachConsole(int pid);
}
