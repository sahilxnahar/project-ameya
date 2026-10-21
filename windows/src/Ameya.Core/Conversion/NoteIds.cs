namespace Ameya.Core.Conversion;

/// <summary>
/// Note ids the Windows engines report. Each must exist in the shared spec (a test checks), so the
/// message shown is always the same plain-words sentence the Mac app shows.
/// </summary>
public static class NoteIds
{
    public const string TransparencyFilledWhite = "transparencyFilledWhite";
    public const string OnlyFirstFrameKept = "onlyFirstFrameKept";
    public const string OnlyFirstPageKept = "onlyFirstPageKept";
    public const string AnimationBecamePages = "animationBecamePages";
    public const string MadeSquareIcon = "madeSquareIcon";

    public static IReadOnlyList<string> All { get; } =
        [TransparencyFilledWhite, OnlyFirstFrameKept, OnlyFirstPageKept, AnimationBecamePages, MadeSquareIcon];
}
