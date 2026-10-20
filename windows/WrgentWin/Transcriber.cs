using System.Diagnostics;
using System.Text;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using Whisper.net;
using Whisper.net.Ggml;
using Whisper.net.LibraryLoader;

namespace WrgentWin;

/// <summary>
/// whisper.cpp（Whisper.net経由）でのローカル文字起こし。
/// GPUはVulkanで使い、Vulkanが使えない環境ではCPUに切り替わる。
/// 無音区間での幻聴を避けるため、Silero VADで話している区間だけを認識する。
/// </summary>
sealed class Transcriber : IDisposable
{
    private const int WhisperRate = 16000;
    private static readonly TimeSpan MaxChunk = TimeSpan.FromSeconds(28);
    private static readonly TimeSpan JoinGap = TimeSpan.FromSeconds(1.0);

    // 無音や雑音だけの区間で whisper がよく出す定型句。
    private static readonly string[] Hallucinations =
    {
        "ご視聴ありがとうございました", "ご清聴ありがとうございました", "チャンネル登録", "おやすみなさい",
        "最後までご視聴", "字幕", "Thank you for watching", "ありがとうございました。"
    };

    private readonly Settings _settings;
    private WhisperFactory? _factory;
    private WhisperVadFactory? _vadFactory;
    private readonly SemaphoreSlim _gate = new(1, 1);

    public string? RuntimeName { get; private set; }

    public Transcriber(Settings settings)
    {
        _settings = settings;
        // WRGENT_RUNTIME=cpu でGPUを使わずに比較できる。
        RuntimeOptions.RuntimeLibraryOrder = Environment.GetEnvironmentVariable("WRGENT_RUNTIME") == "cpu"
            ? new List<RuntimeLibrary> { RuntimeLibrary.Cpu }
            : new List<RuntimeLibrary> { RuntimeLibrary.Vulkan, RuntimeLibrary.Cpu };
    }

    private QuantizationType Quantization => _settings.ModelQuantization switch
    {
        "q8_0" => QuantizationType.Q8_0,
        "f16" => QuantizationType.NoQuantization,
        _ => QuantizationType.Q5_0
    };

    public string ModelPath => Path.Combine(_settings.ModelsDir, $"ggml-large-v3-turbo-{_settings.ModelQuantization}.bin");
    private string VadPath => Path.Combine(_settings.ModelsDir, "ggml-silero-v6.2.0.bin");

    public bool IsModelReady => File.Exists(ModelPath) && File.Exists(VadPath);

    /// <summary>モデルが無ければ取得する。progress には 0〜1 と説明を渡す。</summary>
    public async Task EnsureModelAsync(Action<double, string> progress, CancellationToken ct)
    {
        Directory.CreateDirectory(_settings.ModelsDir);
        if (!File.Exists(VadPath))
        {
            progress(0, "VADモデルを取得中");
            await using var vad = await WhisperGgmlDownloader.Default.GetGgmlSileroVadModelAsync(SileroVadType.V6_2_0, ct);
            await SaveAsync(vad, VadPath, null, _ => { }, ct);
        }
        if (!File.Exists(ModelPath))
        {
            Log.Write($"model: downloading {ModelPath}");
            await using var model = await WhisperGgmlDownloader.Default.GetGgmlModelAsync(GgmlType.LargeV3Turbo, Quantization, ct);
            long? expected = _settings.ModelQuantization switch { "q8_0" => 874_188_075, "f16" => 1_624_555_275, _ => 574_041_195 };
            await SaveAsync(model, ModelPath, expected,
                done => progress(expected is > 0 ? Math.Min(1, done / (double)expected.Value) : 0,
                                 $"文字起こしモデルを取得中 {done / 1_048_576} MB"), ct);
            Log.Write("model: downloaded");
        }
    }

    private static async Task SaveAsync(Stream source, string path, long? expected, Action<long> onBytes, CancellationToken ct)
    {
        var temp = path + ".part";
        await using (var dest = File.Create(temp))
        {
            var buffer = new byte[1 << 20];
            long total = 0;
            int n;
            var last = Stopwatch.StartNew();
            while ((n = await source.ReadAsync(buffer, ct)) > 0)
            {
                await dest.WriteAsync(buffer.AsMemory(0, n), ct);
                total += n;
                if (last.ElapsedMilliseconds > 200) { onBytes(total); last.Restart(); }
            }
            onBytes(total);
        }
        File.Move(temp, path, true);
    }

    private void EnsureLoaded()
    {
        if (_factory != null) return;
        var sw = Stopwatch.StartNew();
        _factory = WhisperFactory.FromPath(ModelPath, new WhisperFactoryOptions { UseGpu = true, UseFlashAttention = true });
        _vadFactory = WhisperVadFactory.FromPath(VadPath);
        RuntimeName = RuntimeOptions.LoadedLibrary?.ToString() ?? "unknown";
        Log.Write($"whisper: loaded {Path.GetFileName(ModelPath)} runtime={RuntimeName} in {sw.Elapsed.TotalSeconds:0.0}s");
    }

