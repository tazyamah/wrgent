using System.Diagnostics;
using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;
using NAudio.MediaFoundation;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace WrgentWin;

/// <summary>
/// マイクとPCの再生音を同時に取り込み、1本の音声に混ぜて保存する。
/// PCの音は「有効なすべての再生デバイス」のループバックを混ぜるので、アプリがどの出力に鳴らしていても録れる。
/// 録音中にデバイスの追加・削除・既定の切り替えがあれば、その場で取り込み先を付け替える。
/// 各デバイスは時計が別なので、入力ごとにバッファに溜め、書き込み側は実時間で一定量ずつ取り出す。
/// 音が鳴っていない間のループバックはデータが来ないため、その分は無音で埋める。
/// </summary>
sealed class AudioRecorder : IDisposable
{
    internal const int SampleRate = 48000;
    internal const int Channels = 2;
    private static readonly TimeSpan StartLatency = TimeSpan.FromMilliseconds(250);
    private static readonly TimeSpan ReconcileDelay = TimeSpan.FromMilliseconds(80);

    private readonly object _sync = new();
    private readonly Dictionary<string, CaptureSource> _loopbacks = new();
    private CaptureSource? _mic;
    private MMDevice? _micDevice;
    private MixingSampleProvider? _mixer;
    private MMDeviceEnumerator? _enumerator;
    private DeviceWatcher? _watcher;
    private Timer? _reconcileTimer;
    private MicMuteGuard? _muteGuard;
    private WaveFileWriter? _writer;
    private Thread? _pumpThread;
    private volatile bool _running;
    private bool _recordMic, _recordSystem, _unmuteMic;
    private readonly Stopwatch _clock = new();

    public string? WavPath { get; private set; }
    public TimeSpan Elapsed => _clock.Elapsed;
    public bool IsRecording => _running;

    /// <summary>0〜1 の直近ピーク。UIのレベル表示用。</summary>
    public float MicLevel => _mic?.Level ?? 0;
    public float SystemLevel
    {
        get
        {
            lock (_sync) return _loopbacks.Values.Select(s => s.Level).DefaultIfEmpty(0).Max();
        }
    }

    public string MicDeviceName { get; private set; } = "";
    public string SystemDeviceName { get; private set; } = "";

    /// <summary>Windows側でマイクがミュート（または音量0）のままになっている。</summary>
    public bool MicMuted { get; private set; }

    /// <summary>録音のためにWindowsのマイクミュートを一時的に解除している。</summary>
    public bool MicUnmutedByApp => _muteGuard?.Active == true;

    public event Action<string>? Error;

    /// <summary>取り込み中のデバイスが変わった。UIの表示更新用。</summary>
    public event Action? DevicesChanged;

    public void Start(string wavPath, bool recordMic, bool recordSystem, bool unmuteMic)
    {
        if (_running) return;
        if (!recordMic && !recordSystem) throw new InvalidOperationException("マイクとPC音声のどちらも無効です。");

        WavPath = wavPath;
        _recordMic = recordMic;
        _recordSystem = recordSystem;
        _unmuteMic = unmuteMic;
        _mixer = new MixingSampleProvider(WaveFormat.CreateIeeeFloatWaveFormat(SampleRate, Channels)) { ReadFully = true };
        _enumerator = new MMDeviceEnumerator();

        Directory.CreateDirectory(Path.GetDirectoryName(wavPath)!);
        _writer = new WaveFileWriter(wavPath, new WaveFormat(SampleRate, 16, Channels));

        lock (_sync)
        {
            _running = true;
            Reconcile();
        }
        if (_loopbacks.Count == 0 && _mic == null)
        {
            Stop();
            throw new InvalidOperationException("録音できる入力が見つかりません。");
        }

        _watcher = new DeviceWatcher(ScheduleReconcile);
        _enumerator.RegisterEndpointNotificationCallback(_watcher);
        _reconcileTimer = new Timer(_ => { lock (_sync) Reconcile(); });

        Log.Write($"rec: start mic=\"{MicDeviceName}\" system=\"{SystemDeviceName}\" -> {wavPath}");
        _clock.Restart();
        _pumpThread = new Thread(() => Pump(_mixer)) { IsBackground = true, Name = "wrgent-pump", Priority = ThreadPriority.AboveNormal };
        _pumpThread.Start();
    }

