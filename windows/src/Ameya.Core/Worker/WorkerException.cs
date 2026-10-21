namespace Ameya.Core.Worker;

public enum WorkerFailure
{
    TimedOut,
    Cancelled,
    Crashed,
    Failed,
    OutputExists,
    CannotOpenInput,
    CannotCreateOutput,
    ProtocolViolation,
}

/// <summary>Why a job didn't produce a file. The message is plain words for the person using Ameya.</summary>
public sealed class WorkerException : Exception
{
    public WorkerException(WorkerFailure failure, string message) : base(message) => Failure = failure;

    public WorkerFailure Failure { get; }

    public static WorkerException TimedOut(TimeSpan after) =>
        new(WorkerFailure.TimedOut, $"Stopped after {(int)after.TotalSeconds} seconds without finishing.");

    public static WorkerException Cancelled() => new(WorkerFailure.Cancelled, "Cancelled.");

    public static WorkerException Crashed(uint code) =>
        new(WorkerFailure.Crashed, $"The converter crashed (code 0x{code:X8}). Your original file is untouched.");

    public static WorkerException Failed(string message) => new(WorkerFailure.Failed, message);

    public static WorkerException OutputExists(string name) =>
        new(WorkerFailure.OutputExists, $"{name} already exists, so nothing was overwritten.");

    public static WorkerException CannotOpenInput(string name) => new(WorkerFailure.CannotOpenInput, $"Couldn't open {name}.");

    public static WorkerException CannotCreateOutput(string name) => new(WorkerFailure.CannotCreateOutput, $"Couldn't create {name}.");

    public static WorkerException ProtocolViolation(string detail) =>
        new(WorkerFailure.ProtocolViolation, $"The converter sent an unexpected reply: {detail}");
}
