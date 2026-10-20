using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;
using Forms = System.Windows.Forms;
using Drawing = System.Drawing;

namespace WrgentWin;

public partial class MainWindow : Window
{
    private const int HotkeyId = 0x5752;
    private const string AudioFileName = "mix.m4a";
    private const string WavFileName = "recording.wav";
    private const string TranscriptFileName = "transcript.txt";

    private readonly Settings _settings = Settings.Load();
    private readonly AudioRecorder _recorder = new();
    private readonly Transcriber _transcriber;
    private readonly DispatcherTimer _meterTimer = new() { Interval = TimeSpan.FromMilliseconds(80) };
    private readonly ObservableCollection<RecordingItem> _items = new();
    private readonly HashSet<string> _busy = new(StringComparer.OrdinalIgnoreCase);
    private readonly Forms.NotifyIcon _tray = new();
    private readonly Forms.ToolStripMenuItem _trayRecord = new("録音を開始");
    private Drawing.Icon _idleIcon = null!;
    private Drawing.Icon _recordingIcon = null!;
    private Storyboard? _pulse;
    private string? _currentDir;
    private bool _pinned;
    private bool _modal;
    private bool _quitting;
    private double _micShown, _sysShown;

    public MainWindow()
    {
        InitializeComponent();
        _transcriber = new Transcriber(_settings);
        Theme.Apply(Resources);
        SystemEvents.UserPreferenceChanged += (_, _) => Dispatcher.BeginInvoke(() => Theme.Apply(Resources));

        LoadIcons();
        BuildTray();

        MicToggle.IsChecked = _settings.RecordMicrophone;
        SysToggle.IsChecked = _settings.RecordSystemAudio;
        AutoToggle.IsChecked = _settings.AutoTranscribe;
        MicToggle.Click += (_, _) => { _settings.RecordMicrophone = MicToggle.IsChecked == true; _settings.Save(); };
        SysToggle.Click += (_, _) => { _settings.RecordSystemAudio = SysToggle.IsChecked == true; _settings.Save(); };
        AutoToggle.Click += (_, _) => { _settings.AutoTranscribe = AutoToggle.IsChecked == true; _settings.Save(); };

        RecordingList.ItemsSource = _items;
        RecordButton.Click += (_, _) => ToggleRecording();
        FolderButton.Click += (_, _) => OpenPath(_settings.LibraryDir);
        PinButton.Click += (_, _) => SetPinned(!_pinned);
        HideButton.Click += (_, _) => Hide();
        LibraryButton.Click += (_, _) => ChooseLibrary();
        QuitButton.Click += (_, _) => Quit();
        Header.MouseLeftButtonDown += (_, e) => { if (_pinned && e.ButtonState == MouseButtonState.Pressed) DragMove(); };
        NameBox.KeyDown += (_, e) => { if (e.Key == Key.Enter) ToggleRecording(); };

        _recorder.Error += msg => Dispatcher.BeginInvoke(() => ShowTask(msg, null));
        _meterTimer.Tick += (_, _) => UpdateMeters();
        Deactivated += (_, _) => { if (!_pinned && !_modal && IsVisible) Hide(); };
        Closing += (_, e) => { if (!_quitting) { e.Cancel = true; Hide(); } };
        KeyDown += (_, e) => { if (e.Key == Key.Escape && !_pinned) Hide(); };

        SourceInitialized += (_, _) =>
        {
            var handle = new WindowInteropHelper(this).Handle;
            HwndSource.FromHwnd(handle)!.AddHook(WndProc);
            RegisterHotKey(handle, HotkeyId, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, (uint)Forms.Keys.R);
        };
        Loaded += (_, _) =>
        {
            RefreshList();
            SetIdleVisuals();
            UpdateEngineText();
            if (!_transcriber.IsModelReady) _ = PrepareModelAsync();
        };
    }

    // ---- 表示位置・トレイ ----

    /// <summary>タスクトレイの上に、Mac版のメニューバーのように表示する。</summary>
    public void ShowPopover()
    {
        if (!_pinned)
        {
            var area = SystemParameters.WorkArea;
            Left = area.Right - Width + 4;
            Top = area.Bottom - Height + 4;
        }
        Show();
        Activate();
        Opacity = 0;
        BeginAnimation(OpacityProperty, new DoubleAnimation(1, TimeSpan.FromMilliseconds(120)));
    }