    /// <summary>録音を止め、WAVを閉じる。戻り値は録音時間。</summary>
    public TimeSpan Stop()
    {
        if (_writer == null) return TimeSpan.Zero;
        _running = false;
        _pumpThread?.Join();
        _pumpThread = null;
        var elapsed = _clock.Elapsed;
        _clock.Stop();

        if (_watcher != null) { try { _enumerator?.UnregisterEndpointNotificationCallback(_watcher); } catch { } }
        _watcher = null;
        _reconcileTimer?.Dispose();
        _reconcileTimer = null;

        lock (_sync)
        {
            foreach (var s in _loopbacks.Values) s.Dispose();
            _loopbacks.Clear();
            _mic?.Dispose();
            _mic = null;
            _micDevice = null;
            _muteGuard?.Restore();
            _muteGuard = null;
        }
        _enumerator?.Dispose();
        _enumerator = null;
        _writer?.Dispose();
        _writer = null;
        MicMuted = false;
        Log.Write($"rec: stop {elapsed:hh\\:mm\\:ss}");
        return elapsed;
    }

    private void ScheduleReconcile()
    {
        // 通知はCOMのスレッドから来るので、そこでは何もしない。続けて届く通知をまとめるため、ごく短く待つ。
        try { _reconcileTimer?.Change(ReconcileDelay, Timeout.InfiniteTimeSpan); } catch (ObjectDisposedException) { }
    }

