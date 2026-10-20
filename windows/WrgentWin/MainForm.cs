using System.Diagnostics;
using System.Runtime.InteropServices;

namespace WrgentWin;

sealed class MainForm : Form
{
    private const int HotkeyId = 0x5752;
    private const string AudioFileName = "mix.m4a";
    private const string TranscriptFileName = "transcript.txt";

    private readonly Settings _settings = Settings.Load();
    private readonly AudioRecorder _recorder = new();
    private readonly Transcriber _transcriber;
    private readonly System.Windows.Forms.Timer _uiTimer = new() { Interval = 100 };
    private readonly HashSet<string> _busy = new(StringComparer.OrdinalIgnoreCase);
    private string? _currentDir;
    private bool _quitting;

    private readonly Button _recordButton = new() { Text = "● 録音開始", Height = 56, Dock = DockStyle.Fill, Font = new Font("Yu Gothic UI", 14f, FontStyle.Bold) };
    private readonly Label _timeLabel = new() { Text = "00:00:00", AutoSize = false, Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter, Font = new Font("Consolas", 20f) };
    private readonly TextBox _nameBox = new() { Dock = DockStyle.Fill, PlaceholderText = "会議名（任意）" };
    private readonly ProgressBar _micMeter = new() { Dock = DockStyle.Fill, Maximum = 100, Height = 12 };
    private readonly ProgressBar _sysMeter = new() { Dock = DockStyle.Fill, Maximum = 100, Height = 12 };
    private readonly CheckBox _micCheck = new() { Text = "マイク", AutoSize = true };
    private readonly CheckBox _sysCheck = new() { Text = "PC音声", AutoSize = true };
    private readonly CheckBox _autoCheck = new() { Text = "停止後に自動で文字起こし", AutoSize = true };
    private readonly ListView _list = new() { Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true, MultiSelect = false };
    private readonly Button _transcribeButton = new() { Text = "文字起こし", AutoSize = true };
    private readonly Button _openTextButton = new() { Text = "テキストを開く", AutoSize = true };
    private readonly Button _openFolderButton = new() { Text = "フォルダを開く", AutoSize = true };
    private readonly Button _libraryButton = new() { Text = "保存先…", AutoSize = true };
    private readonly ToolStripStatusLabel _status = new() { Spring = true, TextAlign = ContentAlignment.MiddleLeft };
    private readonly ToolStripProgressBar _progress = new() { Visible = false, Width = 160 };
    private readonly NotifyIcon _tray = new();
    private readonly ToolStripMenuItem _trayRecord = new("録音開始");

    public MainForm()
    {
        _transcriber = new Transcriber(_settings);
        Text = "wrgent";
        Width = 640;
        Height = 560;
        MinimumSize = new Size(520, 440);
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Yu Gothic UI", 9.5f);
        Icon = LoadIcon();

        BuildLayout();
        BuildTray();

        _micCheck.Checked = _settings.RecordMicrophone;
        _sysCheck.Checked = _settings.RecordSystemAudio;
        _autoCheck.Checked = _settings.AutoTranscribe;
        _micCheck.CheckedChanged += (_, _) => { _settings.RecordMicrophone = _micCheck.Checked; _settings.Save(); };
        _sysCheck.CheckedChanged += (_, _) => { _settings.RecordSystemAudio = _sysCheck.Checked; _settings.Save(); };
        _autoCheck.CheckedChanged += (_, _) => { _settings.AutoTranscribe = _autoCheck.Checked; _settings.Save(); };

        _recordButton.Click += (_, _) => ToggleRecording();
        _transcribeButton.Click += (_, _) => { if (SelectedDir() is { } d) _ = TranscribeAsync(d); };
        _openTextButton.Click += (_, _) => OpenSelected(TranscriptFileName);
        _openFolderButton.Click += (_, _) => OpenSelected(null);
        _libraryButton.Click += (_, _) => ChooseLibrary();
        _list.DoubleClick += (_, _) => OpenSelected(TranscriptFileName);
        _list.SelectedIndexChanged += (_, _) => UpdateButtons();
        _recorder.Error += msg => BeginInvoke(() => ShowStatus(msg));
        _uiTimer.Tick += (_, _) => UpdateMeters();

        Load += (_, _) =>
        {
            RegisterHotKey(Handle, HotkeyId, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, (uint)Keys.R);
            RefreshList();
            ShowStatus($"保存先: {_settings.LibraryDir}　（Ctrl+Alt+R で録音の開始/停止）");
            if (!_transcriber.IsModelReady) _ = PrepareModelAsync();
        };
        FormClosing += OnFormClosing;
    }

