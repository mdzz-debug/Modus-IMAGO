import Combine
import FormaUI
import Foundation

@MainActor
final class ApplicationPreferences: ObservableObject {
    static let shared = ApplicationPreferences()

    let behavior = FormaApplicationBehaviorCenter()
    let soundCenter: SoundCenter

    @Published private(set) var showsMenuBar: Bool

    private let menuBarVisibilityKey = "MImago.showsMenuBar"
    private let soundSetKey = "MImago.soundSet"
    private var cancellables: Set<AnyCancellable> = []

    private init(defaults: UserDefaults = .standard) {
        let storedSoundSet = UISoundSet(
            rawValue: defaults.object(forKey: soundSetKey) as? Int ?? UISoundSet.classic.rawValue
        ) ?? .classic
        soundCenter = SoundCenter(defaultSoundSet: storedSoundSet)

        if defaults.object(forKey: menuBarVisibilityKey) == nil {
            showsMenuBar = true
        } else {
            showsMenuBar = defaults.bool(forKey: menuBarVisibilityKey)
        }

        soundCenter.$selectedSet
            .dropFirst()
            .sink { selectedSet in
                defaults.set(selectedSet.rawValue, forKey: "MImago.soundSet")
            }
            .store(in: &cancellables)
    }

    func setMenuBarVisible(_ isVisible: Bool) {
        showsMenuBar = isVisible
        UserDefaults.standard.set(isVisible, forKey: menuBarVisibilityKey)
        AppDelegate.shared?.setMenuBarVisible(isVisible)
    }
}
