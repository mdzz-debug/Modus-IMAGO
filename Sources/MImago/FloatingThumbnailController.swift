import AppKit

@MainActor
final class FloatingThumbnailController {
    static let shared = FloatingThumbnailController()
    static let windowIdentifier = NSUserInterfaceItemIdentifier("floating-thumbnail")

    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?

    func show(image: CGImage, duration: Double) {
        dismiss()
        guard duration > 0, let screen = NSScreen.main else { return }

        let imageSize = CGSize(width: image.width, height: image.height)
        let width: CGFloat = 220
        let height = max(110, min(150, width * imageSize.height / max(1, imageSize.width)))
        let frame = CGRect(
            x: screen.visibleFrame.maxX - width - 22,
            y: screen.visibleFrame.minY + 22,
            width: width,
            height: height
        )
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = Self.windowIdentifier
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]

        let container = NSVisualEffectView(frame: CGRect(origin: .zero, size: frame.size))
        container.material = .hudWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true

        let imageView = NSImageView(frame: container.bounds.insetBy(dx: 7, dy: 7))
        imageView.image = NSImage(cgImage: image, size: .zero)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(imageView)
        panel.contentView = container
        panel.orderFrontRegardless()
        self.panel = panel

        let dismissWorkItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.dismiss()
            }
        }
        self.dismissWorkItem = dismissWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: dismissWorkItem)
    }

    func dismiss() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }
}