    private void SetPinned(bool pinned)
    {
        _pinned = pinned;
        Topmost = !pinned;
        ShowInTaskbar = pinned;
        PinButton.Content = pinned ? "" : "";
        PinButton.Foreground = pinned ? (Brush)Resources["Accent"] : (Brush)Resources["TextSecondary"];
        PinButton.ToolTip = pinned ? "固定を解除（フォーカスが外れたら隠す）" : "ウィンドウを固定（ドラッグで移動できます）";
        Header.Cursor = pinned ? Cursors.SizeAll : null;
    }

    private void LoadIcons()
    {
        using (var s = typeof(MainWindow).Assembly.GetManifestResourceStream("WrgentWin.app.ico")!)
            _idleIcon = new Drawing.Icon(s, 32, 32);
        using (var s = typeof(MainWindow).Assembly.GetManifestResourceStream("WrgentWin.app.ico")!)
            Logo.Source = BitmapFrame.Create(s, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);

        // 録音中は右下に赤い点を付けたアイコンにする。
        using var bmp = _idleIcon.ToBitmap();
        using (var g = Drawing.Graphics.FromImage(bmp))
        {
            g.SmoothingMode = Drawing.Drawing2D.SmoothingMode.AntiAlias;
            g.FillEllipse(Drawing.Brushes.White, 15, 15, 17, 17);
            using var red = new Drawing.SolidBrush(Drawing.Color.FromArgb(229, 55, 46));
            g.FillEllipse(red, 17, 17, 13, 13);
        }
        _recordingIcon = Drawing.Icon.FromHandle(bmp.GetHicon());
        Icon = Logo.Source;
    }

    private void BuildTray()
    {
        _tray.Icon = _idleIcon;
        _tray.Text = "wrgent";
        _tray.Visible = true;
        var menu = new Forms.ContextMenuStrip();
        _trayRecord.Click += (_, _) => ToggleRecording();
        menu.Items.Add(_trayRecord);
        menu.Items.Add("開く", null, (_, _) => ShowPopover());
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("終了", null, (_, _) => Quit());
        _tray.ContextMenuStrip = menu;
        _tray.MouseClick += (_, e) =>
        {
            if (e.Button != Forms.MouseButtons.Left) return;
            if (IsVisible) Hide(); else ShowPopover();
        };
    }

    // ---- 録音 ----

    private void ToggleRecording()
    {
        if (_recorder.IsRecording) StopRecording();
        else StartRecording();
    }

    private void StartRecording()
    {
        var name = SanitizeName(NameBox.Text);
        var folder = DateTime.Now.ToString("yyyyMMdd_HHmmss") + (name.Length > 0 ? " - " + name : "");
        _currentDir = Path.Combine(_settings.LibraryDir, folder);
        try
        {
            _recorder.Start(Path.Combine(_currentDir, WavFileName), MicToggle.IsChecked == true, SysToggle.IsChecked == true);
        }
        catch (Exception ex)
        {
            Log.Write($"rec: start failed {ex}");
            _currentDir = null;
            ShowTask($"録音を開始できませんでした: {ex.Message}", null);
            return;
        }

        MicName.Text = _recorder.MicDeviceName.Length > 0 ? _recorder.MicDeviceName : "マイク（オフ）";
        SysName.Text = _recorder.SystemDeviceName.Length > 0 ? _recorder.SystemDeviceName : "PCの音（オフ）";
        SetRecordingVisuals();
        if (_recorder.MicMuted)
        {
            MicName.Text = "マイクがWindowsでミュートされています";
            MicName.SetResourceReference(ForegroundProperty, "Orange");
        }
        _meterTimer.Start();
        RefreshList();
    }

    private void StopRecording()
    {
        var elapsed = _recorder.Stop();
        _meterTimer.Stop();
        var dir = _currentDir!;
        _currentDir = null;
        NameBox.Text = "";
        SetIdleVisuals();
        _ = FinishRecordingAsync(dir, elapsed);
    }

    private async Task FinishRecordingAsync(string dir, TimeSpan elapsed)
    {
        var wav = Path.Combine(dir, WavFileName);
        var m4a = Path.Combine(dir, AudioFileName);
        _busy.Add(dir);
        RefreshList();
        SetStatus("録音を保存中…", "Orange");
        try
        {
            await Task.Run(() => AudioRecorder.EncodeToM4a(wav, m4a));
            File.Delete(wav);
            File.WriteAllText(Path.Combine(dir, ".duration"), ((int)elapsed.TotalSeconds).ToString());
        }
        catch (Exception ex)
        {
            // 変換に失敗してもWAVは残すので録音は失われない。
            Log.Write($"rec: encode failed {ex}");
            ShowTask($"M4Aへの変換に失敗したためWAVのまま保存しました: {ex.Message}", null);
        }
        finally
        {
            _busy.Remove(dir);
            RefreshList();
            if (!_recorder.IsRecording) SetStatus("待機中", null);
        }
        if (_settings.AutoTranscribe) await TranscribeAsync(dir);
    }

