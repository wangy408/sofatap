import AppKit
#if SOFATAP_MAC_APP_STORE
import CoreGraphics
#else
@preconcurrency import ApplicationServices
#endif
import Combine
import Darwin
import Foundation

/// All UI state lives on the main actor. Pipe readers and the writer run independently of AppKit.
@MainActor
final class ReceiverController: ObservableObject {
    @Published private(set) var state: ReceiverState?
    @Published var selectedHost: String?
    @Published private(set) var failure: String?
    @Published private(set) var isStarting = true
    @Published private(set) var isStopping = false
    @Published private(set) var copied = false
    @Published private(set) var accessRequested = false
    @Published private(set) var accessNotice: String?

    @Published private(set) var isPaused = false
    @Published private(set) var isPausing = false
    @Published private(set) var exportNotice: String?
    let profiles = ReceiverProfiles()
    private var profileSubscription: AnyCancellable?

    init() {
        profileSubscription = profiles.$activeProfile.sink { [weak self] profile in
            self?.sendData(profile.command)
        }
    }

    var controlStatus: String {
        if isPausing { return "pausing" }
        if isPaused { return "paused" }
        if isStopping { return "stopping" }
        if isStarting { return "starting" }
        return state == nil ? "unavailable" : "running"
    }

    var statusLabel: String {
        if isPausing { return "正在暂停…" }
        if isPaused { return "已暂停 · 不接收输入" }
        if isStopping { return "正在停止…" }
        if isStarting { return "正在启动…" }
        guard let state else { return "接收组件不可用" }
        if state.dryRun { return "测试模式 · 不注入输入" }
        if state.inputStatus != "ready" { return "需要检查输入权限" }
        return state.connected ? "手机已连接" : "等待手机连接"
    }

    func togglePause() {
        guard !isStarting, !isStopping, !isPausing else { return }
        if isPaused { isPaused = false; start(); return }
        isPausing = true
        stop { [weak self] stopped in
            self?.isPausing = false
            self?.isPaused = stopped
        }
    }

    func exportDiagnostics() {
        let timing = state?.diagnostics
        do {
            let data = try ReceiverDiagnosticExport.data(status: controlStatus, inputStatus: state?.inputStatus,
                connected: state?.connected ?? false, dryRun: state?.dryRun ?? false,
                interfaceCount: state?.pairings.count ?? 0, processingCount: timing?.actionCount,
                lastMilliseconds: timing?.lastProcessingMs, maximumMilliseconds: timing?.maxProcessingMs)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Sofatap-diagnostics.json"
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            exportNotice = "已导出脱敏诊断。"
        } catch { exportNotice = "无法保存诊断，请选择可写入的位置。" }
    }

    private var process: Process?
    private var generation = UUID()
    private var pipes: [Pipe] = []
    private var pipeReaders: [ReceiverPipeReader] = []
    private var stateReader: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private var commandStream: AsyncStream<Data>.Continuation?
    private var watchdog: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var copyTask: Task<Void, Never>?
    private var stopCompletion: ((Bool) -> Void)?

    var selectedPairing: ReceiverPairing? {
        state?.pairings.first { $0.host == selectedHost }
    }

    func start() {
        guard process == nil, !isStopping else { return }
        let id = UUID()
        generation = id
        state = nil
        selectedHost = nil
        failure = nil
        isStarting = true
        copied = false
        accessRequested = false
        accessNotice = nil
        #if SOFATAP_MAC_APP_STORE
        #if arch(arm64)
        let helperPath = "Contents/Helpers/arm64/SofaTapHost"
        #elseif arch(x86_64)
        let helperPath = "Contents/Helpers/x64/SofaTapHost"
        #else
        #error("Unsupported Mac App Store helper architecture")
        #endif
        #else
        let helperPath = "Contents/Helpers/SofaTapHost"
        #endif
        let helper = Bundle.main.bundleURL.appendingPathComponent(helperPath)
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            fail("找不到 Mac 接收组件。请重新安装 Sofatap。")
            return
        }

