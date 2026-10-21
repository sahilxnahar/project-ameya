using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using Microsoft.Win32.SafeHandles;
using static Ameya.Core.Windows.NativeMethods;

namespace Ameya.Core.Windows;

/// <summary>How tightly a worker is held.</summary>
public sealed record SandboxOptions
{
    /// <summary>Run at Low integrity, so the worker can't write to the user's files, settings or
    /// temp folder; it only has the stdin/stdout handles it was given.</summary>
    public bool LowIntegrity { get; init; } = true;

    /// <summary>Per-process memory cap. A runaway decoder fails instead of exhausting the PC.</summary>
    public ulong ProcessMemoryLimitBytes { get; init; } = 4UL << 30;
}

/// <summary>
/// One worker process inside its own Job Object. The job is the Windows counterpart of the Mac
/// worker's process group: killing the job kills the worker and everything it started (FFmpeg
/// later), and closing the job's last handle does the same, so nothing outlives the app.
/// The process starts suspended, joins the job, and only then runs, so no code runs outside it.
/// Only the three standard handles are inherited (PROC_THREAD_ATTRIBUTE_HANDLE_LIST).
/// </summary>
[SupportedOSPlatform("windows")]
internal sealed class SandboxedProcess : IDisposable
{
    private readonly SafeKernelHandle _job;
    private readonly SafeKernelHandle _process;
    private readonly TaskCompletionSource _exited = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly RegisteredWaitHandle _registration;
    private readonly ProcessWaitHandle _waitHandle;

    private SandboxedProcess(SafeKernelHandle job, SafeKernelHandle process, int processId)
    {
        _job = job;
        _process = process;
        ProcessId = processId;
        _waitHandle = new ProcessWaitHandle(process);
        _registration = ThreadPool.RegisterWaitForSingleObject(_waitHandle, (_, _) => _exited.TrySetResult(), null, Timeout.Infinite, true);
    }

    public int ProcessId { get; }

    public Task Exited => _exited.Task;

    public static SandboxedProcess Start(
        string executable, IReadOnlyList<string> arguments, SafeHandle stdin, SafeHandle stdout, SafeHandle stderr, SandboxOptions options)
    {
        var job = CreateJob(options);
        try
        {
            var (process, processId) = Launch(executable, arguments, stdin, stdout, stderr, options, job);
            return new SandboxedProcess(job, process, processId);
        }
        catch
        {
            job.Dispose();
            throw;
        }
    }

    /// <summary>Stops the worker and every process it started, immediately.</summary>
    public void KillTree() => TerminateJobObject(_job, 1);

    public uint ExitCode => GetExitCodeProcess(_process, out var code) ? code : uint.MaxValue;

    public void Dispose()
    {
        _registration.Unregister(null);
        _waitHandle.Dispose();
        _process.Dispose();
        _job.Dispose(); // KILL_ON_JOB_CLOSE: anything still running in the job stops here
    }

