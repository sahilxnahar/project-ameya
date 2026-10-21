using System.Runtime.InteropServices;

namespace Ameya.Worker;

internal static class NativeMethods
{
    /// <summary>FOLDERID_LocalAppDataLow: the one per-user folder a Low integrity process may write to.</summary>
    internal static readonly Guid LocalAppDataLow = new("A520A1A4-1780-4FF6-BD18-167343C5AF16");

    internal const int TokenIntegrityLevel = 25;
    internal const uint TokenQuery = 0x0008;

    [DllImport("shell32.dll")]
    internal static extern int SHGetKnownFolderPath(in Guid folder, uint flags, IntPtr token, out IntPtr path);

    [DllImport("kernel32.dll")]
    internal static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);

    [DllImport("advapi32.dll", SetLastError = true)]
    internal static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);

    [DllImport("advapi32.dll", SetLastError = true)]
    internal static extern bool GetTokenInformation(IntPtr token, int infoClass, IntPtr info, int length, out int returnLength);

    [DllImport("advapi32.dll")]
    internal static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);

    [DllImport("advapi32.dll")]
    internal static extern IntPtr GetSidSubAuthority(IntPtr sid, uint index);

    [DllImport("kernel32.dll")]
    internal static extern bool CloseHandle(IntPtr handle);

    /// <summary>%USERPROFILE%\AppData\LocalLow, or null if Windows can't say.</summary>
    internal static string? LocalLowFolder()
    {
        if (SHGetKnownFolderPath(LocalAppDataLow, 0, IntPtr.Zero, out var pointer) != 0) return null;
        try
        {
            return Marshal.PtrToStringUni(pointer);
        }
        finally
        {
            Marshal.FreeCoTaskMem(pointer);
        }
    }

    /// <summary>The integrity level RID of this process: 0x1000 Low, 0x2000 Medium, 0x3000 High.</summary>
    internal static int IntegrityLevel()
    {
        if (!OpenProcessToken(GetCurrentProcess(), TokenQuery, out var token)) return -1;
        try
        {
            GetTokenInformation(token, TokenIntegrityLevel, IntPtr.Zero, 0, out var needed);
            var buffer = Marshal.AllocHGlobal(needed);
            try
            {
                if (!GetTokenInformation(token, TokenIntegrityLevel, buffer, needed, out _)) return -1;
                var sid = Marshal.ReadIntPtr(buffer); // TOKEN_MANDATORY_LABEL.Label.Sid
                var count = Marshal.ReadByte(GetSidSubAuthorityCount(sid));
                return Marshal.ReadInt32(GetSidSubAuthority(sid, (uint)(count - 1)));
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }
        finally
        {
            CloseHandle(token);
        }
    }
}
