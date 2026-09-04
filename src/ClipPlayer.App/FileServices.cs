using System.Collections.ObjectModel;
using System.IO;
using System.Globalization;
using System.Windows;
using Microsoft.VisualBasic.FileIO;
using Microsoft.Win32;

namespace ClipPlayer.App;

public static class AudioFileRules
{
    public static readonly IReadOnlySet<string> Extensions =
        new HashSet<string>(StringComparer.OrdinalIgnoreCase) { ".wav", ".mp3", ".flac" };

    public static bool IsSupported(string path) => Extensions.Contains(Path.GetExtension(path));

    public static string DisplayName(string path) => Path.GetFileName(path);
}

public static class AudioFileDiscovery
{
    public static IReadOnlyList<string> ScanFolder(string path)
    {
        var folder = Path.GetDirectoryName(Path.GetFullPath(path));
        if (string.IsNullOrWhiteSpace(folder) || !Directory.Exists(folder)) return [];
        return Directory.EnumerateFiles(folder)
            .Where(AudioFileRules.IsSupported)
            .OrderBy(Path.GetFileName, NaturalNameComparer.Instance)
            .ThenBy(x => x, StringComparer.Ordinal)
            .ToArray();
    }
}

internal sealed class NaturalNameComparer : IComparer<string?>
{
    public static NaturalNameComparer Instance { get; } = new();
    public int Compare(string? left, string? right)
    {
        if (ReferenceEquals(left, right)) return 0;
        if (left is null) return -1;
        if (right is null) return 1;
        var a = Path.GetFileName(left);
        var b = Path.GetFileName(right);
        var i = 0; var j = 0;
        while (i < a.Length && j < b.Length)
        {
            if (char.IsDigit(a[i]) && char.IsDigit(b[j]))
            {
                var ai = i; var bj = j;
                while (ai < a.Length && a[ai] == '0') ai++;
                while (bj < b.Length && b[bj] == '0') bj++;
                var ae = ai; var be = bj;
                while (ae < a.Length && char.IsDigit(a[ae])) ae++;
                while (be < b.Length && char.IsDigit(b[be])) be++;
                var lengthCompare = (ae - ai).CompareTo(be - bj);
                if (lengthCompare != 0) return lengthCompare;
                var numberCompare = string.Compare(a, ai, b, bj, ae - ai, StringComparison.Ordinal);
                if (numberCompare != 0) return numberCompare;
                i = ae; j = be;
                continue;
            }
            var charCompare = char.ToUpperInvariant(a[i]).CompareTo(char.ToUpperInvariant(b[j]));
            if (charCompare != 0) return charCompare;
            i++; j++;
        }
        return (a.Length - i).CompareTo(b.Length - j);
    }
}

public interface IFilePicker
{
    IReadOnlyList<string> PickFiles();
}

public sealed class WpfFilePicker : IFilePicker
{
    public IReadOnlyList<string> PickFiles()
    {
        var dialog = new OpenFileDialog
        {
            Filter = "Audiodateien (*.wav;*.mp3;*.flac)|*.wav;*.mp3;*.flac|Alle Dateien (*.*)|*.*",
            Multiselect = true,
            CheckFileExists = true,
            Title = "Audiodateien öffnen"
        };
        return dialog.ShowDialog() == true ? dialog.FileNames : [];
    }
}

public interface IRecycleBin
{
    void SendToRecycleBin(string path);
}

public sealed class WindowsRecycleBin : IRecycleBin
{
    public void SendToRecycleBin(string path) =>
        FileSystem.DeleteFile(path, UIOption.OnlyErrorDialogs, RecycleOption.SendToRecycleBin);
}

public sealed class MessageBoxConfirmation : IConfirmation
{
    public bool Confirm(string title, string message) =>
        MessageBox.Show(message, title, MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No) == MessageBoxResult.Yes;
}

public interface IConfirmation
{
    bool Confirm(string title, string message);
}

public sealed class ClipItem
{
    public ClipItem(string path) => Path = System.IO.Path.GetFullPath(path);
    public string Path { get; }
    public string Name => AudioFileRules.DisplayName(Path);
    public override string ToString() => Name;
}
