# Mac native receiver window

The launcher is an AppKit application with a SwiftUI view. It embeds no web view and opens no browser. The bundle contains the launcher at `Contents/MacOS/SofaTap` and the .NET receiver at the fixed path `Contents/Helpers/SofaTapHost`.

Its native window follows the selected [Mint Calm receiver design](../../docs/RECEIVER-DESIGN.md), shared with Windows and Linux. Permission, disconnected, dry-run and failure states remain distinct from a ready desktop.

## Offline appearance fixtures

Render the production content without opening a window, launching the receiver, requesting permission or connecting a phone:

```sh
xcrun swiftc -parse-as-library -swift-version 5 -D SOFATAP_UI_FIXTURE \
  -target "$(uname -m)-apple-macosx15.0" desktop/macos/*.swift \
  desktop/macos/tests/ReceiverAppearanceFixtures.swift -o /tmp/sofatap-appearance-fixtures
/tmp/sofatap-appearance-fixtures artifacts/mint-calm
```

The PNGs use reserved example addresses and an unusable pairing fixture. They check the content layout, including long labels and permission/error states; they do not exercise the native title bar, scrolling, keyboard focus, camera pairing or actual desktop input. The fixture entry point is excluded from the production build.

The launcher starts that helper with `--native-ui`. Passing `--dry-run` explicitly to the launcher also passes this fixed flag to the helper; it is for transport/UI development and is clearly labelled in the window. The production app does not accept a helper executable override.

### Pairing QA on an existing virtual display

After checking the Yomado display ID and the user's unchanged physical display arrangement, launch the signed receiver executable directly with both QA arguments:

```sh
"/path/to/Sofatap Receiver.app/Contents/MacOS/SofaTap" --dry-run --test-display-id 20
```

Replace `20` with the verified current display ID. The option refuses the primary display, mirrored/inactive/missing displays, and displays too small for the receiver. It requires `--dry-run`, never falls back to the primary display, and uses the chosen screen's AppKit `visibleFrame`; do not convert external screenshot coordinates into a launch position. Invalid arguments stop before creating a window or starting the helper.

This mode shows the actual receiver in a fixed, nonactivating panel with no key/main focus, no Dock icon, and no call to activate the app. A lost or newly primary/mirrored target hides the panel and stops its helper. The normal double-click launch retains its usual window and activation behavior. Use the executable directly: opening through Finder/Launch Services can independently request activation. The test option does not create a display, change display arrangement, or establish input isolation for other tools. Confirm the actual window bounds and unchanged foreground app before phone testing; dry-run authenticates pairing but never injects desktop input.

## Build

From the repository root, with Xcode selected:

```sh
xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macosx15.0 -O \
  -o /tmp/SofaTap-arm64 desktop/macos/*.swift
xcrun swiftc -parse-as-library -swift-version 5 -target x86_64-apple-macosx15.0 -O \
  -o /tmp/SofaTap-x86_64 desktop/macos/*.swift
```

The release bundling script supplies the matching helper architecture, Info.plist, resources, signing and notarization. Both helper and launcher must be signed as part of the same distributed app. Compiling this launcher alone does not verify installation, Accessibility authorization, notarization, or iPhone input.

## Private pipe protocol

The helper's stdout is newline-delimited JSON. Each complete `state` has `name`, `platform: "macos"`, `inputStatus`, `dryRun`, `connected`, and `pairings: [{host, uri, qrPng}]`. `qrPng` is a base64 PNG. The protocol allowlists only `{"type":"refresh"}`, `{"type":"requestAccess"}` or `{"type":"quit"}`, each followed by a newline.

The website distribution's Mac authorization button calls Apple's [AXIsProcessTrustedWithOptions](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions) with `kAXTrustedCheckOptionPrompt: true` **from the signed parent app**, only after an explicit click. Apple's prompt is asynchronous; its immediate return value never marks the helper as ready. A separate button opens normal Accessibility settings if the prompt does not appear. The UI gives manual `+` instructions for selecting the installed `Sofatap Receiver.app`. Install the signed app at a stable path before granting permission. The helper still independently checks AX trust and event-posting access in periodic states; granting parent permission is not itself proof that helper injection works. Neither startup, Refresh nor status reads prompt for permission, and dry-run cannot request it.