    private void SetRecordingVisuals()
    {
        SetStatus("録音中", "Red");
        TimeText.SetResourceReference(ForegroundProperty, "Red");
        RecordButton.SetResourceReference(BackgroundProperty, "Red");
        RecordGlyph.CornerRadius = new CornerRadius(2.5);
        RecordLabel.Text = "録音を停止";
        MicToggle.IsEnabled = SysToggle.IsEnabled = NameBox.IsEnabled = false;
        _trayRecord.Text = "録音を停止";
        _tray.Icon = _recordingIcon;
        _tray.Text = "wrgent - 録音中";

        // 状態表示の赤い点をゆっくり点滅させる。
        var fade = new DoubleAnimation(1, 0.25, TimeSpan.FromMilliseconds(800)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever };
        Storyboard.SetTarget(fade, StatusDot);
        Storyboard.SetTargetProperty(fade, new PropertyPath(OpacityProperty));
        _pulse = new Storyboard();
        _pulse.Children.Add(fade);
        _pulse.Begin();
    }

    private void SetIdleVisuals()
    {
        _pulse?.Stop();
        StatusDot.Opacity = 1;
        SetStatus("待機中", null);
        TimeText.Text = "00:00:00";
        TimeText.SetResourceReference(ForegroundProperty, "TextTertiary");
        RecordButton.SetResourceReference(BackgroundProperty, "Accent");
        RecordGlyph.CornerRadius = new CornerRadius(6);
        RecordLabel.Text = "録音を開始";
        MicToggle.IsEnabled = SysToggle.IsEnabled = NameBox.IsEnabled = true;
        MicName.Text = "マイク";
        MicName.SetResourceReference(ForegroundProperty, "TextSecondary");
        SysName.Text = "PCの音";
        MicMeter.Value = SysMeter.Value = 0;
        _micShown = _sysShown = 0;
        _trayRecord.Text = "録音を開始";
        _tray.Icon = _idleIcon;
        _tray.Text = "wrgent";
    }

    private void SetStatus(string text, string? colorKey)
    {
        StatusText.Text = text;
        if (colorKey == null)
        {
            StatusText.SetResourceReference(ForegroundProperty, "TextSecondary");
            StatusDot.SetResourceReference(System.Windows.Shapes.Shape.FillProperty, "TextTertiary");
        }
        else
        {
            StatusText.SetResourceReference(ForegroundProperty, colorKey);
            StatusDot.SetResourceReference(System.Windows.Shapes.Shape.FillProperty, colorKey);
        }
    }

    private void UpdateMeters()
    {
        var e = _recorder.Elapsed;
        TimeText.Text = $"{(int)e.TotalHours:00}:{e.Minutes:00}:{e.Seconds:00}";
        // 上がるときはすぐ、下がるときはゆっくり動かす。
        _micShown = Smooth(_micShown, ToMeter(_recorder.MicLevel));
        _sysShown = Smooth(_sysShown, ToMeter(_recorder.SystemLevel));
        MicMeter.Value = _micShown;
        SysMeter.Value = _sysShown;
    }

    private static double Smooth(double shown, double target) => target > shown ? target : shown + (target - shown) * 0.25;

    private static double ToMeter(float peak)
    {
        if (peak <= 0.0001f) return 0;
        var db = 20 * Math.Log10(peak);
        return Math.Clamp((db + 60) / 60 * 100, 0, 100);
    }

    // ---- 文字起こし ----

    private void UpdateEngineText()
    {
        EngineText.Text = _transcriber.RuntimeName switch
        {
            "Vulkan" => "GPU · large-v3-turbo",
            "Cpu" => "CPU · large-v3-turbo",
            _ => "large-v3-turbo"
        };
    }

    private async Task PrepareModelAsync()
    {
        try
        {
            ShowTask("文字起こしモデルを準備中", 0);
            await _transcriber.EnsureModelAsync((p, msg) => Dispatcher.BeginInvoke(() => ShowTask(msg, p)), CancellationToken.None);
            HideTask();
        }
        catch (Exception ex)
        {
            Log.Write($"model: download failed {ex}");
            ShowTask($"モデルの取得に失敗しました: {ex.Message}", null);
        }
    }

