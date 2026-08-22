import Combine
import Sparkle

@MainActor
final class UpdateController: NSObject, ObservableObject {
    static let shared = UpdateController()

    @Published private(set) var automaticallyChecksForUpdates = true

    private let updaterController: SPUStandardUpdaterController
    private var hasStarted = false

    private override init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        updaterController.startUpdater()
        automaticallyChecksForUpdates = updaterController.updater
            .automaticallyChecksForUpdates
        DiagnosticLogStore.shared.log(
            .info,
            category: "update",
            "sparkle-started automatic=\(automaticallyChecksForUpdates) "
                + "interval=\(Int(updaterController.updater.updateCheckInterval))"
        )
    }

    func checkForUpdates() {
        start()
        DiagnosticLogStore.shared.log(
            .info,
            category: "update",
            "manual-sparkle-update-check-requested"
        )
        updaterController.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ isEnabled: Bool) {
        start()
        updaterController.updater.automaticallyChecksForUpdates = isEnabled
        automaticallyChecksForUpdates = isEnabled
        DiagnosticLogStore.shared.log(
            .info,
            category: "update",
            "automatic-update-checks-changed enabled=\(isEnabled)"
        )
    }
}
