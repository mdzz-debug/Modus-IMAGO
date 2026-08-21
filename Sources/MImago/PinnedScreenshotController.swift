import AppKit
import FormaUI
import SwiftUI

private final class PinnedScreenshotPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private var baseContentSize: CGSize = .zero
    private var minimumZoom: CGFloat = 0.25
    private var maximumZoom: CGFloat = 4
    private weak var zoomState: PinnedScreenshotZoomState?

    func configureZoom(
        baseContentSize: CGSize,
        minimumZoom: CGFloat,
        maximumZoom: CGFloat = 4,
        state: PinnedScreenshotZoomState
    ) {
        self.baseContentSize = baseContentSize
        self.minimumZoom = minimumZoom
        self.maximumZoom = maximumZoom
        zoomState = state
    }

    override func scrollWheel(with event: NSEvent) {
        guard baseContentSize.width > 0,
              baseContentSize.height > 0 else {
            super.scrollWheel(with: event)
            return
        }

        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.001 else {
            super.scrollWheel(with: event)
            return
        }

        let currentZoom = frame.width / baseContentSize.width
        let factor: CGFloat
        if event.hasPreciseScrollingDeltas {
            factor = exp(delta * 0.008)
        } else {
            factor = pow(1.10, delta > 0 ? 1 : -1)
        }
        let nextZoom = min(maximumZoom, max(minimumZoom, currentZoom * factor))
        guard abs(nextZoom - currentZoom) > 0.0001 else {
            zoomState?.show(percentage: Int((currentZoom * 100).rounded()))
            return
        }

        let currentFrame = frame
        let pointer = CGPoint(
            x: min(currentFrame.width, max(0, event.locationInWindow.x)),
            y: min(currentFrame.height, max(0, event.locationInWindow.y))
        )
        let anchorX = pointer.x / max(1, currentFrame.width)
        let anchorY = pointer.y / max(1, currentFrame.height)
        let nextSize = CGSize(
            width: baseContentSize.width * nextZoom,
            height: baseContentSize.height * nextZoom
        )
        let anchorOnScreen = CGPoint(
            x: currentFrame.minX + pointer.x,
            y: currentFrame.minY + pointer.y
        )
        let nextFrame = CGRect(
            x: anchorOnScreen.x - nextSize.width * anchorX,
            y: anchorOnScreen.y - nextSize.height * anchorY,
            width: nextSize.width,
            height: nextSize.height
        )

        setFrame(nextFrame, display: true)
        zoomState?.show(percentage: Int((nextZoom * 100).rounded()))
    }
}

@MainActor
private final class PinnedScreenshotZoomState: ObservableObject {
    @Published private(set) var visiblePercentage: Int?
    private var hideTask: Task<Void, Never>?

    func show(percentage: Int) {
        hideTask?.cancel()
        visiblePercentage = percentage
        hideTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(850))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            visiblePercentage = nil
            hideTask = nil
        }
    }

    deinit {
        hideTask?.cancel()
    }
}

@MainActor
final class PinnedScreenshotController {
    static let shared = PinnedScreenshotController()
    static let windowIdentifierPrefix = "pinned-screenshot-"

    private var panels: [UUID: NSPanel] = [:]

    func show(image: CGImage) {
        guard let screen = NSScreen.main else { return }

        let id = UUID()
        let sourceSize = CGSize(width: image.width, height: image.height)
        let maximumSize = CGSize(
            width: min(720, screen.visibleFrame.width * 0.58),
            height: min(520, screen.visibleFrame.height * 0.58)
        )
        let aspectRatio = sourceSize.width / max(1, sourceSize.height)
        let minimumSize = aspectRatio >= 1
            ? CGSize(width: 180, height: 180 / aspectRatio)
            : CGSize(width: 180 * aspectRatio, height: 180)
        let fitted = fittedSize(sourceSize, maximum: maximumSize, minimum: minimumSize)
        let offset = CGFloat(panels.count % 6) * 18
        let frame = CGRect(
            x: screen.visibleFrame.midX - fitted.width / 2 + offset,
            y: screen.visibleFrame.midY - fitted.height / 2 - offset,
            width: fitted.width,
            height: fitted.height
        )

        let panel = PinnedScreenshotPanel(
            contentRect: frame,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifierPrefix + id.uuidString)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.contentMinSize = minimumSize
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        let zoomState = PinnedScreenshotZoomState()
        let hostingView = NSHostingView(
            rootView: FormaUIRoot(soundCenter: ApplicationPreferences.shared.soundCenter) {
                PinnedScreenshotView(image: image, zoomState: zoomState) { [weak self] in
                    self?.dismiss(id: id)
                }
            }
        )
        hostingView.frame = CGRect(origin: .zero, size: fitted)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        panel.setContentSize(fitted)
        panel.contentAspectRatio = sourceSize
        let minimumZoom = max(
            0.25,
            minimumSize.width / max(1, fitted.width),
            minimumSize.height / max(1, fitted.height)
        )
        panel.configureZoom(
            baseContentSize: fitted,
            minimumZoom: minimumZoom,
            state: zoomState
        )
        panels[id] = panel
        panel.orderFrontRegardless()
    }

    private func dismiss(id: UUID) {
        panels[id]?.orderOut(nil)
        panels[id]?.close()
        panels[id] = nil
    }

    private func fittedSize(_ source: CGSize, maximum: CGSize, minimum: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0 else { return minimum }
        let maximumScale = min(maximum.width / source.width, maximum.height / source.height, 1)
        var size = CGSize(width: source.width * maximumScale, height: source.height * maximumScale)
        let minimumScale = max(minimum.width / max(1, size.width), minimum.height / max(1, size.height), 1)
        size.width *= minimumScale
        size.height *= minimumScale
        return size
    }
}

private struct PinnedScreenshotView: View {
    let image: CGImage
    @ObservedObject var zoomState: PinnedScreenshotZoomState
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Image(nsImage: NSImage(cgImage: image, size: .zero))
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let percentage = zoomState.visiblePercentage {
                Text("\(percentage)%")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.72))
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.28), radius: 5, y: 2)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    .allowsHitTesting(false)
            }

            VStack {
                HStack {
                    Spacer()
                    FormaButton(
                        "",
                        systemImage: "xmark",
                        role: .dark,
                        size: .small,
                        depth: .raised,
                        action: onClose
                    )
                    .frame(width: 38)
                    .padding(8)
                    .accessibilityLabel("关闭置顶截图")
                    .formaTooltip("关闭置顶截图")
                }
                Spacer()
            }
        }
        .animation(.easeOut(duration: 0.14), value: zoomState.visiblePercentage)
        .background(FormaTheme.ink)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(FormaTheme.lineStrong.opacity(0.72), lineWidth: 1)
        }
    }
}
