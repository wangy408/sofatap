using System.Text;
using System.Text.Json;
using SofaTap;

internal static class MacInputProfileChecks
{
    internal static void Run(Action<bool, string> check)
    {
        var sink = new RecordingMacSink();
        var input = new MacInput(sink);
        input.Apply(new("", "move", Dx: 2, Dy: -3));
        check(sink.CursorPosition == new MacPoint(102, 97), "default Mac profile preserves pointer movement");
        input.SetProfile(2, .5, true);
        input.Apply(new("", "move", Dx: 2, Dy: -3));
        check(sink.CursorPosition == new MacPoint(106, 91), "Mac profile scales pointer axes");
        input.Apply(new("", "scroll", Dx: 6, Dy: -8));
        check(sink.Events[^1] is { Kind: MacEventKind.Scroll, DeltaX: -3, DeltaY: 4 },
            "Mac profile scales and reverses both scroll axes");

        var fractionalSink = new RecordingMacSink();
        var fractional = new MacInput(fractionalSink);
        fractional.SetProfile(.25, .25, false);
        for (var i = 0; i < 4; i++)
        {
            fractional.SetProfile(.25, .25, false);
            fractional.Apply(new("", "move", Dx: 1, Dy: -1));
            fractional.Apply(new("", "scroll", Dx: 1, Dy: -1));
        }
        check(fractionalSink.CursorPosition == new MacPoint(101, 99)
            && fractionalSink.Events.Count == 2 && fractionalSink.Events[^1].DeltaY == -1,
            "unchanged profile preserves subpoint movement and scroll accumulation");

        var resetSink = new RecordingMacSink();
        var reset = new MacInput(resetSink);
        reset.Apply(new("", "move", Dx: .75, Dy: -.75));
        reset.Apply(new("", "scroll", Dx: .75, Dy: -.75));
        reset.SetProfile(2, 2, false);
        reset.Apply(new("", "move", Dx: .2, Dy: -.2));
        reset.Apply(new("", "scroll", Dx: .2, Dy: -.2));
        check(resetSink.Events.Count == 0, "changed Mac profile discards previous fractional remainders");

        foreach (var invalid in new[] { double.NaN, double.PositiveInfinity, double.NegativeInfinity, 0, .249, 4.001 })
        {
            foreach (var pointer in new[] { true, false })
            {
                try
                {
                    input.SetProfile(pointer ? invalid : 1, pointer ? 1 : invalid, false);
                    throw new Exception("Invalid profile accepted.");
                }
                catch (ArgumentOutOfRangeException) { check(true, "Mac profile rejects invalid scale"); }
            }
        }
        input.Apply(new("", "scroll", Dx: 4, Dy: 0));
        check(sink.Events[^1].DeltaX == -2, "invalid profile cannot partially replace active settings");
        input.SetProfile(4, .25, false);
        input.Apply(new("", "button", Button: "left", Down: true));
        var heldCount = sink.Events.Count;
        input.SetProfile(1, 1, false);
        check(sink.Events.Count == heldCount && sink.HeldButtons.Contains(0), "profile update does not synthesize a drag release");
        input.ReleaseAll();
        check(sink.HeldButtons.Count == 0 && sink.Events[^1].MouseType == 2, "release still clears owned drag after profile update");

        foreach (var scale in new[] { .25, 1, 4 })
        {
            var json = JsonSerializer.Serialize(new { type = "profile", pointerScale = scale, scrollScale = scale, reverseScroll = true });
            check(NativeDesktopBridge.ParseCommand(json, out var profile) == "profile"
                && profile == new MacInputProfile(scale, scale, true), "private profile command round trip");
        }
        string[] invalidCommands =
        [
            """{"type":"profile"}""",
            """{"type":"profile","pointerScale":1,"scrollScale":1,"reverseScroll":0}""",
            """{"type":"profile","pointerScale":"1","scrollScale":1,"reverseScroll":false}""",
            """{"type":"profile","pointerScale":1e999,"scrollScale":1,"reverseScroll":false}""",
            """{"type":"profile","pointerScale":0.24,"scrollScale":1,"reverseScroll":false}""",
            """{"type":"profile","pointerScale":1,"scrollScale":4.1,"reverseScroll":false}""",
            """{"type":"profile","pointerScale":1,"scrollScale":1,"reverseScroll":false,"app":"private"}""",
            """{"type":"profile","pointerScale":1,"pointerScale":2,"reverseScroll":false}""",
            """{"type":"profile","pointerScale":1,"scrollScale":null,"reverseScroll":false}"""
        ];
        foreach (var json in invalidCommands)
        {
            try { NativeDesktopBridge.ParseCommand(json); throw new Exception("Invalid native profile accepted."); }
            catch (InvalidDataException error) { check(!error.Message.Contains(json), "private profile rejects malformed values without echo"); }
        }
        try
        {
            Protocol.Parse(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new
            {
                id = Guid.NewGuid().ToString("D"), type = "profile", pointerScale = 1, scrollScale = 1, reverseScroll = false
            })));
            throw new Exception("Phone profile accepted.");
        }
        catch (ProtocolException) { check(true, "phone protocol cannot set local profiles"); }

        var diagnostics = new ReceiverActionDiagnostics();
        var fake = new FakeInput();
        var session = new ActionSession(fake);
        var action = new ActionMessage(Guid.NewGuid().ToString("D"), "move", Dx: 1);
        diagnostics.Execute(session, action);
        diagnostics.Execute(session, action);
        check(fake.Count == 1, "diagnostic wrapper preserves duplicate action suppression");
        fake.Fail = true;
        check(!diagnostics.Execute(session, action with { Id = Guid.NewGuid().ToString("D") }).Ok,
            "diagnostic wrapper preserves injection failure");
        var snapshot = JsonSerializer.SerializeToElement(diagnostics.Snapshot());
        check(snapshot.EnumerateObject().Select(field => field.Name).Order().SequenceEqual(
            new[] { "actionCount", "lastProcessingMs", "maxProcessingMs" }),
            "diagnostics serialize only numeric aggregates");
        check(snapshot.GetProperty("actionCount").GetInt64() == 3
            && snapshot.GetProperty("lastProcessingMs").GetDouble() >= 0
            && snapshot.GetProperty("maxProcessingMs").GetDouble() >= snapshot.GetProperty("lastProcessingMs").GetDouble(),
            "diagnostics count handled attempts and monotonic processing duration");
        try
        {
            diagnostics.Execute(new ActionSession(fake, maximumActions: 0), action);
            throw new Exception("Expected action limit.");
        }
        catch (ProtocolException)
        {
            check(JsonSerializer.SerializeToElement(diagnostics.Snapshot()).GetProperty("actionCount").GetInt64() == 4,
                "diagnostics record thrown session failures");
        }
        check(JsonSerializer.SerializeToElement(new ReceiverActionDiagnostics().Snapshot()).GetProperty("actionCount").GetInt64() == 0,
            "fresh helper diagnostics have no retained history");
    }
}