    /// <summary>今あるデバイスと取り込み中のデバイスを突き合わせ、足りないものを開き、消えたものを閉じる。</summary>
    private void Reconcile()
    {
        if (!_running || _enumerator == null || _mixer == null) return;
        var changed = false;

        if (_recordSystem)
        {
            var active = new Dictionary<string, MMDevice>();
            try
            {
                foreach (var d in _enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active)) active[d.ID] = d;
            }
            catch (Exception ex)
            {
                Log.Write($"rec: enumerate render failed {ex.Message}");
            }

            foreach (var (id, source) in _loopbacks.ToList())
            {
                if (active.ContainsKey(id) && !source.Faulted) continue;
                _mixer.RemoveMixerInput(source);
                source.Dispose();
                _loopbacks.Remove(id);
                Log.Write($"rec: loopback removed \"{source.Name}\"");
                changed = true;
            }
            foreach (var (id, device) in active)
            {
                if (_loopbacks.ContainsKey(id)) continue;
                var source = CaptureSource.TryOpen(device, loopback: true, OnSourceFaulted);
                if (source == null) continue;
                _loopbacks[id] = source;
                _mixer.AddMixerInput(source);
                Log.Write($"rec: loopback added \"{source.Name}\"");
                changed = true;
            }

            string? defaultName = null;
            try { defaultName = _enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia).FriendlyName; } catch { }
            var names = _loopbacks.Values.Select(s => s.Name).ToList();
            SystemDeviceName = names.Count == 0 ? "" :
                defaultName != null && names.Count > 1 ? $"{defaultName} ほか{names.Count - 1}" : defaultName ?? names[0];
        }

        if (_recordMic)
        {
            var device = DefaultMic();
            if (device == null)
            {
                if (_mic != null)
                {
                    _mixer.RemoveMixerInput(_mic);
                    _mic.Dispose();
                    _mic = null;
                    changed = true;
                }
                MicDeviceName = "";
                _micDevice = null;
            }
            else if (_mic == null || _mic.Faulted || _mic.DeviceId != device.ID)
            {
                if (_mic != null)
                {
                    _mixer.RemoveMixerInput(_mic);
                    _mic.Dispose();
                    Log.Write($"rec: mic removed \"{_mic.Name}\"");
                }
                _muteGuard?.Restore();
                _muteGuard = _unmuteMic ? MicMuteGuard.Unmute(device) : null;
                _mic = CaptureSource.TryOpen(device, loopback: false, OnSourceFaulted);
                if (_mic != null)
                {
                    _mixer.AddMixerInput(_mic);
                    Log.Write($"rec: mic added \"{_mic.Name}\"{(_muteGuard?.Active == true ? " (unmuted for recording)" : "")}");
                }
                MicDeviceName = _mic?.Name ?? "";
                _micDevice = _mic != null ? device : null;
                changed = true;
            }
            MicMuted = device != null && IsMuted(device);
        }

        if (changed) DevicesChanged?.Invoke();
    }

    /// <summary>今この瞬間、録音中のマイクがWindowsでミュートされているか。</summary>
    public bool IsMicMutedNow()
    {
        MMDevice? device;
        lock (_sync) device = _micDevice;
        return device != null && IsMuted(device);
    }

    private MMDevice? DefaultMic()
    {
        foreach (var role in new[] { Role.Communications, Role.Console })
        {
            try { return _enumerator!.GetDefaultAudioEndpoint(DataFlow.Capture, role); }
            catch { }
        }
        return null;
    }

    private static bool IsMuted(MMDevice device)
    {
        try
        {
            var v = device.AudioEndpointVolume;
            return v.Mute || v.MasterVolumeLevelScalar < 0.01f;
        }
        catch
        {
            return false;
        }
    }

    private void OnSourceFaulted(CaptureSource source, Exception ex)
    {
        Log.Write($"rec: \"{source.Name}\" stopped {ex.Message}; reopening");
        ScheduleReconcile();
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
                for (var i = 0; i < read; i++) chunk[i] = Math.Clamp(chunk[i], -1f, 1f);
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
        var tail = new float[(int)(StartLatency.TotalSeconds * SampleRate) * Channels];
        var n = mixer.Read(tail, 0, tail.Length);
        for (var i = 0; i < n; i++) tail[i] = Math.Clamp(tail[i], -1f, 1f);
        _writer!.WriteSamples(tail, 0, n);
    }

    public void Dispose() => Stop();

    /// <summary>WAVをAAC(M4A)に変換する。Windows標準のMedia Foundationエンコーダを使う。</summary>
    public static void EncodeToM4a(string wavPath, string m4aPath)
    {
        MediaFoundationApi.Startup();
        using var reader = new WaveFileReader(wavPath);
        MediaFoundationEncoder.EncodeToAac(reader, m4aPath, 160_000);
    }

    private sealed class DeviceWatcher : IMMNotificationClient
    {
        private readonly Action _changed;
        public DeviceWatcher(Action changed) => _changed = changed;
        public void OnDeviceStateChanged(string deviceId, DeviceState newState) => _changed();
        public void OnDeviceAdded(string pwstrDeviceId) => _changed();
        public void OnDeviceRemoved(string deviceId) => _changed();
        public void OnDefaultDeviceChanged(DataFlow flow, Role role, string defaultDeviceId) => _changed();
        public void OnPropertyValueChanged(string pwstrDeviceId, PropertyKey key) { }
    }
}

/// <summary>1つのデバイスからの取り込み。48kHzステレオのfloatに揃えてミキサーへ渡す。</summary>
sealed class CaptureSource : ISampleProvider, IDisposable
{
    private readonly WasapiCapture _capture;
    private readonly BufferedWaveProvider _buffer;
    private readonly ISampleProvider _converted;
    private readonly Action<CaptureSource, Exception> _onFault;
    private float _peak;
    private long _peakTicks;
    private volatile bool _disposed;

    public string DeviceId { get; }
    public string Name { get; }
    public bool Faulted { get; private set; }
    public WaveFormat WaveFormat { get; } = WaveFormat.CreateIeeeFloatWaveFormat(AudioRecorder.SampleRate, AudioRecorder.Channels);

    /// <summary>直近0.3秒以内のピーク。データが来ていなければ0。</summary>
    public float Level => Environment.TickCount64 - Interlocked.Read(ref _peakTicks) < 300 ? _peak : 0;