    private static SafeKernelHandle CreateJob(SandboxOptions options)
    {
        var job = CreateJobObject(IntPtr.Zero, null);
        if (job.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "Couldn't create a job object.");
        var limits = new JobExtendedLimitInformation
        {
            BasicLimitInformation = new JobBasicLimitInformation
            {
                LimitFlags = JobObjectLimitKillOnJobClose | JobObjectLimitDieOnUnhandledException | JobObjectLimitProcessMemory,
            },
            ProcessMemoryLimit = (UIntPtr)options.ProcessMemoryLimitBytes,
        };
        if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, ref limits, Marshal.SizeOf<JobExtendedLimitInformation>()))
        {
            var error = Marshal.GetLastWin32Error();
            job.Dispose();
            throw new Win32Exception(error, "Couldn't limit the job object.");
        }
        // No clipboard, no global atoms, no other processes' windows, no display or system settings.
        var ui = JobObjectUiLimitAll;
        if (!SetInformationJobObject(job, JobObjectBasicUiRestrictions, ref ui, sizeof(uint)))
        {
            var error = Marshal.GetLastWin32Error();
            job.Dispose();
            throw new Win32Exception(error, "Couldn't restrict the job object.");
        }
        return job;
    }

    private static (SafeKernelHandle Process, int Id) Launch(
        string executable, IReadOnlyList<string> arguments, SafeHandle stdin, SafeHandle stdout, SafeHandle stderr,
        SandboxOptions options, SafeKernelHandle job)
    {
        SafeHandle[] handles = [stdin, stdout, stderr];
        foreach (var handle in handles)
        {
            if (!SetHandleInformation(handle, HandleFlagInherit, HandleFlagInherit))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Couldn't pass a handle to the converter.");
            }
        }

        var commandLine = (string.Join(' ', new[] { executable }.Concat(arguments).Select(Ameya.Core.Worker.WorkerProtocol.QuoteArgument)) + '\0').ToCharArray();
        var handleList = Marshal.AllocHGlobal(IntPtr.Size * handles.Length);
        var attributeList = IntPtr.Zero;
        var addRefs = new bool[handles.Length];
        try
        {
            for (var i = 0; i < handles.Length; i++)
            {
                handles[i].DangerousAddRef(ref addRefs[i]);
                Marshal.WriteIntPtr(handleList, i * IntPtr.Size, handles[i].DangerousGetHandle());
            }
            var size = IntPtr.Zero;
            InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
            attributeList = Marshal.AllocHGlobal(size);
            if (!InitializeProcThreadAttributeList(attributeList, 1, 0, ref size))
            {
                Marshal.FreeHGlobal(attributeList);
                attributeList = IntPtr.Zero;
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Couldn't prepare the converter's handles.");
            }
            if (!UpdateProcThreadAttribute(attributeList, 0, ProcThreadAttributeHandleList, handleList,
                    IntPtr.Size * handles.Length, IntPtr.Zero, IntPtr.Zero))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Couldn't prepare the converter's handles.");
            }

            var startup = new StartupInfoEx { AttributeList = attributeList };
            startup.StartupInfo.Cb = Marshal.SizeOf<StartupInfoEx>();
            startup.StartupInfo.Flags = StartfUseStdHandles;
            startup.StartupInfo.StdInput = stdin.DangerousGetHandle();
            startup.StartupInfo.StdOutput = stdout.DangerousGetHandle();
            startup.StartupInfo.StdError = stderr.DangerousGetHandle();
            const uint flags = CreateSuspended | CreateNoWindow | ExtendedStartupInfoPresent;
            var directory = Path.GetDirectoryName(executable);

            ProcessInformation info;
            bool started;
            if (options.LowIntegrity)
            {
                using var token = LowIntegrityToken.Create();
                started = CreateProcessAsUser(token, executable, commandLine, IntPtr.Zero, IntPtr.Zero, true, flags,
                    IntPtr.Zero, directory, ref startup, out info);
            }
            else
            {
                started = CreateProcess(executable, commandLine, IntPtr.Zero, IntPtr.Zero, true, flags,
                    IntPtr.Zero, directory, ref startup, out info);
            }
            if (!started) throw new Win32Exception(Marshal.GetLastWin32Error(), "Couldn't start the converter.");

            var process = new SafeKernelHandle(info.Process);
            using var thread = new SafeKernelHandle(info.Thread);
            if (!AssignProcessToJobObject(job, process))
            {
                var error = Marshal.GetLastWin32Error();
                TerminateProcess(process, 1);
                process.Dispose();
                throw new Win32Exception(error, "Couldn't put the converter in its sandbox.");
            }
            if (ResumeThread(thread) == uint.MaxValue)
            {
                var error = Marshal.GetLastWin32Error();
                TerminateJobObject(job, 1);
                process.Dispose();
                throw new Win32Exception(error, "Couldn't start the converter.");
            }
            return (process, info.ProcessId);
        }
        finally
        {
            if (attributeList != IntPtr.Zero)
            {
                DeleteProcThreadAttributeList(attributeList);
                Marshal.FreeHGlobal(attributeList);
            }
            Marshal.FreeHGlobal(handleList);
            for (var i = 0; i < handles.Length; i++)
            {
                if (addRefs[i]) handles[i].DangerousRelease();
            }
        }
    }

    /// <summary>Lets the thread pool wait on the process handle without a blocked thread.</summary>
    private sealed class ProcessWaitHandle : WaitHandle
    {
        public ProcessWaitHandle(SafeKernelHandle process) =>
            SafeWaitHandle = new SafeWaitHandle(process.DangerousGetHandle(), ownsHandle: false);
    }
}