    private void BuildLayout()
    {
        var top = new TableLayoutPanel { Dock = DockStyle.Top, ColumnCount = 2, RowCount = 4, Height = 168, Padding = new Padding(10, 10, 10, 4) };
        top.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        top.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        top.RowStyles.Add(new RowStyle(SizeType.Absolute, 60));
        top.RowStyles.Add(new RowStyle(SizeType.Absolute, 30));
        top.RowStyles.Add(new RowStyle(SizeType.Absolute, 24));
        top.RowStyles.Add(new RowStyle(SizeType.Absolute, 30));
        top.Controls.Add(_recordButton, 0, 0);
        top.Controls.Add(_timeLabel, 1, 0);
        top.Controls.Add(_nameBox, 0, 1);
        top.SetColumnSpan(_nameBox, 2);
        top.Controls.Add(MeterRow(_micCheck, _micMeter), 0, 2);
        top.Controls.Add(MeterRow(_sysCheck, _sysMeter), 1, 2);
        var options = new FlowLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(0, 4, 0, 0) };
        options.Controls.Add(_autoCheck);
        top.Controls.Add(options, 0, 3);
        top.SetColumnSpan(options, 2);

        _list.Columns.Add("日時", 140);
        _list.Columns.Add("会議名", 200);
        _list.Columns.Add("状態", 200);

