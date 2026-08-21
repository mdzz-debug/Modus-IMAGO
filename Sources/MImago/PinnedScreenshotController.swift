import AppKit
import FormaUI
import SwiftUI

private final class PinnedScreenshotPanel: NSPanel, NSWindowDelegate {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    private var baseContentSize: CGSize = .zero
    private var minimumZoom: CGFloat = 0.25
    private var maximumZoom: CGFloat = 4
    private var logicalZoom: CGFloat = 1
    private var lockedZoomCenter: CGPoint?
    private var lastScrollTimestamp: TimeInterval = 0
    private var zoomUpdateScheduled = false
    private var isApplyingZoomFrame = false
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
        logicalZoom = 1
        lockedZoomCenter = CGPoint(x: frame.midX, y: frame.midY)
        lastScrollTimestamp = 0
        zoomUpdateScheduled = false
        isApplyingZoomFrame = false
        zoomState = state
        delegate = self
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

        let isNewGesture = event.phase.contains(.began)
            || event.timestamp - lastScrollTimestamp > 0.18
        if isNewGesture {
            logicalZoom = min(
                maximumZoom,
                max(minimumZoom, frame.width / baseContentSize.width)
            )
            if lockedZoomCenter == nil {
                lockedZoomCenter = CGPoint(x: frame.midX, y: frame.midY)
            }
        }
        lastScrollTimestamp = event.timestamp

        let currentZoom = logicalZoom
        let factor: CGFloat
        if event.hasPreciseScrollingDeltas {
            let boundedDelta = min(16, max(-16, delta))
            factor = exp(boundedDelta * 0.006)
        } else {
            factor = pow(1.10, delta > 0 ? 1 : -1)
        }
        let nextZoom = min(maximumZoom, max(minimumZoom, currentZoom * factor))
        guard abs(nextZoom - currentZoom) > 0.0001 else {
            zoomState?.show(percentage: Int((currentZoom * 100).rounded()))
            return
        }

        logicalZoom = nextZoom
        scheduleZoomUpdate()
    }

    private func scheduleZoomUpdate() {
        guard !zoomUpdateScheduled else { return }
        zoomUpdateScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + (1 / 60)) { [weak self] in
            guard let self else { return }
            self.zoomUpdateScheduled = false
            self.applyLogicalZoom()
        }
    }

    private func applyLogicalZoom() {
        guard baseContentSize.width > 0,
              baseContentSize.height > 0 else { return }

        let currentFrame = frame
        let center = lockedZoomCenter ?? CGPoint(
            x: currentFrame.midX,
            y: currentFrame.midY
        )
        let nextSize = CGSize(
            width: baseContentSize.width * logicalZoom,
            height: baseContentSize.height * logicalZoom
        )
        let nextFrame = CGRect(
            x: center.x - nextSize.width / 2,
            y: center.y - nextSize.height / 2,
            width: nextSize.width,
            height: nextSize.height
        )

        isApplyingZoomFrame = true
        setFrame(nextFrame, display: true, animate: false)
        isApplyingZoomFrame = false
        zoomState?.show(percentage: Int((logicalZoom * 100).rounded()))
    }

    func windowDidMove(_ notification: Notification) {
        guard !isApplyingZoomFrame else { return }
        lockedZoomCenter = CGPoint(x: frame.midX, y: frame.midY)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        logicalZoom = min(
            maximumZoom,
            max(minimumZoom, frame.width / max(1, baseContentSize.width))
        )
        lockedZoomCenter = CGPoint(x: frame.midX, y: frame.midY)
    }
}

@MainActor
private final class PinnedScreenshotZoomState: ObservableObject {
    @Published private(set) var visiblePercentage: Int?
    private var hideTask: Task<Void, Never>?

    func show(percentage: Int) {
        hideTask?.cancel()
        if visiblePercentage != percentage {
            visiblePercentage = percentage
        }
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
    @State private var screenshotOpacity = 1.0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(FormaTheme.ink)
                .opacity(screenshotOpacity)

            Image(nsImage: NSImage(cgImage: image, size: .zero))
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(screenshotOpacity)

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
                HStack(spacing: 8) {
                    Spacer()
                    opacityControl
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
        .background(Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(FormaTheme.lineStrong.opacity(0.72 * screenshotOpacity), lineWidth: 1)
        }
    }

    private var opacityControl: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))

            Slider(value: $screenshotOpacity, in: 0.15...1, step: 0.05)
                .tint(FormaTheme.accent)
                .frame(minWidth: 42, idealWidth: 76, maxWidth: 92)
                .accessibilityLabel("置顶截图透明度")
                .accessibilityValue("\(Int((screenshotOpacity * 100).rounded()))%")

            Text("\(Int((screenshotOpacity * 100).rounded()))%")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 32, alignment: .trailing)
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(.black.opacity(0.72))
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.24), radius: 4, y: 2)
        .accessibilityElement(children: .contain)
    }
}
