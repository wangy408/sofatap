namespace SofaTap;

// Local native-parent configuration only. This is deliberately separate from ActionMessage.
internal sealed record MacInputProfile(double PointerScale, double ScrollScale, bool ReverseScroll)
{
    internal static bool ValidScale(double value) => double.IsFinite(value) && value is >= 0.25 and <= 4;
}