The UI model is main-actor isolated. Independent `DispatchSourceRead` readers consume stdout and drain stderr using nonblocking reads; the command writer operates away from the UI thread. Do not replace these with two `FileHandle.bytes` loops: Foundation's shared serial async IO actor can block stdout behind a quiet stderr. Frame sizes and PNG dimensions are bounded before decoding, and the UI stream buffers only the latest state. A missing update for eight seconds clears visible pairing state. Process exit, malformed frames and pipe failure show a generic error and clear the QR. Raw stderr is discarded. The QR and URI are held in memory, are never logged or saved by the launcher, and only reach the clipboard after an explicit Copy action. The helper separately owns the persistent pairing profile.

Closing the normal pairing window hides it and keeps the receiver running; click the Dock icon to reopen it. The dry-run QA window still stops its helper when closed. Choosing Quit first sends `quit`. After 800 ms the launcher may call `terminate()` on its own child. It never looks up or kills other processes. If that child still has not exited after another four seconds, the app cancels its own exit and shows an error so it cannot silently leave an orphaned receiver.

This follows Apple's [Process](https://developer.apple.com/documentation/foundation/process), [terminationHandler](https://developer.apple.com/documentation/foundation/process/terminationhandler), [DispatchSourceRead](https://developer.apple.com/documentation/dispatch/dispatchsource/makereadsource(filedescriptor:queue:)) and [Pipe](https://developer.apple.com/documentation/foundation/pipe) APIs. Each dispatch source owns a duplicated file descriptor, closed only in its cancellation handler after in-flight handlers finish. Callbacks hop to the main actor before changing view state. The source also compiles in Swift 6 mode.

## Logic checks without launching a UI or helper

```sh
xcrun swiftc -parse-as-library -swift-version 5 \
  -o /tmp/SofaTap-LaunchTests desktop/macos/ReceiverLaunchOptions.swift \
  desktop/macos/tests/ReceiverLaunchOptionsTests.swift
/tmp/SofaTap-LaunchTests
xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macosx15.0 \
  -o /tmp/SofaTap-ProtocolTests desktop/macos/ReceiverProtocol.swift \
  desktop/macos/tests/ReceiverProtocolTests.swift
/tmp/SofaTap-ProtocolTests
xcrun swiftc -parse-as-library -swift-version 6 -target arm64-apple-macosx15.0 \
  -o /tmp/SofaTap-PipeTests desktop/macos/ReceiverProtocol.swift \
  desktop/macos/ReceiverPipeReader.swift desktop/macos/tests/ReceiverPipeTests.swift
/tmp/SofaTap-PipeTests
```

The checks cover fragmented UTF-8 frames, periodic permission/connection changes, network selection and removal, bounded framing, malformed messages/images, and command serialization. Real anonymous-pipe checks additionally cover a permanently quiet stderr, stderr output larger than pipe capacity, stdout EOF and malformed JSON. They do not launch `NSApplication`, a receiver, a socket, or any input injection. Native window rendering, closing/quit behavior with a real helper, and phone-to-desktop input need separate live acceptance.

## Start at login

The native **登录时自动启动** checkbox controls Apple's [`SMAppService.mainApp`](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp). On the first normal launch of the packaged app, Sofatap requests registration once. It starts **after this user logs in**, not before login or while the Mac is powered off. A login launch prepares the receiver without opening its window or taking focus; reopen from the Dock when needed.

The app reads the actual system registration state. Pending authorization (including consent revoked in System Settings) is explicitly labeled and links to Login Items settings; it never claims the receiver will start until the system allows it. Disabling the checkbox unregisters the app, and closing/reopening or upgrading does not silently re-enable it. A failed initial registration is not retried automatically; the checkbox lets the user retry. The one-time marker is stored in the receiver's own user preferences. An already enabled or pending system registration is preserved.

