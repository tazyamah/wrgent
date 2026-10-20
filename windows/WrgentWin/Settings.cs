using System.Text.Json;

namespace WrgentWin;

sealed class Settings
{
    public static string AppDataDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "wrgent");

    private static string FilePath => Path.Combine(AppDataDir, "settings.json");

    public string LibraryDir { get; set; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyMusic), "wrgent");

    public bool AutoTranscribe { get; set; } = true;
    public bool RecordMicrophone { get; set; } = true;
    public bool RecordSystemAudio { get; set; } = true;

    /// <summary>Windowsでマイクがミュートでも、録音中だけ解除して録る。</summary>
    public bool UnmuteMicWhileRecording { get; set; } = true;
    public string Language { get; set; } = "ja";

    /// <summary>large-v3-turbo の量子化。q5_0 は速く小さい、q8_0 は精度寄り。</summary>
    public string ModelQuantization { get; set; } = "q5_0";

    public string ModelsDir => Path.Combine(AppDataDir, "models");

    public static Settings Load()
    {
        try
        {
            if (File.Exists(FilePath))
                return JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath)) ?? new Settings();
        }
        catch (Exception ex)
        {
            Log.Write($"settings: load failed {ex.Message}");
        }
        return new Settings();
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(AppDataDir);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch (Exception ex)
        {
            Log.Write($"settings: save failed {ex.Message}");
        }
    }
}
