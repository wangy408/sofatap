import Foundation

@main
enum ReceiverRecoveryPolicyTests {
    static func main() {
        var policy = ReceiverRecoveryPolicy()
        precondition(!policy.permitsLaunch(helperPresent: false, stopping: false))
        precondition(policy.takeRecoveryAttempt() == nil)
        policy.requestStart()
        precondition(policy.permitsLaunch(helperPresent: false, stopping: false))
        precondition(!policy.permitsLaunch(helperPresent: true, stopping: false))
        precondition(!policy.permitsLaunch(helperPresent: false, stopping: true))
        // Startup failures cannot enter an automatic crash loop.
        precondition(policy.takeRecoveryAttempt() == nil)
        policy.receivedState() // Any valid state, including permission-blocked, is live transport.
        precondition(policy.takeRecoveryAttempt() == 1)
        policy.receivedState()
        precondition(policy.takeRecoveryAttempt() == 2)
        policy.receivedState()
        precondition(policy.takeRecoveryAttempt() == 3)
        policy.receivedState()
        precondition(policy.takeRecoveryAttempt() == nil) // Healthy-looking startup does not refill budget.
        policy.requestStart()
        policy.receivedState()
        policy.isSleeping = true
        precondition(policy.takeRecoveryAttempt() == nil && policy.attempts == 0)
        precondition(!policy.permitsLaunch(helperPresent: false, stopping: false))
        policy.isSleeping = false
        precondition(policy.takeRecoveryAttempt() == 1)
        policy.requestStop()
        precondition(policy.takeRecoveryAttempt() == nil)
        precondition(!policy.permitsLaunch(helperPresent: false, stopping: false))
        policy.isSleeping = true
        policy.isSleeping = false
        precondition(policy.takeRecoveryAttempt() == nil) // Wake cannot resume a paused receiver.
        policy.requestStart()
        policy.receivedState()
        policy.requestStop(quitting: true)
        precondition(policy.isQuitting && policy.takeRecoveryAttempt() == nil)
        precondition(!policy.permitsLaunch(helperPresent: false, stopping: false))
        policy.receivedState() // A late state cannot cancel the user's stop intent.
        precondition(policy.takeRecoveryAttempt() == nil)
        policy.requestStop() // Failed Quit re-enables an explicit Pause retry, never automatic input.
        precondition(!policy.isQuitting && !policy.wantsRunning && policy.takeRecoveryAttempt() == nil)
        precondition(!policy.permitsLaunch(helperPresent: false, stopping: false))
        policy.requestStart()
        precondition(!policy.isQuitting && policy.attempts == 0 && !policy.hasBeenActive)
        print("PASS: owned-child launch gate, bounded prior-active recovery, sleep/pause/quit suppression and explicit retry reset")
    }
}