        let child = Process()
        let input = Pipe(), output = Pipe(), errors = Pipe()
        child.executableURL = helper
        child.arguments = ["--native-ui"] + (CommandLine.arguments.contains("--dry-run") ? ["--dry-run"] : [])
        #if SOFATAP_MAC_APP_STORE
        do {
            let directories = try ReceiverStoreDirectories.production()
            child.arguments?.append(contentsOf: ["--data-dir", directories.data.path])
            child.environment = directories.helperEnvironment(inherited: ProcessInfo.processInfo.environment)
        } catch {
            fail("无法打开 Sofatap 的应用存储空间。请确认正在使用完整的 Mac App Store 应用。")
            return
        }
        #endif
        child.standardInput = input
        child.standardOutput = output
        child.standardError = errors
        // Writing after a child exit must throw EPIPE instead of terminating the UI with SIGPIPE.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            fail("无法建立接收组件连接。请退出后重新打开 Sofatap。")
            return
        }
        child.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.didExit(id: id) }
        }
        process = child
        pipes = [input, output, errors]
        do {
            try child.run()
        } catch {
            cleanUp()
            fail("无法启动 Mac 接收组件。请确认安装完整，并检查是否已打开另一个 Sofatap。")
            return
        }
        // Only the child owns these ends after launch; close our copies so EOF is observable.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()

        let (commands, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(16))
        commandStream = continuation
        let stdin = input.fileHandleForWriting
        writer = Task.detached { [weak self] in
            do {
                for await command in commands {
                    if Task.isCancelled { return }
                    try stdin.write(contentsOf: command)
                }
            } catch {
                await self?.pipeFailed(id: id)
            }
        }
        do {
            let stdout = try ReceiverPipeReader(handle: output.fileHandleForReading, parsesStates: true)
            let stderr = try ReceiverPipeReader(handle: errors.fileHandleForReading, parsesStates: false)
            pipeReaders = [stdout, stderr]
            stateReader = Task { [weak self] in
                for await event in stdout.events {
                    guard !Task.isCancelled else { return }
                    switch event {
                    case .state(let update): self?.receive(update, id: id)
                    case .ended: self?.pipeFailed(id: id)
                    }
                }
            }
        } catch {
            pipeFailed(id: id)
            return
        }
        sendData(profiles.activeProfile.command)
        scheduleWatchdog(id: id)
    }

    func refresh() {
        guard !isPaused, !isPausing else { return }
        if process == nil { start() } else { send(.refresh) }
    }

    func requestAccess() {
        guard state?.inputStatus == "accessibility_required", state?.dryRun == false, !isStopping else { return }
        // Ask from the user-visible, signed .app, so macOS can identify Sofatap rather
        // than only its helper. Apple documents this prompt as asynchronous: the
        // return value is current trust, not the user's response or helper readiness.
        #if SOFATAP_MAC_APP_STORE
        // App Sandbox cannot use AXUIElement. Basic control asks only for event
        // posting access from an explicit native button click. A granted parent
        // preflight does not prove that the bundled helper can inject events.
        if !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
        #else
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        #endif
        accessRequested = true
        accessNotice = "请在系统提示中打开设置，并允许 Sofatap Receiver。若没有出现提示，可点“打开系统设置”；列表中没有应用时，点 + 选择已安装的 Sofatap Receiver.app。"
        // Leave the asynchronous system prompt in front. Do not concurrently ask
        // the helper to open Settings. Its periodic permission preflight remains the
        // authority for whether real input is available.
        send(.refresh)
    }

    func openAccessibilitySettings() {
        guard state?.inputStatus == "accessibility_required", state?.dryRun == false, !isStopping else { return }
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        if !NSWorkspace.shared.open(url) {
            accessNotice = "请手动打开系统设置 → 隐私与安全 → 辅助功能，允许 Sofatap Receiver，然后回到这里重新检查。"
        }
    }

    func copyPairing() {
        guard let pairing = selectedPairing, !isStopping else { return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(pairing.uri, forType: .string) else { return }
        copied = true
        copyTask?.cancel()
        copyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.copied = false
        }
    }

    /// Never terminate an unrelated process. If this child does not exit, keep the UI alive to retry.
    func stop(completion: @escaping (Bool) -> Void) {
        guard !isStopping else { return }
        guard let child = process, child.isRunning else { cleanUp(); completion(true); return }
        isStopping = true
        stopCompletion = completion
        state = nil
        selectedHost = nil
        watchdog?.cancel()
        send(.quit)
        stopTask = Task { [weak self, child] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self, self.isStopping else { return }
            if child.isRunning { child.terminate() }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, self.isStopping else { return }
            if child.isRunning {
                self.isStopping = false
                self.fail("接收组件尚未退出。请稍后再点“退出 Sofatap”。")
                let callback = self.stopCompletion
                self.stopCompletion = nil
                callback?(false)
            } else { self.didExit(id: self.generation) }
        }
    }

    private func send(_ command: ReceiverCommand) { sendData(command.line) }

    private func sendData(_ data: Data) {
        guard let commandStream else { return }
        if case .dropped = commandStream.yield(data) {
            pipeFailed(id: generation)
        }
    }

    private func receive(_ update: ReceiverState, id: UUID) {
        guard id == generation, process?.isRunning == true, !isStopping else { return }
        selectedHost = update.selectedHost(preserving: selectedHost)
        state = update
        failure = nil
        isStarting = false
        scheduleWatchdog(id: id)
    }

    private func scheduleWatchdog(id: UUID) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, self.generation == id, !self.isStopping else { return }
            self.pipeFailed(id: id)
        }
    }

    private func pipeFailed(id: UUID) {
        guard id == generation, process != nil, !isStopping else { return }
        fail("与 Mac 接收组件的连接已中断。请重新打开 Sofatap。")
        if process?.isRunning == true { process?.terminate() }
    }

    private func didExit(id: UUID) {
        guard id == generation, process != nil else { return }
        let wasStopping = isStopping
        let callback = stopCompletion
        stopCompletion = nil
        cleanUp()
        isStopping = false
        if wasStopping { callback?(true) }
        else { fail(failure ?? "Mac 接收组件已停止。请重新检查，或退出后再打开 Sofatap。") }
    }

    private func fail(_ message: String) {
        state = nil
        selectedHost = nil
        copied = false
        isStarting = false
        failure = message
    }

    private func cleanUp() {
        generation = UUID()
        watchdog?.cancel()
        stopTask?.cancel()
        copyTask?.cancel()
        commandStream?.finish()
        commandStream = nil
        writer?.cancel()
        writer = nil
        stateReader?.cancel()
        stateReader = nil
        pipeReaders.forEach { $0.cancel() }
        pipeReaders.removeAll()
        pipes.forEach {
            try? $0.fileHandleForReading.close()
            try? $0.fileHandleForWriting.close()
        }
        pipes.removeAll()
        process?.terminationHandler = nil
        process = nil
    }
}
