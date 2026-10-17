import Foundation

/// Independent audit of the new local-only configuration and export boundaries.
@main
enum ReceiverControlAuditTests {
    static func main() throws {
        let allowed: Set<String> = ["schemaVersion", "platform", "receiverStatus", "inputStatus",
            "connected", "dryRun", "interfaceCount", "latencyScope", "endToEndLatency",
            "redacted", "processedActions", "lastProcessingMilliseconds", "maximumProcessingMilliseconds"]
        let marker = "private-token-host-app-typed-text"
        for status in ["running", "paused", "pausing", marker] {
            let data = try ReceiverDiagnosticExport.data(status: status, inputStatus: marker,
                connected: false, dryRun: false, interfaceCount: Int.max, processingCount: Int64.max,
                lastMilliseconds: 2, maximumMilliseconds: 3)
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            precondition(Set(object.keys).isSubset(of: allowed))
            precondition(!String(decoding: data, as: UTF8.self).contains(marker))
            precondition(object["inputStatus"] as? String == "unknown")
            precondition(object["interfaceCount"] as? Int == 16)
            precondition(object["endToEndLatency"] as? String == "not measured")
        }
        for invalid in ["", "com.example/../secret", "com.example\nsecret", String(repeating: "x", count: 256)] {
            precondition(!ReceiverProfileSettings.validID(invalid))
        }
        var settings = ReceiverProfileSettings()
        settings.defaultProfile = ReceiverInputProfile(pointerScale: 0.25, scrollScale: 4, reverseScroll: true)
        settings.applications["com.example.valid"] = ReceiverInputProfile(pointerScale: 3, scrollScale: 2)
        settings.applications[marker + "/invalid"] = ReceiverInputProfile(pointerScale: 4)
        let clean = settings.sanitized
        precondition(clean.applications.count == 1)
        precondition(clean.profile(for: nil) == clean.defaultProfile)
        precondition(clean.profile(for: "com.example.missing") == clean.defaultProfile)
        for n in [-Double.infinity, -1, 0, 0.25, 1, 4, 5, Double.infinity, Double.nan] {
            let command = ReceiverInputProfile(pointerScale: n, scrollScale: n).command
            let object = try JSONSerialization.jsonObject(with: command) as! [String: Any]
            precondition(Set(object.keys) == ["type", "pointerScale", "scrollScale", "reverseScroll"])
            for key in ["pointerScale", "scrollScale"] {
                let value = object[key] as! Double
                precondition(value.isFinite && (0.25...4).contains(value))
            }
        }
        let legacy = Data(#"{"type":"state","name":"fixture","platform":"macos","inputStatus":"ready","dryRun":true,"connected":false,"pairings":[]}"#.utf8)
        let decoded = try ReceiverState.decode(legacy)
        precondition(decoded.diagnostics == nil)
        print("PASS: independent export allowlist, profile bounds, fallback and legacy state compatibility")
    }
}
