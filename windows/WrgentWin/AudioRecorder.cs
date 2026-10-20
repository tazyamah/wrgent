using System.Diagnostics;
using NAudio.CoreAudioApi;
using NAudio.MediaFoundation;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace WrgentWin;

/// <summary>
/// マイクとPCの再生音（WASAPIループバック）を同時に取り込み、1本の音声に混ぜて保存する。
/// 2つのデバイスは時計が別なので、各入力をバッファに溜め、書き込み側は実時間で一定量ずつ取り出す。
/// 音が鳴っていない間のループバックはデータが来ないため、その分は無音で埋める。
/// </summary>
sealed class AudioRecorder : IDisposable
{
    private const int SampleRate = 48000;
    private const int Channels = 2;
    private static readonly TimeSpan StartLatency = TimeSpan.FromMilliseconds(250);

    private WasapiCapture? _mic;
    private WasapiLoopbackCapture? _loopback;
    private BufferedWaveProvider? _micBuffer;
    private BufferedWaveProvider? _loopBuffer;
    private WaveFileWriter? _writer;
    private Thread? _pumpThread;
    private volatile bool _running;
    private readonly Stopwatch _clock = new();

    public string? WavPath { get; private set; }
    public TimeSpan Elapsed => _clock.Elapsed;
    public bool IsRecording => _running;

    /// <summary>0〜1 の直近ピーク。UIのレベル表示用。</summary>
    public float MicLevel { get; private set; }
    public float SystemLevel { get; private set; }

    public string MicDeviceName { get; private set; } = "";
    public string SystemDeviceName { get; private set; } = "";

    public event Action<string>? Error;

    public void Start(string wavPath, bool recordMic, bool recordSystem)
    {
        if (_running) return;
        if (!recordMic && !recordSystem) throw new InvalidOperationException("マイクとPC音声のどちらも無効です。");

        WavPath = wavPath;
        var mixer = new MixingSampleProvider(WaveFormat.CreateIeeeFloatWaveFormat(SampleRate, Channels))
        {
            ReadFully = true
        };

        using var enumerator = new MMDeviceEnumerator();
        if (recordSystem)
        {
            var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            SystemDeviceName = device.FriendlyName;
            _loopback = new WasapiLoopbackCapture(device);
            _loopBuffer = CreateBuffer(_loopback.WaveFormat);
            _loopback.DataAvailable += (_, e) =>
            {
                _loopBuffer.AddSamples(e.Buffer, 0, e.BytesRecorded);
                SystemLevel = Peak(e.Buffer, e.BytesRecorded, _loopback.WaveFormat);
            };
            _loopback.RecordingStopped += (_, e) => OnDeviceStopped("PC音声", e.Exception);
            mixer.AddMixerInput(ToTarget(_loopBuffer));
        }

        if (recordMic)
        {
            var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications);
            MicDeviceName = device.FriendlyName;
            _mic = new WasapiCapture(device, true, 20);
            _micBuffer = CreateBuffer(_mic.WaveFormat);
            _mic.DataAvailable += (_, e) =>
            {
                _micBuffer.AddSamples(e.Buffer, 0, e.BytesRecorded);
                MicLevel = Peak(e.Buffer, e.BytesRecorded, _mic.WaveFormat);
            };
            _mic.RecordingStopped += (_, e) => OnDeviceStopped("マイク", e.Exception);
            mixer.AddMixerInput(ToTarget(_micBuffer));
        }

        Directory.CreateDirectory(Path.GetDirectoryName(wavPath)!);
        _writer = new WaveFileWriter(wavPath, new WaveFormat(SampleRate, 16, Channels));
        Log.Write($"rec: start mic=\"{MicDeviceName}\" system=\"{SystemDeviceName}\" -> {wavPath}");

