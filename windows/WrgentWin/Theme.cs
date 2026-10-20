using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;

namespace WrgentWin;

/// <summary>Windowsのライト/ダーク設定に合わせて色を差し替える。</summary>
static class Theme
{
    public static bool IsDark()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("AppsUseLightTheme") is int v && v == 0;
        }
        catch
        {
            return false;
        }
    }

    public static void Apply(ResourceDictionary resources)
    {
        var dark = IsDark();
        Set(resources, "Bg", dark ? "#202124" : "#F7F7F8");
        Set(resources, "Surface", dark ? "#2B2C30" : "#FFFFFF");
        Set(resources, "Field", dark ? "#1E1F22" : "#FFFFFF");
        Set(resources, "Line", dark ? "#3A3B40" : "#E3E3E6");
        Set(resources, "Hover", dark ? "#34353A" : "#ECECEF");
        Set(resources, "Pressed", dark ? "#3D3E44" : "#E1E1E5");
        Set(resources, "Track", dark ? "#45464C" : "#D9D9DE");
        Set(resources, "Text", dark ? "#F2F2F4" : "#1C1C1E");
        Set(resources, "TextSecondary", dark ? "#B4B5BB" : "#55565C");
        Set(resources, "TextTertiary", dark ? "#7C7D84" : "#9A9BA1");
        Set(resources, "Accent", dark ? "#3D8BFF" : "#2F74F0");
        Set(resources, "AccentSoft", dark ? "#24364F" : "#E3EDFE");
        Set(resources, "Red", dark ? "#FF5A52" : "#E5372E");
        Set(resources, "RedSoft", dark ? "#4A2626" : "#FDE7E6");
        Set(resources, "Green", dark ? "#3FD066" : "#25A244");
        Set(resources, "Orange", dark ? "#FFA53A" : "#E08300");
    }

    private static void Set(ResourceDictionary resources, string key, string hex)
    {
        var brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));
        brush.Freeze();
        resources[key] = brush;
    }
}
