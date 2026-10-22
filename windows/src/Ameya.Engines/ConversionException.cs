namespace Ameya.Engines;

/// <summary>A conversion that can't be done, with a plain-words reason for the person using Ameya.</summary>
public sealed class ConversionException : Exception
{
    public ConversionException() { }

    public ConversionException(string message) : base(message) { }

    public ConversionException(string message, Exception inner) : base(message, inner) { }
}