Raw executables, `--dry-run`, isolated test-display launches and fixture builds do not register login items or mark first-run preferences. Unit checks inject an in-memory registration service and preferences:

```sh
xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macosx15.0 \
  desktop/macos/ReceiverLoginItem.swift desktop/macos/tests/ReceiverLoginItemTests.swift \
  -o /tmp/SofaTap-LoginTests
/tmp/SofaTap-LoginTests
```

No actual login-item registration, logout/reboot or shared-desktop input is performed by these checks. A display connection change does not terminate a normal receiver; only the explicitly isolated QA launch exits if its assigned display disappears or ceases to be isolated. This change does not establish a cause for any household display-switch failure.

## Mac App Store basic build

Compile both the launcher and backend with `SOFATAP_MAC_APP_STORE` for the separate sandboxed distribution. Keep the receiver bundle identifier stable. This build is intended for manual pointer, click, drag, scrolling and ordinary text/key sending. It does not inspect other applications with Accessibility APIs, detect focused input fields or advertise precise live editing. Building the sandbox variant is not proof that event injection works through its final signed helper; real permission and input acceptance remain a release gate.

The store launcher selects only `Contents/Helpers/arm64/SofaTapHost` or `Contents/Helpers/x64/SofaTapHost`, according to its compiled architecture. The signed parent resolves Application Support and Caches through Foundation, checks that both are inside its own sandbox container, passes an explicit private `--data-dir`, and replaces any inherited `DOTNET_BUNDLE_EXTRACT_BASE_DIR` with its container cache. Missing sandbox containment fails closed; it does not read or migrate the website receiver's pairing profile.

The store permission button uses `CGPreflightPostEventAccess` and, if access is not already granted, `CGRequestPostEventAccess`. It never compiles a call to `AXIsProcessTrustedWithOptions`. The helper's periodic event-access status remains authoritative for the visible ready state. Requests still require an explicit click and remain disabled for dry-run; no prompt is issued at startup or during Refresh.

For startup, the store build presents a first-run checkbox preselected to enable launch at login, followed by a **确认设置** button. The selection alone does not register a login item: the explicit confirmation applies the user's choice. Declining it persists, existing system registration choices are respected, and failures do not cause automatic retries. The website build retains its existing one-time default registration.

The same injected login-item tests run with and without the store define. Container checks use only temporary fixture paths and cover outside-container and symlink escapes:

```sh
xcrun swiftc -parse-as-library -swift-version 6 -D SOFATAP_MAC_APP_STORE \
  -target arm64-apple-macosx15.0 desktop/macos/ReceiverLoginItem.swift \
  desktop/macos/tests/ReceiverLoginItemTests.swift -o /tmp/Sofatap-StoreLoginTests
/tmp/Sofatap-StoreLoginTests
xcrun swiftc -parse-as-library -swift-version 6 -target arm64-apple-macosx15.0 \
  desktop/macos/ReceiverStoreEnvironment.swift \
  desktop/macos/tests/ReceiverStoreEnvironmentTests.swift -o /tmp/Sofatap-StoreEnvironmentTests
/tmp/Sofatap-StoreEnvironmentTests
```

Add `-D SOFATAP_MAC_APP_STORE` to the offscreen appearance-fixture command to inspect the store capability note and first-run startup confirmation. These fixtures cannot replace real Mac App Store screenshots or physical input acceptance.

## Mac control center

The menu bar remains visible while the pairing window is hidden. Pause sends the existing private quit command and is only reported as paused after the owned helper exits. This releases owned inputs and closes the listener. Resume starts a fresh helper using the same existing credential profile; reconnect the phone if necessary. Pause and Quit cancel pending recovery, including an in-progress restart; their completion waits for the same owned child to exit. A stale or failed state pipe sends the existing graceful quit command, then terminates only that child if needed. An unconfirmed stop keeps the child reference and shows a warning; no second helper is launched.

