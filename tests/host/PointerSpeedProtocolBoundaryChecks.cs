using System.Text;
using System.Text.Json;
using SofaTap;

static class PointerSpeedProtocolBoundaryChecks
{
    public static void Run(Action<bool, string> check)
    {
        // The slider is a local receiver setting, never a phone control action.
        foreach (var body in new[]
        {
            "{\"type\":\"setPointerSpeed\",\"value\":2}",
            "{\"id\":\"3a33231b-c402-4dc2-a4ea-e28f6a8f7862\",\"type\":\"setPointerSpeed\",\"value\":2}",
            "{\"id\":\"3a33231b-c402-4dc2-a4ea-e28f6a8f7862\",\"type\":\"move\",\"dx\":1,\"dy\":1,\"value\":2}",
            "{\"id\":\"3a33231b-c402-4dc2-a4ea-e28f6a8f7862\",\"type\":\"move\",\"dx\":1,\"dy\":1,\"pointerSpeed\":2}"
        })
        {
            var rejected = false;
            try { Protocol.Parse(Encoding.UTF8.GetBytes(body)); }
            catch (ProtocolException) { rejected = true; }
            check(rejected, "phone protocol rejects private pointer-speed commands and fields");
        }

        var hello = JsonSerializer.SerializeToElement(ReceiverServer.CreateHello(
            "synthetic-device", "macos", false, "ready", new("unknown", 0)));
        check(hello.GetProperty("version").GetInt32() == 1,
            "pointer-speed setting preserves phone protocol version");
        check(!hello.TryGetProperty("pointerSpeed", out _) && !hello.TryGetProperty("setPointerSpeed", out _),
            "pointer-speed setting is not advertised as a phone capability");

        var defaultSink = new RecordingMacSink();
        var explicitSink = new RecordingMacSink();
        var defaultInput = new MacInput(defaultSink);
        var explicitInput = new MacInput(explicitSink);
        explicitInput.SetPointerSpeed(1);
        foreach (var action in new ActionMessage[]
        {
            new("", "move", Dx: -.4, Dy: .4),
            new("", "move", Dx: -.4, Dy: .4),
            new("", "move", Dx: -.4, Dy: .4),
            new("", "button", Button: "right", Down: true),
            new("", "move", Dx: -2.5, Dy: -1.5),
            new("", "button", Button: "right", Down: false),
            new("", "scroll", Dx: -.5, Dy: .5),
            new("", "scroll", Dx: -.5, Dy: .5)
        })
        {
            defaultInput.Apply(action);
            explicitInput.Apply(action);
        }
        check(defaultSink.Events.SequenceEqual(explicitSink.Events),
            "explicit 1x and default produce identical movement, right drag, and scroll events");
        check(defaultSink.Events[0] is { DeltaX: -1, DeltaY: 1 },
            "1x preserves signed fractional accumulation and truncation toward zero");
        check(defaultSink.Events.Any(item => item is { MouseType: 7, DeltaX: -2, DeltaY: -1 }),
            "1x preserves right-drag event kind and fractional remainder");
    }
}
