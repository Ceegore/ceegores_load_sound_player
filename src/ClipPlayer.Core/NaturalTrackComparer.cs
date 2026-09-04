namespace ClipPlayer.Core;

/// <summary>Ordinal, case-insensitive filename order with numeric runs compared numerically.</summary>
public sealed class NaturalTrackComparer : IComparer<Track>
{
    public static NaturalTrackComparer Instance { get; } = new();

    public int Compare(Track? left, Track? right)
    {
        if (ReferenceEquals(left, right)) return 0;
        if (left is null) return -1;
        if (right is null) return 1;
        return CompareText(left.FileName, right.FileName);
    }

    private static int CompareText(string left, string right)
    {
        var i = 0;
        var j = 0;
        while (i < left.Length && j < right.Length)
        {
            var leftDigit = char.IsDigit(left[i]);
            var rightDigit = char.IsDigit(right[j]);
            if (leftDigit && rightDigit)
            {
                var leftStart = i;
                var rightStart = j;
                while (i < left.Length && char.IsDigit(left[i])) i++;
                while (j < right.Length && char.IsDigit(right[j])) j++;
                var leftRun = left[leftStart..i].TrimStart('0');
                var rightRun = right[rightStart..j].TrimStart('0');
                if (leftRun.Length != rightRun.Length) return leftRun.Length.CompareTo(rightRun.Length);
                var numeric = string.Compare(leftRun, rightRun, StringComparison.Ordinal);
                if (numeric != 0) return numeric;
                var leading = (i - leftStart - leftRun.Length).CompareTo(j - rightStart - rightRun.Length);
                if (leading != 0) return leading;
                continue;
            }

            var comparison = char.ToUpperInvariant(left[i]).CompareTo(char.ToUpperInvariant(right[j]));
            if (comparison != 0) return comparison;
            i++;
            j++;
        }

        return (left.Length - i).CompareTo(right.Length - j);
    }
}
