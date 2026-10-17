import Foundation

/// Receiver-only settings. Never change the Mac's system mouse or trackpad preferences.
struct ReceiverInputProfile: Codable, Equatable, Sendable {
    var pointerScale: Double = 1
    var scrollScale: Double = 1
    var reverseScroll: Bool = false

    var bounded: Self {
        Self(pointerScale: Self.bound(pointerScale), scrollScale: Self.bound(scrollScale),
             reverseScroll: reverseScroll)
    }
    private static func bound(_ value: Double) -> Double {
        value.isFinite ? min(4, max(0.25, value)) : 1
    }
    var command: Data {
        let value = bounded
        let object: [String: Any] = ["type": "profile", "pointerScale": value.pointerScale,
                                    "scrollScale": value.scrollScale, "reverseScroll": value.reverseScroll]
        return (try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) + Data([10])
    }
}

struct ReceiverProfileSettings: Codable, Equatable {
    var defaultProfile = ReceiverInputProfile()
    var applications: [String: ReceiverInputProfile] = [:]
    static let maximumApplications = 128

    func profile(for bundleID: String?) -> ReceiverInputProfile {
        (bundleID.flatMap { applications[$0] } ?? defaultProfile).bounded
    }
    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 255
            && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0)
                || (97...122).contains($0) || $0 == 45 || $0 == 46 }
    }
    var sanitized: Self {
        var result = Self()
        result.defaultProfile = defaultProfile.bounded
        for id in applications.keys.sorted().filter(Self.validID).prefix(Self.maximumApplications) {
            result.applications[id] = applications[id]?.bounded
        }
        return result
    }
}

/// Export only a deliberately small allowlist. Never serialize ReceiverState or raw failures.
enum ReceiverDiagnosticExport {
    static func data(status: String, inputStatus: String?, connected: Bool, dryRun: Bool,
                     interfaceCount: Int, processingCount: Int64?, lastMilliseconds: Double?,
                     maximumMilliseconds: Double?) throws -> Data {
        let knownStatuses = ["ready", "accessibility_required", "desktop_unavailable", "dry_run", "input_unavailable"]
        var value: [String: Any] = [
            "schemaVersion": 1, "platform": "macos",
            "receiverStatus": ["paused", "pausing", "starting", "stopping", "running", "unavailable"].contains(status) ? status : "unavailable",
            "inputStatus": knownStatuses.contains(inputStatus ?? "") ? inputStatus! : "unknown",
            "connected": connected, "dryRun": dryRun, "interfaceCount": min(16, max(0, interfaceCount)),
            "latencyScope": "Receiver action processing only; excludes phone, network, display and application response.",
            "endToEndLatency": "not measured",
            "redacted": ["pairing credentials", "QR images and URIs", "host and IP addresses", "application identifiers", "typed text", "raw errors"]
        ]
        if let count = processingCount, count >= 0 { value["processedActions"] = count }
        if let ms = lastMilliseconds, ms.isFinite, ms >= 0 { value["lastProcessingMilliseconds"] = ms }
        if let ms = maximumMilliseconds, ms.isFinite, ms >= 0 { value["maximumProcessingMilliseconds"] = ms }
        return try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    }
}
