import AppKit
import Combine
import Foundation

@MainActor
final class ReceiverProfiles: ObservableObject {
    @Published private(set) var settings: ReceiverProfileSettings
    @Published private(set) var activeProfile = ReceiverInputProfile()
    @Published private(set) var frontmostBundleID: String?
    @Published private(set) var lastExternalBundleID: String?
    @Published var editingBundleID: String?
    private let defaults: UserDefaults
    private let key = "receiver.inputProfiles.v1"
    private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), data.count <= 128 * 1024,
           let decoded = try? JSONDecoder().decode(ReceiverProfileSettings.self, from: data) {
            settings = decoded.sanitized
        } else { settings = ReceiverProfileSettings() }
        updateFrontmost()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateFrontmost() }
        }
    }

    private func updateFrontmost() {
        let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        frontmostBundleID = id.flatMap { ReceiverProfileSettings.validID($0) ? $0 : nil }
        if let id = frontmostBundleID, id != Bundle.main.bundleIdentifier { lastExternalBundleID = id }
        apply()
    }
    private func apply() {
        activeProfile = settings.profile(for: frontmostBundleID)
    }
    var editingProfile: ReceiverInputProfile { settings.profile(for: editingBundleID) }
    var savedIDs: [String] { settings.applications.keys.sorted() }

    func editLastApplication() {
        guard let id = lastExternalBundleID else { return }
        editingBundleID = id
    }
    func update(_ profile: ReceiverInputProfile) {
        if let id = editingBundleID {
            guard ReceiverProfileSettings.validID(id),
                  settings.applications[id] != nil || settings.applications.count < ReceiverProfileSettings.maximumApplications else { return }
            settings.applications[id] = profile.bounded
        } else { settings.defaultProfile = profile.bounded }
        save()
    }
    func removeOverride() {
        guard let id = editingBundleID else { return }
        settings.applications.removeValue(forKey: id)
        editingBundleID = nil
        save()
    }
    private func save() {
        if let data = try? JSONEncoder().encode(settings.sanitized) { defaults.set(data, forKey: key) }
        apply()
    }
}
