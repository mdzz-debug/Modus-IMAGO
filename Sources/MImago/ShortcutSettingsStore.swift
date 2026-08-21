import FormaUI
import Foundation
import SwiftUI

@MainActor
final class ShortcutSettingsStore: ObservableObject {
    static let shared = ShortcutSettingsStore()

    @Published private(set) var regionCapture: FormaGlobalShortcut?
    @Published private(set) var fullScreenCapture: FormaGlobalShortcut?
    @Published private(set) var regionRecording: FormaGlobalShortcut?
    @Published private(set) var stopRecording: FormaGlobalShortcut?
    @Published private(set) var validationMessage: String?

    private let center = FormaGlobalShortcutCenter()
    private let defaults = UserDefaults.standard

    private enum ShortcutID: String, CaseIterable {
        case regionCapture = "shortcut.region-capture"
        case fullScreenCapture = "shortcut.full-screen-capture"
        case regionRecording = "shortcut.region-recording"
        case stopRecording = "shortcut.stop-recording"
    }

    private init() {
        regionCapture = Self.load(
            .regionCapture,
            fallback: FormaGlobalShortcut(keyCode: 18, modifiers: [.control, .shift], key: "1")
        )
        fullScreenCapture = Self.load(
            .fullScreenCapture,
            fallback: FormaGlobalShortcut(keyCode: 19, modifiers: [.control, .option], key: "2")
        )
        regionRecording = Self.load(
            .regionRecording,
            fallback: FormaGlobalShortcut(keyCode: 21, modifiers: [.control, .shift], key: "4")
        )
        stopRecording = Self.load(
            .stopRecording,
            fallback: FormaGlobalShortcut(keyCode: 29, modifiers: [.control, .shift], key: "0")
        )
        registerAll()
    }

    func binding(for id: String) -> Binding<FormaGlobalShortcut?> {
        guard let shortcutID = ShortcutID(rawValue: id) else {
            return .constant(nil)
        }
        return Binding(
            get: { [weak self] in self?.shortcut(for: shortcutID) },
            set: { [weak self] in self?.update($0, for: shortcutID) }
        )
    }

    private func registerAll() {
        for id in ShortcutID.allCases {
            guard let shortcut = shortcut(for: id) else { continue }
            do {
                try center.register(shortcut, id: id.rawValue, action: action(for: id))
            } catch {
                validationMessage = error.localizedDescription
            }
        }
    }

    private func update(_ shortcut: FormaGlobalShortcut?, for id: ShortcutID) {
        let previous = self.shortcut(for: id)
        center.unregister(id.rawValue)

        guard let shortcut else {
            setShortcut(nil, for: id)
            persist(nil, for: id)
            validationMessage = nil
            return
        }

        do {
            try center.register(shortcut, id: id.rawValue, action: action(for: id))
            setShortcut(shortcut, for: id)
            persist(shortcut, for: id)
            validationMessage = nil
        } catch {
            if let previous {
                try? center.register(previous, id: id.rawValue, action: action(for: id))
            }
            validationMessage = error.localizedDescription
        }
    }

    private func action(for id: ShortcutID) -> () -> Void {
        switch id {
        case .regionCapture:
            { CaptureController.shared.requestFreeScreenshot() }
        case .fullScreenCapture:
            {
                MImagoPermissions.shared.performWithScreenCapturePermission {
                    CaptureController.shared.takeScreenshot()
                }
            }
        case .regionRecording:
            { CaptureController.shared.toggleRecording() }
        case .stopRecording:
            { CaptureController.shared.stopRecording() }
        }
    }

    private func shortcut(for id: ShortcutID) -> FormaGlobalShortcut? {
        switch id {
        case .regionCapture: regionCapture
        case .fullScreenCapture: fullScreenCapture
        case .regionRecording: regionRecording
        case .stopRecording: stopRecording
        }
    }

    private func setShortcut(_ shortcut: FormaGlobalShortcut?, for id: ShortcutID) {
        switch id {
        case .regionCapture: regionCapture = shortcut
        case .fullScreenCapture: fullScreenCapture = shortcut
        case .regionRecording: regionRecording = shortcut
        case .stopRecording: stopRecording = shortcut
        }
    }

    private static func load(
        _ id: ShortcutID,
        fallback: FormaGlobalShortcut
    ) -> FormaGlobalShortcut? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: id.rawValue) != nil else { return fallback }
        guard let data = defaults.data(forKey: id.rawValue) else { return nil }
        return try? JSONDecoder().decode(FormaGlobalShortcut.self, from: data)
    }

    private func persist(_ shortcut: FormaGlobalShortcut?, for id: ShortcutID) {
        guard let shortcut else {
            defaults.set(Data(), forKey: id.rawValue)
            return
        }
        defaults.set(try? JSONEncoder().encode(shortcut), forKey: id.rawValue)
    }
}