        _loopback?.StartRecording();
        _mic?.StartRecording();
        _running = true;
        _clock.Restart();
        _pumpThread = new Thread(() => Pump(mixer)) { IsBackground = true, Name = "wrgent-pump", Priority = ThreadPriority.AboveNormal };
        _pumpThread.Start();
    }

    /// <summary>録音を止め、WAVを閉じる。戻り値は録音時間。</summary>
    public TimeSpan Stop()
    {
        if (!_running) return TimeSpan.Zero;
        _running = false;
        _pumpThread?.Join();
        var elapsed = _clock.Elapsed;
        _clock.Stop();
        try { _mic?.StopRecording(); } catch { }
        try { _loopback?.StopRecording(); } catch { }
        _writer?.Dispose();
        _writer = null;
        Log.Write($"rec: stop {elapsed:hh\\:mm\\:ss}");
        DisposeDevices();
        MicLevel = SystemLevel = 0;
        return elapsed;
    }

    private void Pump(ISampleProvider mixer)
    {
        // 書き込みは開始から少し遅らせ、各バッファに余裕を持たせる。
        var chunk = new float[SampleRate / 50 * Channels];
        long written = 0;
        while (_running)
        {
            var due = (long)((_clock.Elapsed - StartLatency).TotalSeconds * SampleRate);
            while (written + chunk.Length / Channels <= due)
            {
                var read = mixer.Read(chunk, 0, chunk.Length);
                for (var i = 0; i < read; i++) chunk[i] = SoftClip(chunk[i]);
                try
                {
                    _writer!.WriteSamples(chunk, 0, read);
                }
                catch (Exception ex)
                {
                    Log.Write($"rec: write failed {ex}");
                    Error?.Invoke($"書き込みに失敗しました: {ex.Message}");
                    _running = false;
                    return;
                }
                written += read / Channels;
            }
            Thread.Sleep(10);
        }
        // 停止時はバッファに残った分も書き出す。
        var remaining = (int)Math.Min(StartLatency.TotalSeconds * SampleRate * Channels, chunk.Length * 20);
        var tail = new float[remaining];
        var n = mixer.Read(tail, 0, tail.Length);
        for (var i = 0; i < n; i++) tail[i] = SoftClip(tail[i]);
        _writer!.WriteSamples(tail, 0, n);
    }

    private void OnDeviceStopped(string label, Exception? ex)
    {
        if (ex == null || !_running) return;
        Log.Write($"rec: {label} stopped unexpectedly {ex}");
        Error?.Invoke($"{label}の取り込みが止まりました（{ex.Message}）。録音は続けますが、この入力は無音になります。");
    }

    private static BufferedWaveProvider CreateBuffer(WaveFormat format) => new(format)
    {
        BufferDuration = TimeSpan.FromSeconds(5),
        DiscardOnBufferOverflow = true,
        ReadFully = true
    };

    private static ISampleProvider ToTarget(IWaveProvider source)
    {
        ISampleProvider sp = source.ToSampleProvider();
        if (sp.WaveFormat.Channels == 1)
            sp = new MonoToStereoSampleProvider(sp);
        else if (sp.WaveFormat.Channels > 2)
            sp = new MultiplexingSampleProvider(new[] { sp }, 2);
        if (sp.WaveFormat.SampleRate != SampleRate)
            sp = new WdlResamplingSampleProvider(sp, SampleRate);
        return sp;
    }

    private static float SoftClip(float x) => x switch
    {
        > 1f => 1f,
        < -1f => -1f,
        _ => x
    };

    private static float Peak(byte[] buffer, int bytes, WaveFormat format)
    {
        var peak = 0f;
        if (format.Encoding == WaveFormatEncoding.IeeeFloat ||
            (format.Encoding == WaveFormatEncoding.Extensible && format.BitsPerSample == 32))
        {
            for (var i = 0; i + 3 < bytes; i += 4)
                peak = Math.Max(peak, Math.Abs(BitConverter.ToSingle(buffer, i)));
        }
        else if (format.BitsPerSample == 16)
        {
            for (var i = 0; i + 1 < bytes; i += 2)
                peak = Math.Max(peak, Math.Abs(BitConverter.ToInt16(buffer, i) / 32768f));
        }
        return Math.Min(1f, peak);
    }

    private void DisposeDevices()
    {
        _mic?.Dispose();
        _loopback?.Dispose();
        _mic = null;
        _loopback = null;
        _micBuffer = null;
        _loopBuffer = null;
    }

    public void Dispose()
    {
        Stop();
        DisposeDevices();
    }

    /// <summary>WAVをAAC(M4A)に変換する。Windows標準のMedia Foundationエンコーダを使う。</summary>
    public static void EncodeToM4a(string wavPath, string m4aPath)
    {
        MediaFoundationApi.Startup();
        using var reader = new WaveFileReader(wavPath);
        MediaFoundationEncoder.EncodeToAac(reader, m4aPath, 160_000);
    }
}