    private CaptureSource(MMDevice device, bool loopback, Action<CaptureSource, Exception> onFault)
    {
        DeviceId = device.ID;
        Name = device.FriendlyName;
        _onFault = onFault;
        _capture = loopback ? new WasapiLoopbackCapture(device) : new WasapiCapture(device, true, 20);
        _buffer = new BufferedWaveProvider(_capture.WaveFormat)
        {
            BufferDuration = TimeSpan.FromSeconds(5),
            DiscardOnBufferOverflow = true,
            ReadFully = true
        };
        _converted = ToTarget(_buffer);
        _capture.DataAvailable += (_, e) =>
        {
            _buffer.AddSamples(e.Buffer, 0, e.BytesRecorded);
            _peak = Peak(e.Buffer, e.BytesRecorded, _capture.WaveFormat);
            Interlocked.Exchange(ref _peakTicks, Environment.TickCount64);
        };
        _capture.RecordingStopped += (_, e) =>
        {
            if (_disposed || e.Exception == null) return;
            Faulted = true;
            _onFault(this, e.Exception);
        };
    }

    public static CaptureSource? TryOpen(MMDevice device, bool loopback, Action<CaptureSource, Exception> onFault)
    {
        try
        {
            var source = new CaptureSource(device, loopback, onFault);
            source._capture.StartRecording();
            return source;
        }
        catch (Exception ex)
        {
            Log.Write($"rec: open \"{device.FriendlyName}\" failed {ex.Message}");
            return null;
        }
    }

    public int Read(float[] buffer, int offset, int count)
    {
        if (_disposed || Faulted)
        {
            Array.Clear(buffer, offset, count);
            return count;
        }
        return _converted.Read(buffer, offset, count);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        try { _capture.StopRecording(); } catch { }
        try { _capture.Dispose(); } catch { }
    }

    private static ISampleProvider ToTarget(IWaveProvider source)
    {
        ISampleProvider sp = source.ToSampleProvider();
        if (sp.WaveFormat.Channels == 1)
            sp = new MonoToStereoSampleProvider(sp);
        else if (sp.WaveFormat.Channels > 2)
            sp = new MultiplexingSampleProvider(new[] { sp }, 2);
        if (sp.WaveFormat.SampleRate != AudioRecorder.SampleRate)
            sp = new WdlResamplingSampleProvider(sp, AudioRecorder.SampleRate);
        return sp;
    }

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
}

/// <summary>
/// Windowsでマイクがミュート（または音量がほぼ0）のとき、録音中だけ解除して元に戻す。
/// ミュートはデバイス側で掛かるので、解除しないとどのアプリも無音しか受け取れない。
/// </summary>
sealed class MicMuteGuard
{
    private const float MinVolume = 0.5f;
    private readonly MMDevice _device;
    private readonly bool _wasMuted;
    private readonly float? _previousVolume;

    public bool Active { get; private set; }

    private MicMuteGuard(MMDevice device, bool wasMuted, float? previousVolume)
    {
        _device = device;
        _wasMuted = wasMuted;
        _previousVolume = previousVolume;
        Active = wasMuted || previousVolume.HasValue;
    }

    public static MicMuteGuard? Unmute(MMDevice device)
    {
        try
        {
            var v = device.AudioEndpointVolume;
            var wasMuted = v.Mute;
            float? previous = v.MasterVolumeLevelScalar < 0.01f ? v.MasterVolumeLevelScalar : null;
            if (!wasMuted && previous == null) return null;
            if (wasMuted) v.Mute = false;
            if (previous.HasValue) v.MasterVolumeLevelScalar = MinVolume;
            return new MicMuteGuard(device, wasMuted, previous);
        }
        catch (Exception ex)
        {
            Log.Write($"rec: unmute \"{device.FriendlyName}\" failed {ex.Message}");
            return null;
        }
    }

    /// <summary>録音前の状態に戻す。音量は録音中に別の値へ変えられていればそのままにする。</summary>
    public void Restore()
    {
        if (!Active) return;
        Active = false;
        try
        {
            var v = _device.AudioEndpointVolume;
            if (_previousVolume.HasValue && Math.Abs(v.MasterVolumeLevelScalar - MinVolume) < 0.02f)
                v.MasterVolumeLevelScalar = _previousVolume.Value;
            if (_wasMuted && !v.Mute) v.Mute = true;
            Log.Write($"rec: restored mute state of \"{_device.FriendlyName}\"");
        }
        catch (Exception ex)
        {
            Log.Write($"rec: restore mute failed {ex.Message}");
        }
    }
}