    private async Task TranscribeAsync(string dir)
    {
        var audio = FindAudio(dir);
        if (audio == null || _busy.Contains(dir)) return;
        _busy.Add(dir);
        SetItemState(dir, "文字起こし待ち", "busy");
        try
        {
            if (!_transcriber.IsModelReady) await PrepareModelAsync();
            var title = Path.GetFileName(dir);
            ShowTask($"文字起こし中: {title}", 0);
            SetItemState(dir, "文字起こし中 0%", "busy");
            var sw = Stopwatch.StartNew();
            var text = await Task.Run(() => _transcriber.TranscribeAsync(audio,
                p => Dispatcher.BeginInvoke(() =>
                {
                    SetItemState(dir, $"文字起こし中 {p * 100:0}%", "busy");
                    ShowTask($"文字起こし中: {title}", p);
                }), CancellationToken.None));
            await File.WriteAllTextAsync(Path.Combine(dir, TranscriptFileName), text);
            UpdateEngineText();
            ShowTask($"文字起こしが完了しました（{sw.Elapsed.TotalSeconds:0}秒）", null);
            _tray.ShowBalloonTip(3000, "文字起こしが完了しました", title, Forms.ToolTipIcon.Info);
        }
        catch (Exception ex)
        {
            Log.Write($"whisper: failed {dir} {ex}");
            ShowTask($"文字起こしに失敗しました: {ex.Message}", null);
        }
        finally
        {
            _busy.Remove(dir);
            RefreshList();
        }
    }

    private void ShowTask(string text, double? progress)
    {
        TaskPanel.Visibility = Visibility.Visible;
        TaskText.Text = text;
        TaskText.ToolTip = text;
        TaskProgress.Visibility = progress.HasValue ? Visibility.Visible : Visibility.Collapsed;
        if (progress.HasValue) TaskProgress.Value = progress.Value * 100;
    }

    private void HideTask() => TaskPanel.Visibility = Visibility.Collapsed;

    // ---- 一覧 ----

    private void RefreshList()
    {
        _items.Clear();
        if (Directory.Exists(_settings.LibraryDir))
        {
            foreach (var dir in Directory.GetDirectories(_settings.LibraryDir).OrderByDescending(d => d))
            {
                var folder = Path.GetFileName(dir);
                if (folder.StartsWith('_') || folder.Length < 15) continue;
                if (!DateTime.TryParseExact(folder[..15], "yyyyMMdd_HHmmss", null, System.Globalization.DateTimeStyles.None, out var when))
                    continue;
                var name = folder.Length > 18 ? folder[18..] : "";
                var (state, kind) = StateOf(dir);
                _items.Add(new RecordingItem
                {
                    Dir = dir,
                    Title = name.Length > 0 ? name : $"{when:M月d日 H:mm} の録音",
                    When = when,
                    Duration = ReadDuration(dir),
                    State = state,
                    Kind = kind,
                    CanTranscribe = kind is "idle" or "done" && FindAudio(dir) != null,
                    HasTranscript = File.Exists(Path.Combine(dir, TranscriptFileName))
                });
            }
        }
        EmptyText.Visibility = _items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        CountText.Text = _items.Count > 0 ? $"{_items.Count}件" : "";
    }

    private (string State, string Kind) StateOf(string dir)
    {
        if (string.Equals(dir, _currentDir, StringComparison.OrdinalIgnoreCase)) return ("録音中", "recording");
        if (_busy.Contains(dir))
            return File.Exists(Path.Combine(dir, WavFileName)) && !File.Exists(Path.Combine(dir, AudioFileName))
                ? ("保存中", "busy") : ("文字起こし中", "busy");
        if (File.Exists(Path.Combine(dir, TranscriptFileName))) return ("文字起こし済み", "done");
        return FindAudio(dir) != null ? ("未文字起こし", "idle") : ("音声なし", "idle");
    }

    private static TimeSpan? ReadDuration(string dir)
    {
        var path = Path.Combine(dir, ".duration");
        return File.Exists(path) && int.TryParse(File.ReadAllText(path), out var s) ? TimeSpan.FromSeconds(s) : null;
    }

    private void SetItemState(string dir, string state, string kind)
    {
        var item = _items.FirstOrDefault(i => string.Equals(i.Dir, dir, StringComparison.OrdinalIgnoreCase));
        if (item == null) return;
        item.State = state;
        item.Kind = kind;
        item.CanTranscribe = false;
    }

