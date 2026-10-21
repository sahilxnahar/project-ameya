using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using static Ameya.Core.Windows.NativeMethods;

namespace Ameya.Core.Windows;

/// <summary>
/// A copy of this process's token lowered to Low integrity. Windows' mandatory integrity control
/// then stops the worker writing to anything labelled Medium (the user's documents, Downloads,
/// %TEMP%, the registry under HKCU) or touching Medium processes, whatever its user's rights.
/// Lowering your own token needs no privilege, and CreateProcessAsUser accepts a token that is a
/// restricted copy of the caller's (see "Designing Applications to Run at a Low Integrity Level").
/// </summary>
[SupportedOSPlatform("windows")]
internal static class LowIntegrityToken
{
    public static SafeKernelHandle Create()
    {
        if (!OpenProcessToken(GetCurrentProcess(), TokenDuplicate | TokenQuery | TokenAssignPrimary | TokenAdjustDefault, out var own))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Couldn't read this app's security token.");
        }
        using (own)
        {
            if (!DuplicateTokenEx(own, MaximumAllowed, IntPtr.Zero, SecurityImpersonation, TokenPrimary, out var token))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Couldn't copy this app's security token.");
            }
            try
            {
                Lower(token);
                return token;
            }
            catch
            {
                token.Dispose();
                throw;
            }
        }
    }

    private static void Lower(SafeKernelHandle token)
    {
        if (!ConvertStringSidToSid(LowIntegritySid, out var sid))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Couldn't create the Low integrity label.");
        }
        var labelSize = Marshal.SizeOf<TokenMandatoryLabel>();
        var size = labelSize + GetLengthSid(sid);
        var buffer = Marshal.AllocHGlobal(size);
        try
        {
            Marshal.StructureToPtr(new TokenMandatoryLabel { Sid = sid, Attributes = SeGroupIntegrity }, buffer, false);
            if (!SetTokenInformation(token, TokenIntegrityLevel, buffer, size))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Couldn't lower the converter's integrity level.");
            }
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
            LocalFree(sid);
        }
    }
}
