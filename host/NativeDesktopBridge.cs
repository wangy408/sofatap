using System.Diagnostics;
using System.Text.Json;

namespace SofaTap;

/// <summary>Private inherited pipes only. Pairing credentials never have an HTTP/HTML endpoint.</summary>
public static class NativeDesktopBridge
{
    public static async Task RunAsync(WebApplication app, ReceiverServer server, bool dryRun)
    {
        using var stopped = CancellationTokenSource.CreateLinkedTokenSource(app.Lifetime.ApplicationStopping);
        using var gate = new SemaphoreSlim(1, 1);
        using var reader = new StreamReader(Console.OpenStandardInput());
        using var writer = new StreamWriter(Console.OpenStandardOutput()) { AutoFlush = true };
        async Task State()
        {
            await gate.WaitAsync(stopped.Token);
            try { await writer.WriteLineAsync(JsonSerializer.Serialize(server.NativeState()).AsMemory(), stopped.Token); }
            finally { gate.Release(); }
        }
        async Task Updates()
        {
            using var timer = new PeriodicTimer(TimeSpan.FromSeconds(2));
            await State();
            while (await timer.WaitForNextTickAsync(stopped.Token)) await State();
        }
        async Task Commands()
        {
            while (!stopped.IsCancellationRequested)
            {
                var line = await ReadLine(reader, stopped.Token);
                if (line is null) break; // Closing the parent UI closes input and ends control.
                var command = ParseCommand(line, out var profile);
                if (command == "profile" && OperatingSystem.IsMacOS() && !dryRun && profile is not null)
                    server.SetMacInputProfile(profile.PointerScale, profile.ScrollScale, profile.ReverseScroll);
                if (command == "quit") break;
                if (command == "requestAccess" && OperatingSystem.IsLinux() && !dryRun) server.RequestLinuxAccess();
                if (command == "requestAccess" && OperatingSystem.IsMacOS() && !dryRun)
                {
                    MacInput.RequestAccess();
                    var start = new ProcessStartInfo("/usr/bin/open") { UseShellExecute = false };
                    start.ArgumentList.Add("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility");
                    Process.Start(start)?.Dispose();
                }
                await State();
            }
        }
        await app.StartAsync(stopped.Token);
        var updates = Updates();
        var commands = Commands();
        try
        {
            var done = await Task.WhenAny(updates, commands);
            await done;
        }
        catch (OperationCanceledException) when (stopped.IsCancellationRequested) { }
        finally
        {
            app.Lifetime.StopApplication();
            await stopped.CancelAsync();
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            await app.StopAsync(timeout.Token);
            try { await Task.WhenAll(updates, commands); }
            catch (OperationCanceledException) when (stopped.IsCancellationRequested) { }
        }
    }
    internal static string ParseCommand(string line) => ParseCommand(line, out _);
    internal static string ParseCommand(string line, out MacInputProfile? profile)
    {
        profile = null;
        try
        {
            using var document = JsonDocument.Parse(line);
            if (document.RootElement.ValueKind == JsonValueKind.Object)
            {
                var fields = document.RootElement.EnumerateObject().ToArray();
                if (fields.Length == 1 && fields[0].Name == "type" && fields[0].Value.ValueKind == JsonValueKind.String
                    && fields[0].Value.GetString() is "refresh" or "requestAccess" or "quit")
                    return fields[0].Value.GetString()!;
                // Reject duplicates and unknown fields, including values that overflow to infinity.
                var root = document.RootElement;
                if (fields.Length == 4 && fields.Select(field => field.Name).Distinct(StringComparer.Ordinal).Count() == 4
                    && root.TryGetProperty("type", out var type) && type.ValueKind == JsonValueKind.String && type.GetString() == "profile"
                    && root.TryGetProperty("pointerScale", out var pointer) && pointer.ValueKind == JsonValueKind.Number
                    && pointer.TryGetDouble(out var pointerScale) && MacInputProfile.ValidScale(pointerScale)
                    && root.TryGetProperty("scrollScale", out var scroll) && scroll.ValueKind == JsonValueKind.Number
                    && scroll.TryGetDouble(out var scrollScale) && MacInputProfile.ValidScale(scrollScale)
                    && root.TryGetProperty("reverseScroll", out var reverse) && reverse.ValueKind is JsonValueKind.True or JsonValueKind.False)
                {
                    profile = new(pointerScale, scrollScale, reverse.GetBoolean());
                    return "profile";
                }
            }
        }
        catch (JsonException) { }
        throw new InvalidDataException("Invalid native window command. Restart Sofatap.");
    }
    private static async Task<string?> ReadLine(StreamReader reader, CancellationToken cancellation)
    {
        var line = new System.Text.StringBuilder();
        var buffer = new char[1];
        while (await reader.ReadAsync(buffer.AsMemory(), cancellation) > 0)
        {
            if (buffer[0] == '\n') return line.ToString().TrimEnd('\r');
            if (line.Length >= 4096) throw new InvalidDataException("Native window command is too large.");
            line.Append(buffer[0]);
        }
        return line.Length == 0 ? null : throw new InvalidDataException("Native window disconnected mid-command.");
    }
}