        var buttons = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 40, Padding = new Padding(6, 4, 6, 0) };
        buttons.Controls.AddRange(new Control[] { _transcribeButton, _openTextButton, _openFolderButton, _libraryButton });

        var middle = new Panel { Dock = DockStyle.Fill, Padding = new Padding(10, 0, 10, 0) };
        middle.Controls.Add(_list);

        var strip = new StatusStrip();
        strip.Items.Add(_status);
        strip.Items.Add(_progress);

        Controls.Add(middle);
        Controls.Add(buttons);
        Controls.Add(top);
        Controls.Add(strip);
    }

    private static Control MeterRow(CheckBox check, ProgressBar meter)
    {
        var row = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, Margin = new Padding(0) };
        row.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 96));
        row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        meter.Margin = new Padding(0, 5, 6, 0);
        row.Controls.Add(check, 0, 0);
        row.Controls.Add(meter, 1, 0);
        return row;
    }

    private void BuildTray()
    {
        _tray.Icon = Icon;
        _tray.Text = "wrgent";
        _tray.Visible = true;
        var menu = new ContextMenuStrip();
        _trayRecord.Click += (_, _) => ToggleRecording();
        menu.Items.Add(_trayRecord);
        menu.Items.Add("ウィンドウを表示", null, (_, _) => ShowWindow());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("終了", null, (_, _) => { _quitting = true; Close(); });
        _tray.ContextMenuStrip = menu;
        _tray.DoubleClick += (_, _) => ShowWindow();
    }

    private void ShowWindow()
    {
        Show();
        WindowState = FormWindowState.Normal;
        Activate();
    }

    // ---- 録音 ----

    private void ToggleRecording()
    {
        if (_recorder.IsRecording) StopRecording();
        else StartRecording();
    }

    private void StartRecording()
    {
        var name = SanitizeName(_nameBox.Text);
        var folder = DateTime.Now.ToString("yyyyMMdd_HHmmss") + (name.Length > 0 ? " - " + name : "");
        _currentDir = Path.Combine(_settings.LibraryDir, folder);
        try
        {
            _recorder.Start(Path.Combine(_currentDir, "recording.wav"), _micCheck.Checked, _sysCheck.Checked);
        }
        catch (Exception ex)
        {
            Log.Write($"rec: start failed {ex}");
            MessageBox.Show(this, $"録音を開始できませんでした。\n{ex.Message}", "wrgent", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            _currentDir = null;
            return;
        }
        _recordButton.Text = "■ 録音停止";
        _recordButton.BackColor = Color.FromArgb(220, 60, 60);
        _recordButton.ForeColor = Color.White;
        _trayRecord.Text = "録音停止";
        _micCheck.Enabled = _sysCheck.Enabled = _nameBox.Enabled = false;
        _tray.Text = "wrgent - 録音中";
        _uiTimer.Start();
        var devices = string.Join(" / ", new[] { _recorder.MicDeviceName, _recorder.SystemDeviceName }.Where(s => s.Length > 0));
        ShowStatus($"録音中: {devices}");
        RefreshList();
    }

    private void StopRecording()
    {
        var elapsed = _recorder.Stop();
        _uiTimer.Stop();
        _recordButton.Text = "● 録音開始";
        _recordButton.BackColor = SystemColors.Control;
        _recordButton.ForeColor = SystemColors.ControlText;
        _recordButton.UseVisualStyleBackColor = true;
        _trayRecord.Text = "録音開始";
        _micCheck.Enabled = _sysCheck.Enabled = _nameBox.Enabled = true;
        _nameBox.Text = "";
        _tray.Text = "wrgent";
        _micMeter.Value = _sysMeter.Value = 0;
        var dir = _currentDir!;
        _currentDir = null;
        ShowStatus($"録音を保存中（{elapsed:hh\\:mm\\:ss}）");
        _ = FinishRecordingAsync(dir);
    }

    private async Task FinishRecordingAsync(string dir)
    {
        var wav = Path.Combine(dir, "recording.wav");
        var m4a = Path.Combine(dir, AudioFileName);
        _busy.Add(dir);
        RefreshList();
        try
        {
            await Task.Run(() => AudioRecorder.EncodeToM4a(wav, m4a));
            File.Delete(wav);
            ShowStatus($"保存しました: {m4a}");
        }
        catch (Exception ex)
        {
            // 変換に失敗してもWAVは残すので録音は失われない。
            Log.Write($"rec: encode failed {ex}");
            ShowStatus($"M4Aへの変換に失敗したため WAV のまま保存しました: {ex.Message}");
        }
        finally
        {
            _busy.Remove(dir);
            RefreshList();
        }
        if (_settings.AutoTranscribe) await TranscribeAsync(dir);
    }

    private void UpdateMeters()
    {
        var e = _recorder.Elapsed;
        _timeLabel.Text = $"{(int)e.TotalHours:00}:{e.Minutes:00}:{e.Seconds:00}";
        _micMeter.Value = ToMeter(_recorder.MicLevel);
        _sysMeter.Value = ToMeter(_recorder.SystemLevel);
    }

    private static int ToMeter(float peak)
    {
        if (peak <= 0.0001f) return 0;
        var db = 20 * Math.Log10(peak);
        return (int)Math.Clamp((db + 60) / 60 * 100, 0, 100);
    }

    // ---- 文字起こし ----

    private async Task PrepareModelAsync()
    {
        _progress.Visible = true;
        try
        {
            await _transcriber.EnsureModelAsync((p, msg) => BeginInvoke(() =>
            {
                _progress.Value = (int)(p * 100);
                ShowStatus(msg);
            }), CancellationToken.None);
            ShowStatus("文字起こしモデルの準備ができました");
        }
        catch (Exception ex)
        {
            Log.Write($"model: download failed {ex}");
            ShowStatus($"モデルの取得に失敗しました: {ex.Message}");
        }
        finally
        {
            _progress.Visible = false;
        }
    }

    private async Task TranscribeAsync(string dir)
    {
        var audio = FindAudio(dir);
        if (audio == null || _busy.Contains(dir)) return;
        _busy.Add(dir);
        SetState(dir, "文字起こし待ち");
        try
        {
            if (!_transcriber.IsModelReady) await PrepareModelAsync();
            SetState(dir, "文字起こし中 0%");
            var sw = Stopwatch.StartNew();
            var text = await Task.Run(() => _transcriber.TranscribeAsync(audio,
                p => BeginInvoke(() => SetState(dir, $"文字起こし中 {p * 100:0}%")), CancellationToken.None));
            await File.WriteAllTextAsync(Path.Combine(dir, TranscriptFileName), text);
            ShowStatus($"文字起こし完了（{sw.Elapsed.TotalSeconds:0}秒, {_transcriber.RuntimeName}）: {Path.GetFileName(dir)}");
        }
        catch (Exception ex)
        {
            Log.Write($"whisper: failed {dir} {ex}");
            ShowStatus($"文字起こしに失敗しました: {ex.Message}");
        }
        finally
        {
            _busy.Remove(dir);
            RefreshList();
        }
    }

    // ---- 一覧 ----

    private void RefreshList()
    {
        var selected = SelectedDir();
        _list.BeginUpdate();
        _list.Items.Clear();
        if (Directory.Exists(_settings.LibraryDir))
        {
            foreach (var dir in Directory.GetDirectories(_settings.LibraryDir).OrderByDescending(d => d))
            {
                var folder = Path.GetFileName(dir);
                if (folder.StartsWith('_') || folder.Length < 15) continue;
                var when = DateTime.TryParseExact(folder[..15], "yyyyMMdd_HHmmss", null,
                    System.Globalization.DateTimeStyles.None, out var t) ? t.ToString("yyyy/MM/dd HH:mm") : folder;
                var name = folder.Length > 18 ? folder[18..] : "";
                var item = new ListViewItem(new[] { when, name, StateOf(dir) }) { Tag = dir };
                _list.Items.Add(item);
                if (string.Equals(dir, selected, StringComparison.OrdinalIgnoreCase)) item.Selected = true;
            }
        }
        _list.EndUpdate();
        UpdateButtons();
    }

    private string StateOf(string dir)
    {
        if (string.Equals(dir, _currentDir, StringComparison.OrdinalIgnoreCase)) return "録音中";
        if (_busy.Contains(dir)) return File.Exists(Path.Combine(dir, "recording.wav")) && !File.Exists(Path.Combine(dir, AudioFileName)) ? "保存中" : "文字起こし中";
        if (File.Exists(Path.Combine(dir, TranscriptFileName))) return "文字起こし済み";
        return FindAudio(dir) != null ? "未文字起こし" : "音声なし";
    }

    private void SetState(string dir, string state)
    {
        foreach (ListViewItem item in _list.Items)
            if (string.Equals((string)item.Tag!, dir, StringComparison.OrdinalIgnoreCase))
                item.SubItems[2].Text = state;
    }

    private static string? FindAudio(string dir)
    {
        foreach (var name in new[] { AudioFileName, "recording.wav" })
        {
            var path = Path.Combine(dir, name);
            if (File.Exists(path)) return path;
        }
        return null;
    }

    private string? SelectedDir() => _list.SelectedItems.Count > 0 ? (string)_list.SelectedItems[0].Tag! : null;

    private void UpdateButtons()
    {
        var dir = SelectedDir();
        var idle = dir != null && !_busy.Contains(dir) && !string.Equals(dir, _currentDir, StringComparison.OrdinalIgnoreCase);
        _transcribeButton.Enabled = idle && FindAudio(dir!) != null;
        _openTextButton.Enabled = dir != null && File.Exists(Path.Combine(dir, TranscriptFileName));
        _openFolderButton.Enabled = true;
    }

    private void OpenSelected(string? file)
    {
        var dir = SelectedDir();
        var target = dir == null ? _settings.LibraryDir : file == null ? dir : Path.Combine(dir, file);
        if (file != null && !File.Exists(target)) return;
        Directory.CreateDirectory(_settings.LibraryDir);
        Process.Start(new ProcessStartInfo(target) { UseShellExecute = true });
    }

    private void ChooseLibrary()
    {
        using var dialog = new FolderBrowserDialog { SelectedPath = _settings.LibraryDir, Description = "録音の保存先" };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        _settings.LibraryDir = dialog.SelectedPath;
        _settings.Save();
        RefreshList();
        ShowStatus($"保存先: {_settings.LibraryDir}");
    }

    private void ShowStatus(string message) => _status.Text = message;

    private static string SanitizeName(string name)
    {
        var invalid = Path.GetInvalidFileNameChars();
        return new string(name.Trim().Select(c => invalid.Contains(c) ? '_' : c).ToArray()).Trim('.', ' ');
    }

    private static Icon LoadIcon()
    {
        using var stream = typeof(MainForm).Assembly.GetManifestResourceStream("WrgentWin.app.ico");
        return stream != null ? new Icon(stream) : SystemIcons.Application;
    }

    // ---- ウィンドウ・終了 ----

    private void OnFormClosing(object? sender, FormClosingEventArgs e)
    {
        if (!_quitting && e.CloseReason == CloseReason.UserClosing)
        {
            // ×ボタンはトレイに格納するだけ。録音は続ける。
            e.Cancel = true;
            Hide();
            _tray.ShowBalloonTip(2000, "wrgent", "タスクトレイで動作中です。終了はトレイのメニューから。", ToolTipIcon.Info);
            return;
        }
        if (_recorder.IsRecording)
        {
            var answer = MessageBox.Show(this, "録音中です。録音を保存して終了しますか？", "wrgent", MessageBoxButtons.OKCancel, MessageBoxIcon.Question);
            if (answer != DialogResult.OK) { e.Cancel = true; _quitting = false; return; }
            var dir = _currentDir!;
            _recorder.Stop();
            try { AudioRecorder.EncodeToM4a(Path.Combine(dir, "recording.wav"), Path.Combine(dir, AudioFileName)); File.Delete(Path.Combine(dir, "recording.wav")); }
            catch (Exception ex) { Log.Write($"rec: encode on exit failed {ex}"); }
        }
        UnregisterHotKey(Handle, HotkeyId);
        _tray.Visible = false;
        _transcriber.Dispose();
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_HOTKEY && m.WParam.ToInt32() == HotkeyId) ToggleRecording();
        base.WndProc(ref m);
    }

    private const int WM_HOTKEY = 0x0312;
    private const uint MOD_ALT = 0x0001, MOD_CONTROL = 0x0002, MOD_NOREPEAT = 0x4000;

    [DllImport("user32.dll")] private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr hWnd, int id);
}
