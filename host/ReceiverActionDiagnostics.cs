using System.Diagnostics;

namespace SofaTap;

/// <summary>Process-lifetime numeric aggregates only; no action content or identities are retained.</summary>
internal sealed class ReceiverActionDiagnostics
{
    private readonly object _gate = new();
    private long _count;
    private double _lastMs, _maxMs;

    internal ActionAck Execute(ActionSession session, ActionMessage action)
    {
        var start = Stopwatch.GetTimestamp();
        try { return session.Execute(action); }
        finally
        {
            var elapsed = Stopwatch.GetElapsedTime(start).TotalMilliseconds;
            lock (_gate)
            {
                if (_count < long.MaxValue) _count++;
                _lastMs = elapsed;
                _maxMs = Math.Max(_maxMs, elapsed);
            }
        }
    }

    internal object Snapshot()
    {
        lock (_gate) return new { actionCount = _count, lastProcessingMs = _lastMs, maxProcessingMs = _maxMs };
    }
}