    /// <summary>音声ファイルを文字起こしし、テキストを返す。progress には 0〜1 を渡す。</summary>
    public async Task<string> TranscribeAsync(string audioPath, Action<double> progress, CancellationToken ct)
    {
        await _gate.WaitAsync(ct);
        try
        {
            EnsureLoaded();
            var sw = Stopwatch.StartNew();
            var samples = await Task.Run(() => LoadMono16k(audioPath), ct);
            var duration = TimeSpan.FromSeconds(samples.Length / (double)WhisperRate);
            var chunks = await Task.Run(() => SpeechChunks(samples), ct);
            Log.Write($"whisper: {Path.GetFileName(audioPath)} {duration:hh\\:mm\\:ss} -> {chunks.Count} speech chunks");

            await using var processor = _factory!.CreateBuilder()
                .WithLanguage(_settings.Language)
                .WithThreads(Math.Max(2, Environment.ProcessorCount / 2))
                .WithNoContext()
                .Build();

            var text = new StringBuilder();
            var done = 0.0;
            var total = chunks.Sum(c => (c.End - c.Start).TotalSeconds);
            foreach (var (start, end) in chunks)
            {
                ct.ThrowIfCancellationRequested();
                var from = (int)(start.TotalSeconds * WhisperRate);
                var to = Math.Min(samples.Length, (int)(end.TotalSeconds * WhisperRate));
                var slice = new float[to - from];
                Array.Copy(samples, from, slice, 0, slice.Length);

                await foreach (var seg in processor.ProcessAsync(slice, ct))
                {
                    var line = seg.Text.Trim();
                    if (line.Length == 0 || IsHallucination(line)) continue;
                    var at = start + seg.Start;
                    text.AppendLine($"[{(int)at.TotalHours:00}:{at.Minutes:00}:{at.Seconds:00}] {line}");
                }
                done += (end - start).TotalSeconds;
                progress(total > 0 ? done / total : 1);
            }

            var speed = sw.Elapsed.TotalSeconds > 0 ? duration.TotalSeconds / sw.Elapsed.TotalSeconds : 0;
            Log.Write($"whisper: done in {sw.Elapsed.TotalSeconds:0.0}s ({speed:0.0}x realtime, runtime={RuntimeName})");
            return text.ToString();
        }
        finally
        {
            _gate.Release();
        }
    }

    private static bool IsHallucination(string line)
    {
        var trimmed = line.Trim('。', '、', ' ', '.', '!', '！');
        return Hallucinations.Any(h => trimmed == h.TrimEnd('。') || (trimmed.Length < h.Length + 6 && trimmed.Contains(h.TrimEnd('。'))));
    }

    /// <summary>VADで話している区間を探し、近いもの同士を最大28秒程度にまとめる。</summary>
    private List<(TimeSpan Start, TimeSpan End)> SpeechChunks(float[] samples)
    {
        using var vad = _vadFactory!.CreateBuilder()
            .WithThreshold(0.5f)
            .WithMinSpeechDuration(TimeSpan.FromMilliseconds(250))
            .WithMinSilenceDuration(TimeSpan.FromMilliseconds(500))
            .WithMaxSpeechDuration(MaxChunk)
            .WithSpeechPadding(TimeSpan.FromMilliseconds(300))
            .Build();

        var raw = vad.DetectSpeech(samples).ToList();
        var chunks = new List<(TimeSpan Start, TimeSpan End)>();
        foreach (var s in raw)
        {
            if (chunks.Count > 0)
            {
                var last = chunks[^1];
                if (s.Start - last.End <= JoinGap && s.End - last.Start <= MaxChunk)
                {
                    chunks[^1] = (last.Start, s.End);
                    continue;
                }
            }
            chunks.Add((s.Start, s.End));
        }
        return chunks;
    }

    private static float[] LoadMono16k(string path)
    {
        using var reader = new AudioFileReader(path);
        ISampleProvider sp = reader.ToSampleProvider();
        if (sp.WaveFormat.Channels == 2)
            sp = new StereoToMonoSampleProvider(sp) { LeftVolume = 0.5f, RightVolume = 0.5f };
        else if (sp.WaveFormat.Channels > 2)
            sp = new MultiplexingSampleProvider(new[] { sp }, 1);
        if (sp.WaveFormat.SampleRate != WhisperRate)
            sp = new WdlResamplingSampleProvider(sp, WhisperRate);

        var estimated = (int)(reader.TotalTime.TotalSeconds * WhisperRate) + WhisperRate;
        var result = new List<float>(Math.Max(estimated, WhisperRate));
        var buffer = new float[WhisperRate];
        int n;
        while ((n = sp.Read(buffer, 0, buffer.Length)) > 0)
            result.AddRange(new ArraySegment<float>(buffer, 0, n));
        return result.ToArray();
    }

    public void Dispose()
    {
        _factory?.Dispose();
        _vadFactory?.Dispose();
    }
}
