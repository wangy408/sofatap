import Foundation

@main
enum ReceiverControlModelsTests {
    static func main() throws {
        precondition(ReceiverInputProfile(pointerScale: .nan, scrollScale: .infinity).bounded == ReceiverInputProfile())
        precondition(ReceiverInputProfile(pointerScale: -3, scrollScale: 100).bounded ==
            ReceiverInputProfile(pointerScale: 0.25, scrollScale: 4))
        let profile = ReceiverInputProfile(pointerScale: 2, scrollScale: 0.5, reverseScroll: true)
        let command = try JSONSerialization.jsonObject(with: profile.command) as! [String: Any]
        precondition(command.count == 4 && command["type"] as? String == "profile")
        precondition(command["pointerScale"] as? Double == 2 && command["reverseScroll"] as? Bool == true)
        precondition(profile.command.last == 10)
        var settings = ReceiverProfileSettings()
        settings.defaultProfile = ReceiverInputProfile(pointerScale: 1.5)
        settings.applications["com.example.editor"] = profile
        settings.applications["bad\nidentifier"] = profile
        precondition(settings.profile(for: "com.example.editor") == profile)
        precondition(settings.profile(for: nil).pointerScale == 1.5)
        precondition(settings.profile(for: "com.example.other").pointerScale == 1.5)
        precondition(settings.sanitized.applications.count == 1)
        for i in 0..<200 { settings.applications["com.example.app\(i)"] = profile }
        precondition(settings.sanitized.applications.count == ReceiverProfileSettings.maximumApplications)
        let saved = try JSONEncoder().encode(settings.sanitized)
        let restored = try JSONDecoder().decode(ReceiverProfileSettings.self, from: saved)
        precondition(restored == settings.sanitized)
        let data = try ReceiverDiagnosticExport.data(status: "running", inputStatus: "secret-token",
            connected: true, dryRun: false, interfaceCount: 40, processingCount: 4,
            lastMilliseconds: 1.2, maximumMilliseconds: 3.4)
        let diagnostic = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(diagnostic["inputStatus"] as? String == "unknown")
        precondition(diagnostic["interfaceCount"] as? Int == 16)
        precondition(diagnostic["endToEndLatency"] as? String == "not measured")
        precondition(diagnostic["lastProcessingMilliseconds"] as? Double == 1.2)
        precondition(!String(decoding: data, as: UTF8.self).contains("secret-token"))
        let invalid = try ReceiverDiagnosticExport.data(status: "private-value", inputStatus: nil,
            connected: false, dryRun: true, interfaceCount: -1, processingCount: -1,
            lastMilliseconds: .nan, maximumMilliseconds: .infinity)
        let clean = try JSONSerialization.jsonObject(with: invalid) as! [String: Any]
        precondition(clean["lastProcessingMilliseconds"] == nil && clean["processedActions"] == nil)
        precondition(clean["receiverStatus"] as? String == "unavailable")
        print("PASS: bounded profiles, per-app fallback, persistence and redacted diagnostic allowlist (no UI/input)")
    }
}