Application profiles use NSWorkspace's frontmost application notification. Edit the last external foreground application or the default profile. Settings persist locally in the receiver's UserDefaults only, are limited to 128 bundle identifiers, and constrain pointer/scroll multipliers to 0.25–4. They affect only MacInput's received movements and scrolls; physical input, global settings, phone commands and credentials are unchanged. Unknown applications use the default. Application switching and private-pipe delivery are asynchronous, so an input racing a foreground change may use the preceding profile.

The private pipe additionally accepts exactly {"type":"profile","pointerScale":1,"scrollScale":1,"reverseScroll":false}. This is not a phone command. Native states may include diagnostics with actionCount, lastProcessingMs and maxProcessingMs. These measure receiver action execution only, not network/phone/display/application response or end-to-end latency. Counts include valid ping/retry/error executions and reset when the helper restarts. Dry-run has no real-input timings.

Diagnostics export is an explicit local Save action. It uses an allowlist and excludes host names, IPs, pairing secrets/URIs/QR, application identifiers, typed text and raw errors. A missing permission or connection is shown independently; network/firewall suggestions are not diagnoses. No automatic permission requests are added.

Additional pure model checks (no UI, helper, network or event injection):

```sh
xcrun swiftc -parse-as-library -swift-version 6 desktop/macos/ReceiverControlModels.swift desktop/macos/tests/ReceiverControlModelsTests.swift -o /tmp/Sofatap-ControlTests
/tmp/Sofatap-ControlTests
dotnet run --project tests/host/SofaTap.Host.Tests.csproj
```

Manual acceptance remains necessary with the installed signed app: hold/release a remote drag while pausing, confirm the listener stops, resume with the existing phone pairing, revoke permission, close/reopen the window, switch between two foreground applications and verify physical mouse settings remain unchanged. Do not perform live input tests on a shared desktop without isolated targets. CI compilation and fake-sink checks do not establish physical input or signing/notarization acceptance.


## Development permission guidance and receiver recovery

The connection/permission panel and menu bar offer **Restart receiver**. This disconnects the phone, uses the existing quit protocol, and waits for verified helper exit before launching a replacement. Repeated clicks are disabled during stop/start. The latest active Mac input profile is sent to the replacement; phone input is never buffered or replayed by the UI.

Unexpected exit or pipe failure can trigger at most three automatic attempts (2, 4, then 6 seconds), only if the receiver previously reported a valid state and the user has not paused or quit. A new helper's first status does not refill this budget. Explicit Start/Resume or Restart resets it. Permission-blocked and locked-desktop states are valid transport states, not reasons to restart or claim permission is ready. Startup failure before any valid state requires an explicit retry.

Sleep cancels pending watchdog/retry/stop timers. Wake starts fresh timers (15 seconds for the initial state watchdog), continues any already-requested stop, or resumes eligible recovery. Suspended time is not counted by these timers. Sleep/wake never overrides Pause or Quit. Network address/identity changes can still require reconnecting or rescanning the pairing QR; authentication and certificate pinning are unchanged.

For a Development build whose Accessibility entry is enabled but ineffective after app replacement/re-signing, the UI explains how the user can remove the stale entry, add the actual installed app again, and quit/relaunch. This is guidance only: the app does not reset TCC, change macOS permissions, or override helper-reported readiness.

Pure recovery policy checks:

```sh
swiftc -parse-as-library -swift-version 6 desktop/macos/ReceiverRecoveryPolicy.swift desktop/macos/tests/ReceiverRecoveryPolicyTests.swift -o /tmp/Sofatap-RecoveryTests
/tmp/Sofatap-RecoveryTests
```

Manual acceptance with the installed app still needs: repeated Restart clicks; Pause/Quit during restart; a helper that ignores graceful quit and termination (no replacement may launch); three crash/recovery attempts; sleep during each retry/stop stage; wake while paused; and restored permission on the actual installed Development app. Run with dry-run input where possible. Cloud policy checks do not establish physical Mac input, sleep delivery, or TCC behavior.
