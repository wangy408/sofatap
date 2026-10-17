import AppKit
import Combine
import SwiftUI

@MainActor
final class ReceiverStatusItem: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let receiver: ReceiverController
    private let open: () -> Void
    private var subscription: AnyCancellable?
    init(receiver: ReceiverController, open: @escaping () -> Void) {
        self.receiver = receiver
        self.open = open
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        subscription = receiver.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateIcon() }
        }
        updateIcon()
    }
    private func updateIcon() {
        let symbol = receiver.isPaused ? "pause.circle" : receiver.state?.connected == true ? "iphone.radiowaves.left.and.right" : "computermouse"
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Sofatap")
        item.button?.toolTip = "Sofatap · " + receiver.statusLabel
        item.button?.setAccessibilityLabel("Sofatap · " + receiver.statusLabel)
    }
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: receiver.statusLabel, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        add(menu, "打开配对与设置", #selector(showWindow))
        let pause = add(menu, receiver.isPaused ? "恢复接收" : "暂停接收", #selector(togglePause))
        pause.isEnabled = receiver.canTogglePause
        let restart = add(menu, "重启接收组件", #selector(restartReceiver))
        restart.isEnabled = !receiver.isStarting && !receiver.isPaused && !receiver.isPausing && !receiver.isStopping && !receiver.isRestarting && !receiver.isSleeping
        add(menu, "导出脱敏诊断…", #selector(export))
        menu.addItem(.separator())
        add(menu, "退出 Sofatap", #selector(quit))
    }
    @discardableResult private func add(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        menu.addItem(entry)
        return entry
    }
    @objc private func showWindow() { open() }
    @objc private func togglePause() { receiver.togglePause() }
    @objc private func restartReceiver() { receiver.restartReceiver() }
    @objc private func export() { open(); receiver.exportDiagnostics() }
    @objc private func quit() { NSApp.terminate(nil) }
}

struct ReceiverControlCenter: View {
    @ObservedObject var receiver: ReceiverController
    @ObservedObject var profiles: ReceiverProfiles

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(receiver.statusLabel).font(.headline)
            Button(receiver.isPaused ? "恢复接收" : "暂停接收", action: receiver.togglePause)
                .disabled(!receiver.canTogglePause)
            Text("暂停会断开手机并停止接收；恢复后请重新连接。网络地址或身份变化时，可能需要重新扫码。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            DisclosureGroup("连接与权限诊断") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("接收组件：" + receiver.controlStatus)
                    Text("输入权限：" + permissionLabel)
                    Text(receiver.state?.connected == true ? "手机：已连接" : "手机：未连接")
                    Text("可用配对地址数量：\(receiver.state?.pairings.count ?? 0)")
                    if let timing = receiver.state?.diagnostics {
                        Text("处理次数：\(timing.actionCount)")
                        Text(String(format: "最近处理 %.2f ms · 最大 %.2f ms", timing.lastProcessingMs, timing.maxProcessingMs))
                    }
                    Text("这里只测量接收端动作处理时间，不包含手机、网络、屏幕或目标应用响应；不是端到端延迟。")
                    Text("无法连接时，请检查两端是否在可互通的网络、Mac 防火墙是否允许 Sofatap，以及是否有其他接收组件占用端口。这里只提供检查建议，不推断具体原因。")
                    Button("重启接收组件", action: receiver.restartReceiver)
                        .disabled(receiver.isStarting || receiver.isPaused || receiver.isPausing || receiver.isStopping || receiver.isRestarting || receiver.isSleeping)
                    Text("重启前会先停止现有组件。无法确认停止时不会启动第二个组件，也不会更改系统权限。")
                    if let notice = receiver.recoveryNotice { Text(notice) }
                    Text("Development 版替换或重新签名后，若辅助功能已开启却仍提示无权限，请在系统设置中移除旧条目，用 + 重新添加实际安装的 Sofatap Receiver.app，再退出并重新打开。")
                    Button("导出脱敏诊断…", action: receiver.exportDiagnostics)
                    Text("不包含配对密钥、二维码、地址、应用标识、输入文字或原始错误。")
                    if let notice = receiver.exportNotice { Text(notice) }
                }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }
            Divider()
            DisclosureGroup("按 Mac 应用调整指针与滚动") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("编辑", selection: $profiles.editingBundleID) {
                        Text("默认配置").tag(String?.none)
                        ForEach(profiles.savedIDs, id: \.self) { id in Text(id).tag(Optional(id)) }
                        if let id = profiles.editingBundleID, !profiles.savedIDs.contains(id) {
                            Text(id).tag(Optional(id))
                        }
                    }
                    Button("编辑最近的前台应用", action: profiles.editLastApplication)
                        .disabled(profiles.lastExternalBundleID == nil)
                    Text(profiles.editingBundleID ?? "未单独配置的应用使用默认值")
                        .font(.caption).textSelection(.enabled)
                    scale("指针速度", keyPath: \.pointerScale)
                    scale("滚动速度", keyPath: \.scrollScale)
                    Toggle("反转 Sofatap 滚动", isOn: Binding(
                        get: { profiles.editingProfile.reverseScroll },
                        set: { value in var p = profiles.editingProfile; p.reverseScroll = value; profiles.update(p) }))
                    Button("重置为默认配置", action: profiles.removeOverride)
                        .disabled(profiles.editingBundleID == nil)
                    Text("先切换到要调整的应用，再返回这里编辑。只影响 Sofatap 发送的输入；不会改变系统鼠标、触控板或手机设置。配置按当前前台应用自动切换，无法识别时使用默认值。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }
        }
        .padding(20)
        .frame(maxWidth: 530, alignment: .leading)
    }
    private var permissionLabel: String {
        guard let state = receiver.state else { return "未检查" }
        switch state.inputStatus {
        case "ready": return "可提交输入"
        case "accessibility_required": return "需要辅助功能授权"
        case "desktop_unavailable": return "桌面不可用，请解锁后检查"
        default: return state.dryRun ? "测试模式" : "暂不可用，请重新检查"
        }
    }
    private func scale(_ label: String, keyPath: WritableKeyPath<ReceiverInputProfile, Double>) -> some View {
        VStack(alignment: .leading) {
            Text(String(format: "%@ %.2f×", label, profiles.editingProfile[keyPath: keyPath]))
            Slider(value: Binding(get: { profiles.editingProfile[keyPath: keyPath] },
                set: { value in var p = profiles.editingProfile; p[keyPath: keyPath] = value; profiles.update(p) }),
                in: 0.25...4, step: 0.05)
                .accessibilityLabel(label)
        }
    }
}
