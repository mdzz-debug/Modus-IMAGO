import AppKit
import CoreServices
import FormaUI
import SwiftUI

@main
struct MImagoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    private var menuBarItem: FormaMenuBarItemController?
    private var mainWindow: NSWindow?
    private var isCaptureOverlayActive = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        DiagnosticLogStore.shared.start()
        _ = ShortcutSettingsStore.shared
        let launchedAtLogin = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) != nil
        NSApp.setActivationPolicy(launchedAtLogin ? .accessory : .regular)
        if !launchedAtLogin {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.createMainWindow()
            }
        }
        let item = FormaMenuBarItemController(
            systemImage: "camera.viewfinder",
            accessibilityLabel: "M · Imago",
            toolTip: "M · Imago"
        )

        item.setPopover(contentSize: CGSize(width: 320, height: 300)) {
            FormaUIRoot(soundCenter: ApplicationPreferences.shared.soundCenter) {
                MenuBarPanel(openMainWindow: { [weak self] in self?.showMainWindow() })
            }
        }
        menuBarItem = item
        item.setVisible(ApplicationPreferences.shared.showsMenuBar)
    }

    private func createMainWindow() {
        let window = NSWindow(
            contentRect: CGRect(
                x: 0,
                y: 0,
                width: MainWindow.preset.width,
                height: MainWindow.preset.height
            ),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "M · Imago"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.styleMask.insert(.fullSizeContentView)
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.isReleasedWhenClosed = false
        window.contentMinSize = MainWindow.preset.size
        window.contentMaxSize = MainWindow.preset.size
        window.center()
        window.contentView = NSHostingView(rootView: FormaUIRoot(soundCenter: ApplicationPreferences.shared.soundCenter) {
            MainPanelView()
                .formaWindowConfiguration(
                    FormaWindowConfiguration(
                        preset: MainWindow.preset,
                        resizePolicy: .locked,
                        buttons: FormaWindowButtonConfiguration(
                            close: .enabled,
                            minimize: .enabled,
                            zoom: .hidden
                        )
                    )
                )
        })
        mainWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func setMenuBarVisible(_ isVisible: Bool) {
        menuBarItem?.setVisible(isVisible)
    }

    func setCaptureOverlayActive(_ isActive: Bool) {
        guard isCaptureOverlayActive != isActive else { return }
        isCaptureOverlayActive = isActive
        DiagnosticLogStore.shared.log(
            .debug,
            category: "capture-overlay",
            isActive ? "activated" : "deactivated"
        )
        if isActive {
            // The capture flow intentionally orders every ordinary app window
            // out before presenting a borderless nonactivating panel. Such a
            // panel does not count as a restorable app window, so SwiftUI/AppKit
            // may otherwise automatically terminate the process while the
            // user is still selecting or annotating a screenshot.
            ProcessInfo.processInfo.disableAutomaticTermination(
                "M · Imago capture overlay is active"
            )
        } else {
            ProcessInfo.processInfo.enableAutomaticTermination(
                "M · Imago capture overlay is active"
            )
        }
    }

    func applicationShouldSaveSecureApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldRestoreSecureApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, !isCaptureOverlayActive { showMainWindow() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // AppKit may request a normal termination after every ordinary window
        // has been hidden for capture, even while the borderless overlay panel
        // is still active. Treat that lifecycle request as transient; explicit
        // quit remains available as soon as the capture flow finishes/cancels.
        isCaptureOverlayActive ? .terminateCancel : .terminateNow
    }

    private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if mainWindow == nil {
            createMainWindow()
        }
        mainWindow?.makeKeyAndOrderFront(nil)
    }
}

private enum MainWindow {
    static let preset = FormaWindowPreset(
        id: "MImagoMain",
        width: 520,
        height: 840,
        minimumWidth: 520,
        minimumHeight: 840
    )
}

private extension FormaWindowPreset {
    var size: CGSize {
        CGSize(width: width, height: height)
    }
}