    private static string? FindAudio(string dir)
    {
        foreach (var name in new[] { AudioFileName, WavFileName })
        {
            var path = Path.Combine(dir, name);
            if (File.Exists(path)) return path;
        }
        return null;
    }

    private void OnTranscribeClick(object sender, RoutedEventArgs e)
    {
        if (((FrameworkElement)sender).Tag is RecordingItem item) _ = TranscribeAsync(item.Dir);
    }

    private void OnOpenTextClick(object sender, RoutedEventArgs e)
    {
        if (((FrameworkElement)sender).Tag is RecordingItem item) OpenPath(Path.Combine(item.Dir, TranscriptFileName));
    }

    private void OnOpenFolderClick(object sender, RoutedEventArgs e)
    {
        if (((FrameworkElement)sender).Tag is RecordingItem item) OpenPath(item.Dir);
    }

    private static void OpenPath(string path)
    {
        if (!File.Exists(path)) Directory.CreateDirectory(path);
        Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
    }

    private void ChooseLibrary()
    {
        _modal = true;
        try
        {
            using var dialog = new Forms.FolderBrowserDialog { SelectedPath = _settings.LibraryDir, Description = "録音の保存先" };
            if (dialog.ShowDialog() != Forms.DialogResult.OK) return;
            _settings.LibraryDir = dialog.SelectedPath;
            _settings.Save();
            RefreshList();
            ShowTask($"保存先: {_settings.LibraryDir}", null);
        }
        finally
        {
            _modal = false;
        }
    }

    private static string SanitizeName(string name)
    {
        var invalid = Path.GetInvalidFileNameChars();
        return new string(name.Trim().Select(c => invalid.Contains(c) ? '_' : c).ToArray()).Trim('.', ' ');
    }

    // ---- 終了 ----

    private void Quit()
    {
        if (_recorder.IsRecording)
        {
            _modal = true;
            ShowPopover();
            var answer = MessageBox.Show(this, "録音中です。録音を保存して終了しますか？", "wrgent", MessageBoxButton.OKCancel, MessageBoxImage.Question);
            _modal = false;
            if (answer != MessageBoxResult.OK) return;
            var dir = _currentDir!;
            _recorder.Stop();
            try
            {
                AudioRecorder.EncodeToM4a(Path.Combine(dir, WavFileName), Path.Combine(dir, AudioFileName));
                File.Delete(Path.Combine(dir, WavFileName));
            }
            catch (Exception ex)
            {
                Log.Write($"rec: encode on exit failed {ex}");
            }
        }
        _quitting = true;
        UnregisterHotKey(new WindowInteropHelper(this).Handle, HotkeyId);
        _tray.Visible = false;
        _tray.Dispose();
        _transcriber.Dispose();
        Close();
        Application.Current.Shutdown();
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WM_HOTKEY && wParam.ToInt32() == HotkeyId)
        {
            ToggleRecording();
            handled = true;
        }
        return IntPtr.Zero;
    }

    private const int WM_HOTKEY = 0x0312;
    private const uint MOD_ALT = 0x0001, MOD_CONTROL = 0x0002, MOD_NOREPEAT = 0x4000;

    [DllImport("user32.dll")] private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr hWnd, int id);
}

sealed class RecordingItem : INotifyPropertyChanged
{
    private string _state = "";
    private string _kind = "idle";
    private bool _canTranscribe;

    public required string Dir { get; init; }
    public required string Title { get; init; }
    public DateTime When { get; init; }
    public TimeSpan? Duration { get; init; }
    public bool HasTranscript { get; init; }

    public string State { get => _state; set { _state = value; Changed(nameof(State)); Changed(nameof(Subtitle)); } }
    public string Kind { get => _kind; set { _kind = value; Changed(nameof(Kind)); } }
    public bool CanTranscribe { get => _canTranscribe; set { _canTranscribe = value; Changed(nameof(CanTranscribe)); } }

    public string Subtitle
    {
        get
        {
            var parts = new List<string> { When.ToString("M/d HH:mm") };
            if (Duration is { } d) parts.Add(d.TotalHours >= 1 ? $"{(int)d.TotalHours}時間{d.Minutes}分" : d.TotalMinutes >= 1 ? $"{(int)Math.Round(d.TotalMinutes)}分" : $"{d.Seconds}秒");
            parts.Add(State);
            return string.Join("  ·  ", parts);
        }
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    private void Changed(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
