import Foundation

/// Pure launch/retry policy. A status frame proves the helper is alive, not input permission.
/// The budget is reset only by an explicit user start/restart, never by a flapping helper.
struct ReceiverRecoveryPolicy {
    private(set) var wantsRunning = false
    private(set) var hasBeenActive = false
    private(set) var attempts = 0
    private(set) var isQuitting = false
    var isSleeping = false
    static let maximumAttempts = 3

    mutating func requestStart() {
        wantsRunning = true
        isQuitting = false
        attempts = 0
        hasBeenActive = false
    }
    mutating func receivedState() { hasBeenActive = true }
    mutating func requestStop(quitting: Bool = false) {
        wantsRunning = false
        isQuitting = quitting
    }
    var permitsRecovery: Bool { wantsRunning && hasBeenActive && !isSleeping && !isQuitting }
    func permitsLaunch(helperPresent: Bool, stopping: Bool) -> Bool {
        wantsRunning && !isSleeping && !isQuitting && !helperPresent && !stopping
    }
    mutating func takeRecoveryAttempt() -> Int? {
        guard permitsRecovery, attempts < Self.maximumAttempts else { return nil }
        attempts += 1
        return attempts
    }
}
