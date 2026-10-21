using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using Microsoft.Win32.SafeHandles;

namespace Ameya.Core.Windows;

/// <summary>A kernel handle (job, process, token) closed with CloseHandle.</summary>
[SupportedOSPlatform("windows")]
internal sealed class SafeKernelHandle : SafeHandleZeroOrMinusOneIsInvalid
{
    public SafeKernelHandle() : base(true) { }

    public SafeKernelHandle(IntPtr handle) : base(true) => SetHandle(handle);

    protected override bool ReleaseHandle() => NativeMethods.CloseHandle(handle);
}

/// <summary>Win32 calls for the worker sandbox. Structures follow the Windows SDK headers.</summary>
[SupportedOSPlatform("windows")]
internal static class NativeMethods
{
    // Process creation
    internal const uint CreateSuspended = 0x00000004;
    internal const uint CreateNoWindow = 0x08000000;
    internal const uint ExtendedStartupInfoPresent = 0x00080000;
    internal const int StartfUseStdHandles = 0x00000100;
    internal static readonly IntPtr ProcThreadAttributeHandleList = 0x00020002;
    internal const uint HandleFlagInherit = 0x00000001;

    // Tokens
    internal const uint TokenDuplicate = 0x0002;
    internal const uint TokenQuery = 0x0008;
    internal const uint TokenAssignPrimary = 0x0001;
    internal const uint TokenAdjustDefault = 0x0080;
    internal const uint MaximumAllowed = 0x02000000;
    internal const int SecurityImpersonation = 2;
    internal const int TokenPrimary = 1;
    internal const int TokenIntegrityLevel = 25;
    internal const uint SeGroupIntegrity = 0x00000020;
    internal const string LowIntegritySid = "S-1-16-4096";

    // Job objects
    internal const int JobObjectBasicUiRestrictions = 4;
    internal const int JobObjectExtendedLimitInformation = 9;
    internal const uint JobObjectLimitProcessMemory = 0x00000100;
    internal const uint JobObjectLimitDieOnUnhandledException = 0x00000400;
    internal const uint JobObjectLimitKillOnJobClose = 0x00002000;
    internal const uint JobObjectUiLimitAll = 0x000000FF; // handles, clipboard, system parameters, display, atoms, desktop, exit

    [StructLayout(LayoutKind.Sequential)]
    internal struct StartupInfo
    {
        public int Cb;
        public IntPtr Reserved;
        public IntPtr Desktop;
        public IntPtr Title;
        public int X, Y, XSize, YSize, XCountChars, YCountChars, FillAttribute;
        public int Flags;
        public short ShowWindow;
        public short Reserved2Count;
        public IntPtr Reserved2;
        public IntPtr StdInput;
        public IntPtr StdOutput;
        public IntPtr StdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct StartupInfoEx
    {
        public StartupInfo StartupInfo;
        public IntPtr AttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct ProcessInformation
    {
        public IntPtr Process;
        public IntPtr Thread;
        public int ProcessId;
        public int ThreadId;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct JobBasicLimitInformation
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct IoCounters
    {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct JobExtendedLimitInformation
    {
        public JobBasicLimitInformation BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct TokenMandatoryLabel
    {
        public IntPtr Sid;
        public uint Attributes;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll")]
    internal static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern bool SetHandleInformation(SafeHandle handle, uint mask, uint flags);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "CreateJobObjectW")]
    internal static extern SafeKernelHandle CreateJobObject(IntPtr attributes, string? name);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern bool SetInformationJobObject(SafeKernelHandle job, int infoClass, ref JobExtendedLimitInformation info, int length);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern bool SetInformationJobObject(SafeKernelHandle job, int infoClass, ref uint info, int length);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern bool AssignProcessToJobObject(SafeKernelHandle job, SafeKernelHandle process);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern bool TerminateJobObject(SafeKernelHandle job, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern bool TerminateProcess(SafeKernelHandle process, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern uint ResumeThread(SafeKernelHandle thread);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern bool GetExitCodeProcess(SafeKernelHandle process, out uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern bool UpdateProcThreadAttribute(
        IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previousValue, IntPtr returnSize);

    [DllImport("kernel32.dll")]
    internal static extern void DeleteProcThreadAttributeList(IntPtr list);

    [DllImport("advapi32.dll", SetLastError = true)]
    internal static extern bool OpenProcessToken(IntPtr process, uint access, out SafeKernelHandle token);

    [DllImport("advapi32.dll", SetLastError = true)]
    internal static extern bool DuplicateTokenEx(
        SafeKernelHandle existing, uint access, IntPtr attributes, int impersonationLevel, int tokenType, out SafeKernelHandle token);

    [DllImport("advapi32.dll", SetLastError = true)]
    internal static extern bool SetTokenInformation(SafeKernelHandle token, int infoClass, IntPtr info, int length);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "ConvertStringSidToSidW")]
    internal static extern bool ConvertStringSidToSid(string sid, out IntPtr sidPointer);

    [DllImport("advapi32.dll")]
    internal static extern int GetLengthSid(IntPtr sid);

    [DllImport("kernel32.dll")]
    internal static extern IntPtr LocalFree(IntPtr memory);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "CreateProcessAsUserW")]
    internal static extern bool CreateProcessAsUser(
        SafeKernelHandle token, string? applicationName, char[] commandLine, IntPtr processAttributes, IntPtr threadAttributes,
        bool inheritHandles, uint creationFlags, IntPtr environment, string? currentDirectory,
        ref StartupInfoEx startupInfo, out ProcessInformation processInformation);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "CreateProcessW")]
    internal static extern bool CreateProcess(
        string? applicationName, char[] commandLine, IntPtr processAttributes, IntPtr threadAttributes,
        bool inheritHandles, uint creationFlags, IntPtr environment, string? currentDirectory,
        ref StartupInfoEx startupInfo, out ProcessInformation processInformation);
}
