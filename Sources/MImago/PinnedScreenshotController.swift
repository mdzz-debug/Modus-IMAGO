import AppKit
import FormaUI
import QuartzCore
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
    private var zoomDisplayLink: CADisplayLink?
    private var needsZoomFrame = false
    private var isApplyingZoomFrame = false
    private var zoomInteractionEndTimer: Timer?
    private weak var pinnedContentView: PinnedScreenshotContentView?

    func configureZoom(
        baseContentSize: CGSize,
        minimumZoom: CGFloat,
        maximumZoom: CGFloat = 4,
        contentView: PinnedScreenshotContentView
    ) {
        self.baseContentSize = baseContentSize
        self.minimumZoom = minimumZoom
        self.maximumZoom = maximumZoom
        logicalZoom = 1
        lockedZoomCenter = CGPoint(x: frame.midX, y: frame.midY)
        lastScrollTimestamp = 0
        needsZoomFrame = false
        isApplyingZoomFrame = false
        pinnedContentView = contentView
        delegate = self

        zoomDisplayLink?.invalidate()
        let displayLink = displayLink(target: self, selector: #selector(renderZoomFrame(_:)))
        displayLink.add(to: .main, forMode: .common)
        displayLink.isPaused = true
        zoomDisplayLink = displayLink
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
            let frameZoom = min(maximumZoom, max(minimumZoom, frame.width / baseContentSize.width))
            logicalZoom = frameZoom
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
            pinnedContentView?.showZoomPercentage(Int((currentZoom * 100).rounded()))
            scheduleZoomInteractionEnd()
            return
        }

        logicalZoom = nextZoom
        pinnedContentView?.setZoomInteractionActive(true)
        pinnedContentView?.showZoomPercentage(Int((nextZoom * 100).rounded()))
        scheduleZoomUpdate()
        scheduleZoomInteractionEnd()
    }

    private func scheduleZoomUpdate() {
        needsZoomFrame = true
        if let displayLink = zoomDisplayLink {
            displayLink.isPaused = false
        } else {
            applyZoom(logicalZoom)
            needsZoomFrame = false
        }
    }

    @objc private func renderZoomFrame(_ displayLink: CADisplayLink) {
        guard needsZoomFrame else {
            displayLink.isPaused = true
            return
        }
        needsZoomFrame = false
        // Trackpads already deliver a smooth stream of precise deltas. Apply
        // only the newest target once per display refresh instead of creating
        // a second interpolation loop that keeps resizing the WindowServer
        // surface after the gesture has moved on.
        applyZoom(logicalZoom)
        displayLink.isPaused = true
    }

    private func applyZoom(_ zoom: CGFloat) {
        guard baseContentSize.width > 0,
              baseContentSize.height > 0 else { return }

        let currentFrame = frame
        let center = lockedZoomCenter ?? CGPoint(
            x: currentFrame.midX,
            y: currentFrame.midY
        )
        let nextSize = CGSize(
            width: baseContentSize.width * zoom,
            height: baseContentSize.height * zoom
        )
        let nextFrame = pixelAlignedFrame(center: center, size: nextSize)
        guard nextFrame != currentFrame else { return }

        isApplyingZoomFrame = true
        // The image is layer-backed, so synchronously redrawing the complete
        // window for every scroll sample only adds main-thread work. AppKit
        // can commit the new geometry with the next compositor transaction.
        setFrame(nextFrame, display: false, animate: false)
        isApplyingZoomFrame = false
    }

    private func scheduleZoomInteractionEnd() {
        if let timer = zoomInteractionEndTimer, timer.isValid {
            timer.fireDate = Date(timeIntervalSinceNow: 0.14)
            return
        }
        let timer = Timer(timeInterval: 0.14, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.needsZoomFrame {
                    self.needsZoomFrame = false
                    self.applyZoom(self.logicalZoom)
                }
                self.pinnedContentView?.setZoomInteractionActive(false)
                self.zoomInteractionEndTimer = nil
            }
        }
        zoomInteractionEndTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func pixelAlignedFrame(center: CGPoint, size: CGSize) -> CGRect {
        let scale = max(1, backingScaleFactor)
        let alignedCenter = CGPoint(
            x: (center.x * scale).rounded() / scale,
            y: (center.y * scale).rounded() / scale
        )
        func evenPixelLength(_ value: CGFloat) -> CGFloat {
            let pixels = max(2, Int((value * scale).rounded()))
            let evenPixels = pixels.isMultiple(of: 2) ? pixels : pixels + 1
            return CGFloat(evenPixels) / scale
        }
        let alignedSize = CGSize(
            width: evenPixelLength(size.width),
            height: evenPixelLength(size.height)
        )
        return CGRect(
            x: alignedCenter.x - alignedSize.width / 2,
            y: alignedCenter.y - alignedSize.height / 2,
            width: alignedSize.width,
            height: alignedSize.height
        )
    }

    func windowDidMove(_ notification: Notification) {
        guard !isApplyingZoomFrame else { return }
        lockedZoomCenter = CGPoint(x: frame.midX, y: frame.midY)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        let resolvedZoom = min(
            maximumZoom,
            max(minimumZoom, frame.width / max(1, baseContentSize.width))
        )
        logicalZoom = resolvedZoom
        lockedZoomCenter = CGPoint(x: frame.midX, y: frame.midY)
    }

    override func close() {
        zoomInteractionEndTimer?.invalidate()
        zoomInteractionEndTimer = nil
        zoomDisplayLink?.invalidate()
        zoomDisplayLink = nil
        super.close()
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
        panel.title = "M · Imago 置顶截图"
        panel.isExcludedFromWindowsMenu = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.preservesContentDuringLiveResize = true
        panel.contentMinSize = minimumSize
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        let contentView = PinnedScreenshotContentView(
            image: image,
            size: fitted
        ) { [weak self] in
            self?.dismiss(id: id)
        }
        panel.contentView = contentView
        panel.setContentSize(fitted)
        let minimumZoom = max(
            0.25,
            minimumSize.width / max(1, fitted.width),
            minimumSize.height / max(1, fitted.height)
        )
        panel.configureZoom(
            baseContentSize: fitted,
            minimumZoom: minimumZoom,
            contentView: contentView
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

private final class PinnedScreenshotContentView: NSView {
    private static let controlsSize = CGSize(width: 220, height: 74)

    private let backgroundLayer = CALayer()
    private let imageLayer = CALayer()
    private let borderLayer = CALayer()
    private let zoomBadgeLayer = CALayer()
    private let zoomTextLayer = CATextLayer()
    private let hostingView: NSHostingView<AnyView>
    private var zoomBadgeHideTimer: Timer?

    init(
        image: CGImage,
        size: CGSize,
        onClose: @escaping () -> Void
    ) {
        hostingView = NSHostingView(rootView: AnyView(EmptyView()))
        super.init(frame: CGRect(origin: .zero, size: size))

        wantsLayer = true
        setAccessibilityLabel("置顶截图")
        layer?.masksToBounds = true
        layer?.cornerRadius = 12
        layer?.drawsAsynchronously = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        backgroundLayer.backgroundColor = NSColor.black.cgColor
        imageLayer.contents = image
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.minificationFilter = .linear
        imageLayer.magnificationFilter = .linear
        imageLayer.drawsAsynchronously = true
        borderLayer.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        borderLayer.borderWidth = 1
        borderLayer.cornerRadius = 12
        zoomBadgeLayer.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        zoomBadgeLayer.cornerRadius = 15
        zoomBadgeLayer.opacity = 0
        zoomTextLayer.alignmentMode = .center
        zoomTextLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2

        layer?.addSublayer(backgroundLayer)
        layer?.addSublayer(imageLayer)
        layer?.addSublayer(borderLayer)
        layer?.addSublayer(zoomBadgeLayer)
        zoomBadgeLayer.addSublayer(zoomTextLayer)

        hostingView.rootView = AnyView(
            FormaUIRoot(soundCenter: ApplicationPreferences.shared.soundCenter) {
                PinnedScreenshotControlsView(
                    onOpacityChange: { [weak self] opacity in
                        self?.setImageOpacity(opacity)
                    },
                    onClose: onClose
                )
            }
        )
        hostingView.frame = CGRect(
            x: max(0, size.width - Self.controlsSize.width),
            y: max(0, size.height - Self.controlsSize.height),
            width: Self.controlsSize.width,
            height: Self.controlsSize.height
        )
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        addSubview(hostingView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundLayer.frame = bounds
        imageLayer.frame = bounds
        borderLayer.frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        zoomBadgeLayer.frame = CGRect(
            x: bounds.midX - 36,
            y: bounds.midY - 15,
            width: 72,
            height: 30
        )
        zoomTextLayer.frame = CGRect(x: 0, y: 6, width: 72, height: 18)
        hostingView.frame.origin = CGPoint(
            x: max(0, bounds.width - Self.controlsSize.width),
            y: max(0, bounds.height - Self.controlsSize.height)
        )
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        imageLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        zoomTextLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    func setZoomInteractionActive(_ isActive: Bool) {
        hostingView.layer?.shouldRasterize = isActive
        hostingView.layer?.rasterizationScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
    }

    func showZoomPercentage(_ percentage: Int) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        zoomTextLayer.string = NSAttributedString(
            string: "\(percentage)%",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .bold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph
            ]
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        zoomBadgeLayer.opacity = 1
        CATransaction.commit()

        if let timer = zoomBadgeHideTimer, timer.isValid {
            timer.fireDate = Date(timeIntervalSinceNow: 0.85)
            return
        }
        let timer = Timer(timeInterval: 0.85, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.12)
                self.zoomBadgeLayer.opacity = 0
                CATransaction.commit()
                self.zoomBadgeHideTimer = nil
            }
        }
        zoomBadgeHideTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func setImageOpacity(_ opacity: Double) {
        let resolved = Float(min(1, max(0.15, opacity)))
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        backgroundLayer.opacity = resolved
        imageLayer.opacity = resolved
        borderLayer.opacity = resolved
        CATransaction.commit()
    }

}

private struct PinnedScreenshotControlsView: View {
    let onOpacityChange: (Double) -> Void
    let onClose: () -> Void
    @State private var screenshotOpacity = 1.0

    var body: some View {
        ZStack {
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
                    .accessibilityLabel("关闭置顶截图")
                    .delayedFormaHelp(
                        "关闭置顶截图",
                        detail: "关闭当前这张置顶图片",
                        placement: .below
                    )
                }
                .padding(8)
                Spacer()
            }
        }
        .background(Color.clear)
        .onAppear { onOpacityChange(screenshotOpacity) }
        .onChange(of: screenshotOpacity) { _, opacity in
            onOpacityChange(opacity)
        }
    }

    private var opacityControl: some View {
        FormaFloatingCard(padding: 8) {
            FormaSlider(
                "透明度",
                value: $screenshotOpacity,
                range: 0.15...1,
                step: 0.05,
                formatter: { "\(Int(($0 * 100).rounded()))%" }
            )
            .frame(width: 142)
        }
        .frame(width: 158, height: 58)
        .delayedFormaHelp(
            "透明度",
            detail: "拖动滑条调整截图透明度，控制按钮保持清晰",
            placement: .below
        )
    }
}
