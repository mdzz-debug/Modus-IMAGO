import AppKit
import ApplicationServices
import AVFoundation
import CoreText
import FormaUI
import Foundation
import ScreenCaptureKit
import Vision

@MainActor
final class MImagoPermissions {
    static let shared = MImagoPermissions()
    let center = FormaPermissionCenter()
    private var hasPromptedForAccessibilityThisLaunch = false

    func ensureAccessibilityAuthorization() async -> Bool {
        let axTrusted = AXIsProcessTrusted()
        let canPostEvents = CGPreflightPostEventAccess()
        if axTrusted || canPostEvents {
            _ = await center.refresh(.accessibility)
            DiagnosticLogStore.shared.log(
                .info,
                category: "permission",
                "accessibility-ready ax=\(axTrusted) post-events=\(canPostEvents)"
            )
            return true
        }

        let refreshed = await center.refresh(.accessibility)
        if refreshed == .authorized {
            DiagnosticLogStore.shared.log(
                .info,
                category: "permission",
                "accessibility-ready center=authorized ax=false post-events=false"
            )
            return true
        }

        guard !hasPromptedForAccessibilityThisLaunch else {
            DiagnosticLogStore.shared.log(
                .warning,
                category: "permission",
                "accessibility-still-unavailable prompt-suppressed status=\(String(describing: refreshed))"
            )
            return false
        }

        hasPromptedForAccessibilityThisLaunch = true
        let requested = await center.request(.accessibility)
        try? await Task.sleep(for: .milliseconds(180))
        let isReady = AXIsProcessTrusted()
            || CGPreflightPostEventAccess()
            || requested == .authorized
        DiagnosticLogStore.shared.log(
            isReady ? .info : .warning,
            category: "permission",
            "accessibility-request-result status=\(String(describing: requested)) ready=\(isReady)"
        )
        return isReady
    }

    func ensureMicrophoneAuthorization() async -> Bool {
        let current = await center.refresh(.microphone)
        guard current != .authorized else { return true }

        let requested = await center.request(.microphone)
        guard requested != .authorized else { return true }

        center.openSettings(for: .microphone)
        return false
    }

    func synchronizeRecordingPermission() async {
        let status = await center.refresh(.microphone)
        guard status != .authorized, RecordingPreferences.shared.capturesMicrophone else { return }
        RecordingPreferences.shared.capturesMicrophone = false
        CaptureController.shared.setStatusMessage("检测到麦克风权限已关闭，录屏麦克风已同步关闭。")
    }

    func performWithScreenCapturePermission(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) {
        if CGPreflightScreenCaptureAccess() {
            Task { @MainActor in
                await Task.yield()
                action()
            }
            Task { _ = await center.refresh(.screenRecording) }
            return
        }

        Task {
            guard Bundle.main.bundleURL.pathExtension == "app" else {
                CaptureController.shared.setStatusMessage(
                    "当前由 swift run 启动，无法使用已授予 M · Imago.app 的屏幕录制权限。请运行 zsh scripts/package-app.sh。"
                )
                return
            }

            do {
                _ = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
                _ = await center.refresh(.screenRecording)
                action()
                return
            } catch {
                let status = await center.refresh(.screenRecording)
                if status == .notDetermined,
                   await center.request(.screenRecording) == .authorized {
                    action()
                    return
                }
                CaptureController.shared.setStatusMessage(
                    "系统设置中的权限可能已经开启，但当前 M · Imago 实例尚未生效，请重新启动应用后再试。"
                )
            }
        }
    }
}

private struct LongScreenshotFrameUpdate: @unchecked Sendable {
    let previewImage: CGImage?
    let frameCount: Int
    let shift: Int
}

private enum LongScreenshotOffsetEstimateSource {
    case bandConsensus
    case validatedBandFallback
    case fullFrameFallback
}

private struct LongScreenshotOffsetEstimate {
    let translation: CGPoint
    let confidence: Float
    let source: LongScreenshotOffsetEstimateSource
}

private struct LongScreenshotImageTranslation {
    let x: CGFloat
    let y: CGFloat
    let confidence: Float
}

/// Vision-based translation matching adapted from ScrollSnap's MIT-licensed
/// StitchingManager. Requiring agreement across several horizontal bands keeps
/// repeated chat bubbles, fixed headers, and composers from deciding the seam.
private struct LongScreenshotVisionOffsetEstimator {
    private let comparisonBandCount = 5
    private let minimumComparisonBandHeight = 80
    private let agreementTolerance: CGFloat = 3
    private let maximumHorizontalMovement: CGFloat = 3
    private let minimumOverlapFraction: CGFloat = 0.15
    private let validatedBandConfidence: Float = 0.8
    private let fullFrameConfidence: Float = 0.9

    func estimate(
        from currentImage: CGImage,
        to previousImage: CGImage
    ) -> LongScreenshotOffsetEstimate? {
        guard currentImage.width == previousImage.width,
              currentImage.height == previousImage.height else {
            return nil
        }

        let frameHeight = CGFloat(currentImage.height)
        let bandTranslations = comparisonBands(for: currentImage).compactMap {
            band -> LongScreenshotImageTranslation? in
            guard let currentBand = currentImage.cropping(to: band),
                  let previousBand = previousImage.cropping(to: band),
                  let translation = findTranslation(
                    from: currentBand,
                    to: previousBand
                  ),
                  isValid(translation, frameHeight: frameHeight) else {
                return nil
            }
            return translation
        }

        if let consensus = bestGroup(in: bandTranslations, minimumCount: 4) {
            return makeEstimate(from: consensus, source: .bandConsensus)
        }

        return resolve(
            bandTranslations: bandTranslations,
            fullFrameTranslation: findTranslation(
                from: currentImage,
                to: previousImage
            ),
            frameHeight: frameHeight
        )
    }

    private func resolve(
        bandTranslations: [LongScreenshotImageTranslation],
        fullFrameTranslation: LongScreenshotImageTranslation?,
        frameHeight: CGFloat
    ) -> LongScreenshotOffsetEstimate? {
        let validBands = bandTranslations.filter {
            isValid($0, frameHeight: frameHeight)
        }
        if let consensus = bestGroup(in: validBands, minimumCount: 4) {
            return makeEstimate(from: consensus, source: .bandConsensus)
        }

        guard let fullFrameTranslation,
              isValid(fullFrameTranslation, frameHeight: frameHeight) else {
            return nil
        }
        if fullFrameTranslation.confidence >= validatedBandConfidence,
           let partialConsensus = bestGroup(in: validBands, minimumCount: 3),
           let bandOffset = average(partialConsensus),
           abs(bandOffset.y - fullFrameTranslation.y) <= agreementTolerance {
            return LongScreenshotOffsetEstimate(
                translation: CGPoint(x: bandOffset.x, y: bandOffset.y),
                confidence: min(
                    bandOffset.confidence,
                    fullFrameTranslation.confidence
                ),
                source: .validatedBandFallback
            )
        }

        guard fullFrameTranslation.confidence >= fullFrameConfidence else {
            return nil
        }
        return LongScreenshotOffsetEstimate(
            translation: CGPoint(
                x: fullFrameTranslation.x,
                y: fullFrameTranslation.y
            ),
            confidence: fullFrameTranslation.confidence,
            source: .fullFrameFallback
        )
    }

    private func comparisonBands(for image: CGImage) -> [CGRect] {
        let imageHeight = image.height
        guard image.width > 0, imageHeight > 0 else { return [] }

        let bandHeight = min(
            imageHeight,
            max(minimumComparisonBandHeight, imageHeight / 3)
        )
        let maximumOriginY = max(0, imageHeight - bandHeight)
        let origins: [Int]
        if maximumOriginY == 0 {
            origins = [0]
        } else {
            origins = (0..<comparisonBandCount).map { index in
                let denominator = max(1, comparisonBandCount - 1)
                return Int(
                    (CGFloat(maximumOriginY) * CGFloat(index)
                        / CGFloat(denominator)).rounded()
                )
            }
        }
        return Array(Set(origins)).sorted().map { originY in
            CGRect(
                x: 0,
                y: originY,
                width: image.width,
                height: bandHeight
            )
        }
    }

    private func bestGroup(
        in translations: [LongScreenshotImageTranslation],
        minimumCount: Int
    ) -> [LongScreenshotImageTranslation]? {
        var bestGroup: [LongScreenshotImageTranslation] = []
        for translation in translations {
            let group = translations.filter {
                abs($0.y - translation.y) <= agreementTolerance
            }
            if group.count > bestGroup.count {
                bestGroup = group
            }
        }
        return bestGroup.count >= minimumCount ? bestGroup : nil
    }

    private func makeEstimate(
        from translations: [LongScreenshotImageTranslation],
        source: LongScreenshotOffsetEstimateSource
    ) -> LongScreenshotOffsetEstimate? {
        guard let translation = average(translations) else { return nil }
        return LongScreenshotOffsetEstimate(
            translation: CGPoint(x: translation.x, y: translation.y),
            confidence: translation.confidence,
            source: source
        )
    }

    private func average(
        _ translations: [LongScreenshotImageTranslation]
    ) -> LongScreenshotImageTranslation? {
        guard !translations.isEmpty else { return nil }
        let count = CGFloat(translations.count)
        return LongScreenshotImageTranslation(
            x: translations.reduce(0) { $0 + $1.x } / count,
            y: translations.reduce(0) { $0 + $1.y } / count,
            confidence: translations.reduce(0) { $0 + $1.confidence }
                / Float(translations.count)
        )
    }

    private func isValid(
        _ translation: LongScreenshotImageTranslation,
        frameHeight: CGFloat
    ) -> Bool {
        let maximumVerticalMovement = frameHeight * (1 - minimumOverlapFraction)
        return abs(translation.x) <= maximumHorizontalMovement
            && abs(translation.y) <= maximumVerticalMovement
    }

    private func findTranslation(
        from currentImage: CGImage,
        to previousImage: CGImage
    ) -> LongScreenshotImageTranslation? {
        let request = VNTranslationalImageRegistrationRequest(
            targetedCGImage: previousImage
        )
        let handler = VNImageRequestHandler(cgImage: currentImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first
            as? VNImageTranslationAlignmentObservation else {
            return nil
        }
        return LongScreenshotImageTranslation(
            x: observation.alignmentTransform.tx,
            y: observation.alignmentTransform.ty,
            confidence: observation.confidence
        )
    }
}

private final class LongScreenshotFrameProcessor: @unchecked Sendable {
    private let lock = NSLock()
    private let offsetEstimator = LongScreenshotVisionOffsetEstimator()
    private var firstFrame: CGImage?
    private var lastFrame: CGImage?
    private var appendedStrips: [CGImage] = []
    private var totalHeight = 0
    private var lastPreviewUptime = 0.0
    private var hasPendingPreview = false

    var hasFrames: Bool {
        lock.lock()
        defer { lock.unlock() }
        return firstFrame != nil
    }

    func consume(_ captured: CGImage) throws -> LongScreenshotFrameUpdate? {
        lock.lock()
        defer { lock.unlock() }

        guard let previous = lastFrame else {
            firstFrame = captured
            lastFrame = captured
            totalHeight = captured.height
            lastPreviewUptime = ProcessInfo.processInfo.systemUptime
            return LongScreenshotFrameUpdate(
                previewImage: captured,
                frameCount: 1,
                shift: 0
            )
        }

        guard let estimate = offsetEstimator.estimate(
            from: captured,
            to: previous
        ) else {
            return nil
        }
        let translatedY = estimate.translation.y
        if abs(translatedY) <= 3 {
            lastFrame = captured
            return nil
        }
        // A negative translation means the user reversed direction. Keeping the
        // last accepted reference avoids corrupting an already assembled image.
        guard translatedY > 0 else { return nil }
        let shift = Int(translatedY.rounded())
        if shift >= 2 {
            let stripHeight = min(shift, captured.height)
            guard let strip = CaptureController.copiedRegion(
                CGRect(
                    x: 0,
                    y: captured.height - stripHeight,
                    width: captured.width,
                    height: stripHeight
                ),
                from: captured
            ) else { return nil }
            guard totalHeight + strip.height <= 60_000 else {
                throw CaptureError.longScreenshotTooLarge
            }
            appendedStrips.append(strip)
            totalHeight += strip.height
            lastFrame = captured
            hasPendingPreview = true
        }

        let now = ProcessInfo.processInfo.systemUptime
        let previewImage: CGImage?
        if hasPendingPreview,
           now - lastPreviewUptime >= 0.24,
           let firstFrame {
            previewImage = try CaptureController.stitchVerticalSegments(
                first: firstFrame,
                strips: appendedStrips,
                maximumPixelSize: CGSize(width: 440, height: 1_400)
            )
            hasPendingPreview = false
            lastPreviewUptime = now
        } else {
            previewImage = nil
        }
        guard shift >= 2 || previewImage != nil else { return nil }
        return LongScreenshotFrameUpdate(
            previewImage: previewImage,
            frameCount: appendedStrips.count + 1,
            shift: shift
        )
    }

    func finishedImage() -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let firstFrame else { return nil }
        return try? CaptureController.stitchVerticalSegments(
            first: firstFrame,
            strips: appendedStrips
        )
    }
}

private struct FrozenDisplayCaptureInput: @unchecked Sendable {
    let display: SCDisplay
    let excludedApplication: SCRunningApplication?
}

@MainActor
final class CaptureController: NSObject, ObservableObject, SCStreamDelegate, SCRecordingOutputDelegate {
    static let shared = CaptureController()

    enum ManualLongScreenshotSource: Sendable {
        case window(windowID: CGWindowID, processID: pid_t)
        case region(
            displayID: CGDirectDisplayID,
            normalizedRect: CGRect,
            scrollTarget: ManualLongScreenshotScrollTarget
        )
    }

    struct ManualLongScreenshotScrollTarget: Sendable, Hashable {
        let windowID: CGWindowID
        let processID: pid_t
        let selectionFrame: CGRect
    }

    @MainActor
    final class ManualLongScreenshotSession: NSObject, ObservableObject {
        @Published private(set) var previewImage: CGImage?
        @Published private(set) var capturedFrameCount = 0
        @Published private(set) var isCapturing = false
        @Published private(set) var errorMessage: String?

        private let source: ManualLongScreenshotSource
        private let frameQueue = DispatchQueue(
            label: "com.modus-imago.long-screenshot.frames",
            qos: .userInitiated
        )
        private nonisolated let frameProcessor = LongScreenshotFrameProcessor()
        private var captureTask: Task<Void, Never>?
        private var isStopped = false

        init(source: ManualLongScreenshotSource) {
            self.source = source
        }

        func start() {
            guard !frameProcessor.hasFrames,
                  captureTask == nil,
                  !isCapturing else { return }
            isCapturing = true
            errorMessage = nil
            DiagnosticLogStore.shared.log(
                .info,
                category: "long-screenshot",
                "manual-session-start source=\(sourceDescription)"
            )
            captureTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    CaptureController.prepareManualLongScreenshotSource(source)
                    try await Task.sleep(for: .milliseconds(120))
                    let (filter, configuration) = try await CaptureController.longScreenshotStreamConfiguration(
                        source: source
                    )
                    guard !isStopped else { return }
                    DiagnosticLogStore.shared.log(
                        .info,
                        category: "long-screenshot",
                        "manual-frame-capture-ready source=\(sourceDescription)"
                    )
                    var isFirstFrame = true
                    while !Task.isCancelled, !isStopped {
                        let image = try await SCScreenshotManager.captureImage(
                            contentFilter: filter,
                            configuration: configuration
                        )
                        await processCapturedImageInOrder(image)
                        if isFirstFrame {
                            isFirstFrame = false
                            isCapturing = false
                        }
                        try await Task.sleep(for: .milliseconds(250))
                    }
                } catch is CancellationError {
                    // Normal when the user finishes or cancels the session.
                } catch {
                    errorMessage = error.localizedDescription
                    DiagnosticLogStore.shared.log(
                        .error,
                        category: "long-screenshot",
                        "manual-session-start-failed error=\(error.localizedDescription)"
                    )
                }
                isCapturing = false
                captureTask = nil
            }
        }

        func stop() {
            isStopped = true
            isCapturing = false
            captureTask?.cancel()
            captureTask = nil
            DiagnosticLogStore.shared.log(
                .debug,
                category: "long-screenshot",
                "manual-session-stop frames=\(capturedFrameCount)"
            )
        }

        func finishedImage() -> CGImage? {
            frameQueue.sync {
                frameProcessor.finishedImage()
            }
        }

        nonisolated private func processCapturedImage(_ image: CGImage) {
            do {
                guard let update = try frameProcessor.consume(image) else { return }
                Task { @MainActor [weak self] in
                    self?.apply(update)
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.reportFrameError(error)
                }
            }
        }

        private func processCapturedImageInOrder(_ image: CGImage) async {
            await withCheckedContinuation { continuation in
                frameQueue.async { [weak self] in
                    self?.processCapturedImage(image)
                    continuation.resume()
                }
            }
        }

        private func apply(_ update: LongScreenshotFrameUpdate) {
            guard !isStopped else { return }
            capturedFrameCount = update.frameCount
            if let updatedPreview = update.previewImage {
                previewImage = updatedPreview
            }
            errorMessage = nil
            DiagnosticLogStore.shared.log(
                .debug,
                category: "long-screenshot",
                "manual-frame-captured count=\(update.frameCount) shift=\(update.shift) preview-height=\(update.previewImage?.height ?? previewImage?.height ?? 0)"
            )
        }

        private func reportFrameError(_ error: Error) {
            guard !isStopped else { return }
            errorMessage = error.localizedDescription
            DiagnosticLogStore.shared.log(
                .warning,
                category: "long-screenshot",
                "manual-frame-failed error=\(error.localizedDescription)"
            )
        }

        private var sourceDescription: String {
            switch source {
            case let .window(windowID, processID):
                "window=\(windowID) pid=\(processID)"
            case let .region(displayID, normalizedRect, scrollTarget):
                "region display=\(displayID) rect=\(normalizedRect.debugDescription) target=\(scrollTarget.windowID) pid=\(scrollTarget.processID)"
            }
        }
    }

    @Published private(set) var isCapturing = false
    @Published private(set) var isRecording = false
    @Published private(set) var statusMessage = "准备就绪" {
        didSet {
            DiagnosticLogStore.shared.log(.debug, category: "status", statusMessage)
        }
    }

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var recordingDurationTask: Task<Void, Never>?
    private var isStoppingRecording = false
    private var windowsHiddenForCapture: [NSWindow] = []
    private var frozenDisplayImages: [CGDirectDisplayID: CGImage] = [:]
    private var isSelectionOverlayPresented = false

    func setStatusMessage(_ message: String) {
        statusMessage = message
    }

    func requestFreeScreenshot() {
        let pointerAtTrigger = NSEvent.mouseLocation
        MImagoPermissions.shared.performWithScreenCapturePermission {
            CaptureController.shared.beginFreeScreenshot(
                initialPointerGlobalLocation: pointerAtTrigger
            )
        }
    }

    func takeScreenshot(completion: ScreenshotCompletion = CapturePreferences.shared.screenshotCompletion) {
        statusMessage = "正在截图…"
        Task { [weak self] in
            do {
                let image = try await Self.captureMainDisplayImage()
                try self?.finishScreenshot(image, completion: completion)
            } catch {
                self?.statusMessage = "截图失败：\(error.localizedDescription)"
            }
        }
    }

    func takeFreeScreenshot(_ result: CaptureSelectionResult) {
        statusMessage = result.action == .longScreenshot ? "正在截取长图…" : "正在处理选区…"
        Task { [weak self] in
            defer { self?.restoreWindowsHiddenForCapture() }
            do {
                try await Task.sleep(for: .milliseconds(120))

                if result.action == .longScreenshot {
                    guard case let .window(windowID, processID) = result.target else {
                        throw CaptureError.longScreenshotRequiresWindow
                    }
                    let longImage = try await Self.captureLongWindowImage(
                        windowID: windowID,
                        processID: processID,
                        progress: { page in
                            self?.statusMessage = "正在拼接长图 · 第 \(page) 屏"
                        }
                    )
                    try self?.finishScreenshot(
                        longImage,
                        completion: CapturePreferences.shared.screenshotCompletion
                    )
                    self?.statusMessage = "长截图已完成"
                    return
                }

                let captured: CGImage
                if let frozenImage = self?.frozenDisplayImages[result.displayID] {
                    captured = try Self.cropFrozenDisplayImage(
                        frozenImage,
                        normalizedRect: result.normalizedFrame
                    )
                } else {
                    switch result.target {
                    case let .window(windowID, processID):
                        Self.raiseWindow(windowID: windowID, processID: processID)
                        try await Task.sleep(for: .milliseconds(180))
                        captured = try await Self.captureWindowImage(
                            windowID: windowID,
                            processID: processID
                        )
                    case let .region(displayID, normalizedRect):
                        captured = try await Self.captureDisplayRegionImage(
                            displayID: displayID,
                            normalizedRect: normalizedRect
                        )
                    }
                }

                let finished = try Self.drawing(result.annotations, on: captured)
                if result.action == .pin {
                    PinnedScreenshotController.shared.show(image: finished)
                    self?.statusMessage = "截图已置顶"
                } else {
                    try self?.finishScreenshot(
                        finished,
                        completion: CapturePreferences.shared.screenshotCompletion
                    )
                }
            } catch {
                self?.statusMessage = Self.captureFailureMessage(
                    prefix: result.action == .longScreenshot ? "长截图失败" : "自由截图失败",
                    error: error
                )
            }
        }
    }

    func finishManualLongScreenshot(_ image: CGImage) {
        statusMessage = "正在完成长截图…"
        do {
            try finishScreenshot(
                image,
                completion: CapturePreferences.shared.screenshotCompletion
            )
            statusMessage = "长截图已完成"
        } catch {
            statusMessage = Self.captureFailureMessage(prefix: "长截图失败", error: error)
        }
        restoreWindowsHiddenForCapture()
    }

    private func beginFreeScreenshot(initialPointerGlobalLocation: CGPoint) {
        guard !isSelectionOverlayPresented else {
            DiagnosticLogStore.shared.log(
                .warning,
                category: "screenshot",
                "ignored duplicate selection request"
            )
            return
        }
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            statusMessage = "无法开始自由截图：未找到显示器。"
            return
        }

        isSelectionOverlayPresented = true
        frozenDisplayImages.removeAll()
        DiagnosticLogStore.shared.log(
            .info,
            category: "screenshot",
            "selection-start displays=\(screens.count)"
        )
        AppDelegate.shared?.setCaptureOverlayActive(true)
        // Hide every visible window owned by M · Imago before querying the
        // WindowServer. FormaUI popovers and the floating thumbnail are
        // panels too; leaving them visible makes them appear in a full-screen
        // capture even though they are not valid window-selection targets.
        windowsHiddenForCapture = NSApp.windows.filter(\.isVisible)
        windowsHiddenForCapture.forEach { $0.orderOut(nil) }

        let candidatesByDisplayID = Self.windowCandidatesByDisplayID(for: screens)
        let displayIDs = candidatesByDisplayID.keys.sorted()
        statusMessage = "正在定格画面…"
        let freezeStartedAt = ContinuousClock.now
        Task { [weak self] in
            guard let self else { return }
            let frozenImages: [CGDirectDisplayID: CGImage]
            do {
                frozenImages = try await Self.captureFrozenDisplayImages(displayIDs: displayIDs)
                let elapsed = freezeStartedAt.duration(to: .now)
                DiagnosticLogStore.shared.log(
                    .info,
                    category: "screenshot",
                    "freeze-ready displays=\(frozenImages.count) elapsed=\(elapsed)"
                )
            } catch {
                frozenImages = [:]
                DiagnosticLogStore.shared.log(
                    .warning,
                    category: "screenshot",
                    "freeze-failed; using-live-overlay error=\(error.localizedDescription)"
                )
            }
            guard self.isSelectionOverlayPresented else { return }
            self.frozenDisplayImages = frozenImages
            self.statusMessage = screens.count > 1
                ? "画面已定格，在任意屏幕选择窗口或区域"
                : "画面已定格，选择窗口或拖拽区域"
            FreeSelectionOverlay.present(
                on: screens,
                windowCandidatesByDisplayID: candidatesByDisplayID,
                frozenImagesByDisplayID: frozenImages,
                initialPointerGlobalLocation: initialPointerGlobalLocation
            ) { result in
                CaptureController.shared.isSelectionOverlayPresented = false
                CaptureController.shared.takeFreeScreenshot(result)
            } onLongScreenshot: { image in
                CaptureController.shared.isSelectionOverlayPresented = false
                CaptureController.shared.finishManualLongScreenshot(image)
            } onCancel: {
                CaptureController.shared.cancelFreeScreenshot()
            }
        }
    }

    func cancelFreeScreenshot() {
        isSelectionOverlayPresented = false
        statusMessage = "已取消截图"
        DiagnosticLogStore.shared.log(.info, category: "screenshot", "selection-cancelled")
        restoreWindowsHiddenForCapture()
    }

    func toggleRecording() {
        isRecording ? stopRecording() : requestRecordingSelection()
    }

    func requestRecordingSelection() {
        guard CapturePreferences.shared.saveDirectory != nil else {
            statusMessage = "录屏需要先选择保存位置。"
            CapturePreferences.shared.chooseSaveDirectory { [weak self] in
                self?.requestRecordingSelection()
            }
            return
        }
        let pointerAtTrigger = NSEvent.mouseLocation
        MImagoPermissions.shared.performWithScreenCapturePermission {
            CaptureController.shared.beginRecordingSelection(
                initialPointerGlobalLocation: pointerAtTrigger
            )
        }
    }

    private func beginRecordingSelection(initialPointerGlobalLocation: CGPoint) {
        guard !isSelectionOverlayPresented else {
            DiagnosticLogStore.shared.log(
                .warning,
                category: "recording",
                "ignored duplicate selection request"
            )
            return
        }
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            statusMessage = "无法开始录屏：未找到显示器。"
            return
        }

        isSelectionOverlayPresented = true
        frozenDisplayImages.removeAll()
        DiagnosticLogStore.shared.log(
            .info,
            category: "recording",
            "selection-start displays=\(screens.count)"
        )
        AppDelegate.shared?.setCaptureOverlayActive(true)
        windowsHiddenForCapture = NSApp.windows.filter(\.isVisible)
        windowsHiddenForCapture.forEach { $0.orderOut(nil) }
        let candidatesByDisplayID = Self.windowCandidatesByDisplayID(for: screens)
        statusMessage = screens.count > 1
            ? "在任意屏幕选择要录制的窗口或自由区域"
            : "选择要录制的窗口或自由区域"

        FreeSelectionOverlay.presentRecording(
            on: screens,
            windowCandidatesByDisplayID: candidatesByDisplayID,
            initialPointerGlobalLocation: initialPointerGlobalLocation
        ) { result, options in
            CaptureController.shared.isSelectionOverlayPresented = false
            CaptureController.shared.startRecording(selection: result, options: options)
        } onCancel: {
            CaptureController.shared.cancelRecordingSetup()
        }
    }

    private func cancelRecordingSetup() {
        isSelectionOverlayPresented = false
        statusMessage = "已取消录屏"
        DiagnosticLogStore.shared.log(.info, category: "recording", "selection-cancelled")
        restoreWindowsHiddenForCapture()
    }

    func startRecording(selection: CaptureSelectionResult, options: RecordingOptions) {
        Task {
            do {
                if options.countdownSeconds > 0 {
                    for second in stride(from: options.countdownSeconds, through: 1, by: -1) {
                        statusMessage = "\(second) 秒后开始录屏"
                        try await Task.sleep(for: .seconds(1))
                    }
                }

                statusMessage = "正在准备录屏…"
                let (filter, configuration) = try await recordingFilterAndConfiguration(
                    selection: selection,
                    options: options
                )

                let destination = try recordingDestination(format: options.format)
                let outputConfiguration = SCRecordingOutputConfiguration()
                outputConfiguration.outputURL = destination
                outputConfiguration.outputFileType = options.format == .mp4 ? .mp4 : .mov

                let output = SCRecordingOutput(
                    configuration: outputConfiguration,
                    delegate: self
                )
                let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
                try stream.addRecordingOutput(output)
                self.stream = stream
                self.recordingOutput = output
                self.isCapturing = true
                self.isRecording = true
                self.isStoppingRecording = false
                self.statusMessage = "正在启动录屏…"
                RecordingStatusPanel.present {
                    CaptureController.shared.stopRecording()
                }

                try await stream.startCapture()
                guard self.stream === stream, !self.isStoppingRecording else { return }
                self.statusMessage = "正在录制"
                if options.maximumDurationMinutes > 0 {
                    recordingDurationTask = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(options.maximumDurationMinutes * 60))
                        guard !Task.isCancelled else { return }
                        self?.stopRecording()
                    }
                }
            } catch {
                statusMessage = "无法开始录屏：\(error.localizedDescription)"
                clearRecordingState()
            }
        }
    }

    func stopRecording() {
        Task {
            guard let stream, !isStoppingRecording else { return }
            isStoppingRecording = true
            RecordingStatusPanel.dismiss()
            recordingDurationTask?.cancel()
            recordingDurationTask = nil
            statusMessage = "正在保存录屏…"
            do {
                try await stream.stopCapture()
                // SCRecordingOutput finishes the container asynchronously
                // after the stream stops. Keep it strongly retained until its
                // delegate confirms the MP4/MOV has been finalized.
                self.stream = nil
                self.isCapturing = false
            } catch {
                statusMessage = "录屏停止失败：\(error.localizedDescription)"
                clearRecordingState()
            }
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard self?.isStoppingRecording != true else { return }
            self?.statusMessage = "录屏已停止：\(error.localizedDescription)"
            self?.clearRecordingState()
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            self?.statusMessage = "录屏已保存"
            self?.clearRecordingState()
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.statusMessage = "录屏失败：\(error.localizedDescription)"
            self?.clearRecordingState()
        }
    }

    private func recordingFilterAndConfiguration(
        selection: CaptureSelectionResult,
        options: RecordingOptions
    ) async throws -> (SCContentFilter, SCStreamConfiguration) {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let configuration = SCStreamConfiguration()
        let filter: SCContentFilter
        let sourcePixelSize: CGSize

        switch selection.target {
        case let .window(windowID, processID):
            guard let window = content.windows.first(where: {
                $0.windowID == windowID && $0.owningApplication?.processID == processID
            }) else { throw CaptureError.windowUnavailable }
            filter = SCContentFilter(desktopIndependentWindow: window)
            sourcePixelSize = CGSize(width: window.frame.width * 2, height: window.frame.height * 2)
            configuration.ignoreShadowsSingleWindow = true

        case let .region(displayID, normalizedRect):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw CaptureError.noDisplayAvailable
            }
            let displayFrame = display.frame
            let sourceRect = CGRect(
                x: normalizedRect.minX * displayFrame.width,
                y: normalizedRect.minY * displayFrame.height,
                width: normalizedRect.width * displayFrame.width,
                height: normalizedRect.height * displayFrame.height
            )
            configuration.sourceRect = sourceRect
            let scale = CGFloat(display.width) / max(1, displayFrame.width)
            sourcePixelSize = CGSize(width: sourceRect.width * scale, height: sourceRect.height * scale)
            if let ownApplication = content.applications.first(where: {
                $0.processID == ProcessInfo.processInfo.processIdentifier
            }) {
                filter = SCContentFilter(
                    display: display,
                    excludingApplications: [ownApplication],
                    exceptingWindows: []
                )
            } else {
                filter = SCContentFilter(display: display, excludingWindows: [])
            }
        }

        let outputSize = Self.recordingOutputSize(sourcePixelSize, quality: options.quality)
        configuration.width = Self.evenPixelCount(outputSize.width)
        configuration.height = Self.evenPixelCount(outputSize.height)
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(options.frameRate.rawValue)
        )
        configuration.showsCursor = options.showsCursor
        configuration.showMouseClicks = options.showsMouseClicks
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.capturesAudio = options.capturesSystemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = options.capturesMicrophone
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        return (filter, configuration)
    }

    nonisolated static func manualLongScreenshotTarget(
        windowID: CGWindowID,
        processID: pid_t,
        selectionFrame: CGRect
    ) -> ManualLongScreenshotScrollTarget? {
        guard selectionFrame.width >= 40,
              selectionFrame.height >= 40,
              let targetWindowFrame = windowFrame(windowID: windowID) else {
            return nil
        }
        let detectedScrollFrame: CGRect? = if AXIsProcessTrusted(),
           let windowElement = accessibilityWindow(
            windowID: windowID,
            processID: processID
           ) {
            scrollableFrame(
                in: windowElement,
                intersecting: selectionFrame.offsetBy(
                    dx: targetWindowFrame.minX,
                    dy: targetWindowFrame.minY
                )
            )
        } else {
            nil
        }
        let resolvedFrame = detectedScrollFrame?.offsetBy(
            dx: -targetWindowFrame.minX,
            dy: -targetWindowFrame.minY
        ) ?? selectionFrame
        return ManualLongScreenshotScrollTarget(
            windowID: windowID,
            processID: processID,
            selectionFrame: resolvedFrame
        )
    }

    nonisolated private static func prepareManualLongScreenshotSource(
        _ source: ManualLongScreenshotSource
    ) {
        let target: ManualLongScreenshotScrollTarget
        switch source {
        case let .window(windowID, processID):
            guard let windowFrame = windowFrame(windowID: windowID) else { return }
            target = ManualLongScreenshotScrollTarget(
                windowID: windowID,
                processID: processID,
                selectionFrame: CGRect(origin: .zero, size: windowFrame.size)
            )
        case let .region(_, _, scrollTarget):
            target = scrollTarget
        }

        movePointerIntoScrollSelection(target)
    }

    nonisolated private static func movePointerIntoScrollSelection(
        _ target: ManualLongScreenshotScrollTarget
    ) {
        guard let windowFrame = windowFrame(windowID: target.windowID) else { return }
        let selection = target.selectionFrame.standardized.intersection(
            CGRect(origin: .zero, size: windowFrame.size)
        )
        guard !selection.isNull, selection.width > 0, selection.height > 0 else { return }
        CGWarpMouseCursorPosition(
            CGPoint(
                x: windowFrame.minX + selection.midX,
                y: windowFrame.minY + selection.midY
            )
        )
    }

    nonisolated private static func recordingOutputSize(
        _ source: CGSize,
        quality: RecordingQuality
    ) -> CGSize {
        let maximumHeight: CGFloat? = switch quality {
        case .adaptive1080p: 1080
        case .p720: 720
        case .original: nil
        }
        guard let maximumHeight, source.height > maximumHeight else { return source }
        let scale = maximumHeight / source.height
        return CGSize(width: source.width * scale, height: source.height * scale)
    }

    nonisolated private static func evenPixelCount(_ value: CGFloat) -> Int {
        let rounded = max(2, Int(value.rounded()))
        return rounded.isMultiple(of: 2) ? rounded : rounded - 1
    }

    private func finishScreenshot(_ image: CGImage, completion: ScreenshotCompletion) throws {
        FloatingThumbnailController.shared.show(
            image: image,
            duration: CapturePreferences.shared.thumbnailDuration
        )
        if completion == .copy || completion == .copyAndSave {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: .zero)])
        }

        if completion.needsDirectory {
            guard let directory = CapturePreferences.shared.saveDirectory else {
                throw CaptureError.saveDirectoryRequired
            }
            let destination = directory.appendingPathComponent("M-Imago_\(Self.timestamp()).png")
            guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw CaptureError.imageEncodingFailed
            }
            try data.write(to: destination, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
        statusMessage = completion == .copy ? "截图已复制到剪贴板" : "截图已完成"
    }

    nonisolated private static func captureFrozenDisplayImages(
        displayIDs: [CGDirectDisplayID]
    ) async throws -> [CGDirectDisplayID: CGImage] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let requestedIDs = Set(displayIDs)
        let displays = content.displays.filter { requestedIDs.contains($0.displayID) }
        guard !displays.isEmpty else { throw CaptureError.noDisplayAvailable }
        let ownApplication = content.applications.first {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }
        let inputs = displays.map {
            FrozenDisplayCaptureInput(display: $0, excludedApplication: ownApplication)
        }

        return try await withThrowingTaskGroup(
            of: (CGDirectDisplayID, CGImage).self,
            returning: [CGDirectDisplayID: CGImage].self
        ) { group in
            for input in inputs {
                group.addTask {
                    let display = input.display
                    let configuration = SCStreamConfiguration()
                    // SCDisplay.width/height follow the display's logical mode.
                    // On a Retina display that is only half of the backing pixel
                    // dimensions, so presenting it full-screen visibly softens
                    // text and the cropped screenshot permanently loses detail.
                    let displayMode = CGDisplayCopyDisplayMode(display.displayID)
                    configuration.width = displayMode?.pixelWidth ?? display.width
                    configuration.height = displayMode?.pixelHeight ?? display.height
                    configuration.captureResolution = .best
                    configuration.showsCursor = false
                    configuration.capturesAudio = false
                    let filter: SCContentFilter
                    if let excludedApplication = input.excludedApplication {
                        filter = SCContentFilter(
                            display: display,
                            excludingApplications: [excludedApplication],
                            exceptingWindows: []
                        )
                    } else {
                        filter = SCContentFilter(display: display, excludingWindows: [])
                    }
                    let image = try await SCScreenshotManager.captureImage(
                        contentFilter: filter,
                        configuration: configuration
                    )
                    DiagnosticLogStore.shared.log(
                        .debug,
                        category: "screenshot",
                        "freeze-display id=\(display.displayID) logical=\(display.width)x\(display.height) requested=\(configuration.width)x\(configuration.height) received=\(image.width)x\(image.height)"
                    )
                    return (display.displayID, image)
                }
            }

            var images: [CGDirectDisplayID: CGImage] = [:]
            for try await (displayID, image) in group {
                images[displayID] = image
            }
            return images
        }
    }

    nonisolated private static func cropFrozenDisplayImage(
        _ image: CGImage,
        normalizedRect: CGRect
    ) throws -> CGImage {
        let unitBounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        let clamped = normalizedRect.standardized.intersection(unitBounds)
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else {
            throw CaptureError.invalidSelection
        }
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let pixelRect = CGRect(
            x: floor(clamped.minX * CGFloat(image.width)),
            y: floor(clamped.minY * CGFloat(image.height)),
            width: ceil(clamped.maxX * CGFloat(image.width))
                - floor(clamped.minX * CGFloat(image.width)),
            height: ceil(clamped.maxY * CGFloat(image.height))
                - floor(clamped.minY * CGFloat(image.height))
        ).intersection(imageBounds)
        guard let cropped = image.cropping(to: pixelRect),
              cropped.width > 0,
              cropped.height > 0 else {
            throw CaptureError.imageUnavailable
        }
        return cropped
    }

    nonisolated private static func captureMainDisplayImage() async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainDisplayID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainDisplayID })
            ?? content.displays.first else { throw CaptureError.imageUnavailable }
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.showsCursor = true
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []),
            configuration: configuration
        )
    }

    nonisolated private static func captureDisplayRegionImage(
        displayID: CGDirectDisplayID,
        normalizedRect: CGRect,
        excludingCurrentProcess: Bool = false
    ) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.imageUnavailable
        }
        let clamped = normalizedRect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard clamped.width > 0, clamped.height > 0 else { throw CaptureError.invalidSelection }

        let displayFrame = display.frame
        let sourceRect = CGRect(
            x: clamped.minX * displayFrame.width,
            y: clamped.minY * displayFrame.height,
            width: clamped.width * displayFrame.width,
            height: clamped.height * displayFrame.height
        )
        let scale = CGFloat(display.width) / max(1, displayFrame.width)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        // Still images do not require even dimensions. Preserve the user's
        // rounded selection size exactly instead of shrinking odd edges as the
        // video encoder helper does.
        configuration.width = max(1, Int((sourceRect.width * scale).rounded()))
        configuration.height = max(1, Int((sourceRect.height * scale).rounded()))
        configuration.showsCursor = !excludingCurrentProcess
        let filter: SCContentFilter
        if excludingCurrentProcess,
           let application = content.applications.first(where: {
               $0.processID == ProcessInfo.processInfo.processIdentifier
           }) {
            filter = SCContentFilter(
                display: display,
                excludingApplications: [application],
                exceptingWindows: []
            )
        } else {
            filter = SCContentFilter(display: display, excludingWindows: [])
        }
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }

    nonisolated private static func longScreenshotStreamConfiguration(
        source: ManualLongScreenshotSource
    ) async throws -> (SCContentFilter, SCStreamConfiguration) {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let configuration = SCStreamConfiguration()
        let filter: SCContentFilter

        switch source {
        case let .window(windowID, processID):
            guard let window = content.windows.first(where: {
                $0.windowID == windowID &&
                $0.owningApplication?.processID == processID
            }) else {
                throw CaptureError.windowUnavailable
            }
            let sourceScale = content.displays
                .filter { $0.frame.intersects(window.frame) }
                .max { lhs, rhs in
                    lhs.frame.intersection(window.frame).area
                        < rhs.frame.intersection(window.frame).area
                }
                .map { CGFloat($0.width) / max(1, $0.frame.width) }
                ?? 1
            configuration.width = max(1, Int((window.frame.width * sourceScale).rounded()))
            configuration.height = max(1, Int((window.frame.height * sourceScale).rounded()))
            configuration.ignoreShadowsSingleWindow = true
            filter = SCContentFilter(desktopIndependentWindow: window)

        case let .region(displayID, normalizedRect, _):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw CaptureError.noDisplayAvailable
            }
            let clamped = normalizedRect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard clamped.width > 0, clamped.height > 0 else {
                throw CaptureError.invalidSelection
            }
            let sourceRect = CGRect(
                x: clamped.minX * display.frame.width,
                y: clamped.minY * display.frame.height,
                width: clamped.width * display.frame.width,
                height: clamped.height * display.frame.height
            )
            let scale = CGFloat(display.width) / max(1, display.frame.width)
            configuration.sourceRect = sourceRect
            configuration.width = max(1, Int((sourceRect.width * scale).rounded()))
            configuration.height = max(1, Int((sourceRect.height * scale).rounded()))
            if let ownApplication = content.applications.first(where: {
                $0.processID == ProcessInfo.processInfo.processIdentifier
            }) {
                filter = SCContentFilter(
                    display: display,
                    excludingApplications: [ownApplication],
                    exceptingWindows: []
                )
            } else {
                filter = SCContentFilter(display: display, excludingWindows: [])
            }
        }

        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.captureResolution = .best
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 12)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.capturesAudio = false
        return (filter, configuration)
    }

    private static func windowCandidates(for screen: NSScreen) -> [CaptureWindowCandidate] {
        guard let rawDisplayID = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber,
              let windowInfo = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[CFString: Any]] else { return [] }

        let displayBounds = CGDisplayBounds(CGDirectDisplayID(rawDisplayID.uint32Value))
        let localBounds = CGRect(origin: .zero, size: displayBounds.size)
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        let excludedOwners = Set([
            "Window Server",
            "Dock",
            "SystemUIServer",
            "Control Center",
            "Notification Center",
            "ChatGPT Computer Use"
        ])
        let excludedWindowNames = Set([
            "Cursor",
            "Software Cursor",
            "StatusIndicator"
        ])

        return windowInfo.compactMap { info in
            guard let layer = info[kCGWindowLayer] as? Int,
                  layer == 0,
                  let windowID = info[kCGWindowNumber] as? CGWindowID,
                  let processID = info[kCGWindowOwnerPID] as? pid_t,
                  processID != ownProcessID,
                  let ownerName = info[kCGWindowOwnerName] as? String,
                  !excludedOwners.contains(ownerName),
                  let alpha = info[kCGWindowAlpha] as? CGFloat,
                  alpha > 0.01,
                  let sharingState = info[kCGWindowSharingState] as? Int,
                  sharingState != 0,
                  let boundsDictionary = info[kCGWindowBounds] as? NSDictionary,
                  let globalFrame = CGRect(dictionaryRepresentation: boundsDictionary),
                  globalFrame.width >= 80,
                  globalFrame.height >= 60 else { return nil }

            if let windowName = info[kCGWindowName] as? String,
               excludedWindowNames.contains(windowName) {
                return nil
            }

            let localFrame = CGRect(
                x: globalFrame.minX - displayBounds.minX,
                y: globalFrame.minY - displayBounds.minY,
                width: globalFrame.width,
                height: globalFrame.height
            ).intersection(localBounds)
            guard localFrame.width >= 40, localFrame.height >= 40 else { return nil }

            return CaptureWindowCandidate(
                windowID: windowID,
                processID: processID,
                frame: localFrame
            )
        }
    }

    private static func windowCandidatesByDisplayID(
        for screens: [NSScreen]
    ) -> [CGDirectDisplayID: [CaptureWindowCandidate]] {
        Dictionary(uniqueKeysWithValues: screens.compactMap { screen in
            guard let rawDisplayID = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { return nil }
            let displayID = CGDirectDisplayID(rawDisplayID.uint32Value)
            return (displayID, windowCandidates(for: screen))
        })
    }

    nonisolated private static func captureWindowImage(
        windowID: CGWindowID,
        processID: pid_t
    ) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        guard let window = content.windows.first(where: {
            $0.windowID == windowID &&
            $0.owningApplication?.processID == processID
        }) else {
            throw CaptureError.windowUnavailable
        }

        let configuration = SCStreamConfiguration()
        let sourceScale = content.displays
            .filter { $0.frame.intersects(window.frame) }
            .max { lhs, rhs in
                lhs.frame.intersection(window.frame).area < rhs.frame.intersection(window.frame).area
            }
            .map { CGFloat($0.width) / max(1, $0.frame.width) }
            ?? 1
        configuration.width = max(1, Int((window.frame.width * sourceScale).rounded()))
        configuration.height = max(1, Int((window.frame.height * sourceScale).rounded()))
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window),
            configuration: configuration
        )
    }

    private struct ScrollCaptureTarget {
        let scrollArea: AXUIElement
        let scrollBar: AXUIElement
        let frame: CGRect
    }

    private static func captureLongWindowImage(
        windowID: CGWindowID,
        processID: pid_t,
        progress: @escaping @MainActor (Int) -> Void
    ) async throws -> CGImage {
        raiseWindow(windowID: windowID, processID: processID)
        try await Task.sleep(for: .milliseconds(260))

        guard let windowFrame = windowFrame(windowID: windowID),
              windowFrame.width > 0,
              windowFrame.height > 0 else {
            throw CaptureError.windowUnavailable
        }

        if let windowElement = accessibilityWindow(
            windowID: windowID,
            processID: processID
        ),
           let target = largestScrollableArea(in: windowElement) {
            return try await captureLongWindowUsingScrollBar(
                target,
                windowID: windowID,
                processID: processID,
                windowFrame: windowFrame,
                progress: progress
            )
        }

        return try await captureLongWindowUsingScrollEvents(
            windowID: windowID,
            processID: processID,
            windowFrame: windowFrame,
            progress: progress
        )
    }

    private static func captureLongWindowUsingScrollBar(
        _ target: ScrollCaptureTarget,
        windowID: CGWindowID,
        processID: pid_t,
        windowFrame: CGRect,
        progress: @escaping @MainActor (Int) -> Void
    ) async throws -> CGImage {
        let minimumValue = accessibilityNumber(target.scrollBar, attribute: kAXMinValueAttribute) ?? 0
        let maximumValue = accessibilityNumber(target.scrollBar, attribute: kAXMaxValueAttribute) ?? 1
        let originalValue = accessibilityNumber(target.scrollBar, attribute: kAXValueAttribute) ?? minimumValue
        guard maximumValue - minimumValue > 0.0001 else {
            throw CaptureError.scrollableContentUnavailable
        }

        defer {
            _ = AXUIElementSetAttributeValue(
                target.scrollBar,
                kAXValueAttribute as CFString,
                NSNumber(value: originalValue)
            )
        }

        let captureCount = 25
        var frames: [CGImage] = []
        for index in 0..<captureCount {
            try Task.checkCancellation()
            let progressValue = Double(index) / Double(captureCount - 1)
            let value = minimumValue + (maximumValue - minimumValue) * progressValue
            let setResult = AXUIElementSetAttributeValue(
                target.scrollBar,
                kAXValueAttribute as CFString,
                NSNumber(value: value)
            )
            guard setResult == .success else {
                throw CaptureError.accessibilityPermissionRequired
            }
            try await Task.sleep(for: .milliseconds(index == 0 ? 180 : 85))
            let windowImage = try await captureWindowImage(
                windowID: windowID,
                processID: processID
            )
            let cropped = try cropScrollableArea(
                target.frame,
                from: windowImage,
                windowFrame: windowFrame
            )
            frames.append(cropped)
            progress(index + 1)
        }

        return try stitchVerticalFrames(frames)
    }

    private static func captureLongWindowUsingScrollEvents(
        windowID: CGWindowID,
        processID: pid_t,
        windowFrame: CGRect,
        progress: @escaping @MainActor (Int) -> Void
    ) async throws -> CGImage {
        guard await MImagoPermissions.shared.ensureAccessibilityAuthorization() else {
            throw CaptureError.accessibilityPermissionRequired
        }

        var frames: [CGImage] = []
        var unchangedCount = 0
        let maximumFrames = 28
        for index in 0..<maximumFrames {
            try Task.checkCancellation()
            let frame = try await captureWindowImage(
                windowID: windowID,
                processID: processID
            )
            if let previous = frames.last {
                let shift = try detectedVerticalShift(from: previous, to: frame)
                if shift < 2 {
                    unchangedCount += 1
                } else {
                    unchangedCount = 0
                }
                if unchangedCount >= 2 { break }
            }
            frames.append(frame)
            progress(frames.count)

            guard index < maximumFrames - 1 else { break }
            guard let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 1,
                wheel1: -Int32(max(180, windowFrame.height * 0.72)),
                wheel2: 0,
                wheel3: 0
            ) else {
                throw CaptureError.scrollableContentUnavailable
            }
            event.location = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
            event.postToPid(processID)
            try await Task.sleep(for: .milliseconds(150))
        }

        return try stitchVerticalFrames(frames)
    }

    nonisolated private static func accessibilityWindow(
        windowID: CGWindowID,
        processID: pid_t
    ) -> AXUIElement? {
        let targetFrame = windowFrame(windowID: windowID)
        let targetTitle = windowTitle(windowID: windowID)
        let application = AXUIElementCreateApplication(processID)
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &rawWindows
        ) == .success,
              let windows = rawWindows as? [AXUIElement] else { return nil }

        return windows.first { window in
            var rawWindowNumber: CFTypeRef?
            let copiedWindowNumber = AXUIElementCopyAttributeValue(
                window,
                "AXWindowNumber" as CFString,
                &rawWindowNumber
            ) == .success
            let hasMatchingWindowNumber = copiedWindowNumber
                && (rawWindowNumber as? NSNumber).map { CGWindowID($0.uint32Value) == windowID } == true
            let hasMatchingFrame = targetFrame.map { axWindowFrame(window).approximatelyEquals($0) } == true
            let hasMatchingTitle = targetTitle.map { axWindowTitle(window) == $0 } == true
            return hasMatchingWindowNumber || hasMatchingFrame || hasMatchingTitle
        }
    }

    nonisolated private static func scrollableFrame(
        in root: AXUIElement,
        intersecting selectionFrame: CGRect
    ) -> CGRect? {
        var best: CGRect?

        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 18 else { return }

            var rawRole: CFTypeRef?
            let role = AXUIElementCopyAttributeValue(
                element,
                kAXRoleAttribute as CFString,
                &rawRole
            ) == .success ? rawRole as? String : nil

            var rawScrollBar: CFTypeRef?
            let copiedScrollBar = AXUIElementCopyAttributeValue(
                element,
                kAXVerticalScrollBarAttribute as CFString,
                &rawScrollBar
            ) == .success
            var hasScrollableRange = false
            if copiedScrollBar,
               let rawScrollBar,
               CFGetTypeID(rawScrollBar) == AXUIElementGetTypeID() {
                let scrollBar = unsafeDowncast(rawScrollBar, to: AXUIElement.self)
                let minimum = accessibilityNumber(
                    scrollBar,
                    attribute: kAXMinValueAttribute
                ) ?? 0
                let maximum = accessibilityNumber(
                    scrollBar,
                    attribute: kAXMaxValueAttribute
                ) ?? 0
                hasScrollableRange = maximum - minimum > 0.0001
            }

            var actionNames: CFArray?
            let supportsScrollAction = AXUIElementCopyActionNames(
                element,
                &actionNames
            ) == .success && (actionNames as? [String])?.contains(where: {
                $0.localizedCaseInsensitiveContains("scroll")
            }) == true

            if (role == kAXScrollAreaRole || copiedScrollBar),
               hasScrollableRange || supportsScrollAction {
                let frame = axWindowFrame(element).standardized
                let overlap = frame.intersection(selectionFrame.standardized)
                if !overlap.isNull,
                   overlap.width >= 60,
                   overlap.height >= 60,
                   overlap.area >= min(3_600, selectionFrame.area * 0.18) {
                    if overlap.area > (best?.area ?? 0) {
                        best = overlap
                    }
                }
            }

            var rawChildren: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element,
                kAXChildrenAttribute as CFString,
                &rawChildren
            ) == .success,
                  let children = rawChildren as? [AXUIElement] else { return }
            for child in children {
                visit(child, depth: depth + 1)
            }
        }

        visit(root, depth: 0)
        return best
    }

    private static func largestScrollableArea(
        in root: AXUIElement
    ) -> ScrollCaptureTarget? {
        var best: ScrollCaptureTarget?

        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 18 else { return }
            var rawScrollBar: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                element,
                kAXVerticalScrollBarAttribute as CFString,
                &rawScrollBar
            ) == .success,
               let scrollBar = rawScrollBar,
               CFGetTypeID(scrollBar) == AXUIElementGetTypeID() {
                let resolvedScrollBar = unsafeDowncast(scrollBar, to: AXUIElement.self)
                var isSettable = DarwinBoolean(false)
                let canSetValue = AXUIElementIsAttributeSettable(
                    resolvedScrollBar,
                    kAXValueAttribute as CFString,
                    &isSettable
                ) == .success && isSettable.boolValue
                let frame = axWindowFrame(element)
                if canSetValue,
                   frame.width >= 120,
                   frame.height >= 120,
                   frame.area > (best?.frame.area ?? 0) {
                    best = ScrollCaptureTarget(
                        scrollArea: element,
                        scrollBar: resolvedScrollBar,
                        frame: frame
                    )
                }
            }

            var rawChildren: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element,
                kAXChildrenAttribute as CFString,
                &rawChildren
            ) == .success,
                  let children = rawChildren as? [AXUIElement] else { return }
            for child in children {
                visit(child, depth: depth + 1)
            }
        }

        visit(root, depth: 0)
        return best
    }

    private static func largestScrollableFrame(in root: AXUIElement) -> CGRect? {
        var best: CGRect?

        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 18 else { return }

            var rawRole: CFTypeRef?
            let role = AXUIElementCopyAttributeValue(
                element,
                kAXRoleAttribute as CFString,
                &rawRole
            ) == .success ? rawRole as? String : nil

            var rawScrollBar: CFTypeRef?
            let hasVerticalScrollBar = AXUIElementCopyAttributeValue(
                element,
                kAXVerticalScrollBarAttribute as CFString,
                &rawScrollBar
            ) == .success
            if role == kAXScrollAreaRole || hasVerticalScrollBar {
                let frame = axWindowFrame(element)
                if frame.width >= 120,
                   frame.height >= 120,
                   frame.area > (best?.area ?? 0) {
                    best = frame
                }
            }

            var rawChildren: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element,
                kAXChildrenAttribute as CFString,
                &rawChildren
            ) == .success,
                  let children = rawChildren as? [AXUIElement] else { return }
            for child in children {
                visit(child, depth: depth + 1)
            }
        }

        visit(root, depth: 0)
        return best
    }

    nonisolated private static func accessibilityNumber(
        _ element: AXUIElement,
        attribute: String
    ) -> Double? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &rawValue
        ) == .success else { return nil }
        return (rawValue as? NSNumber)?.doubleValue
    }

    nonisolated private static func cropScrollableArea(
        _ scrollFrame: CGRect,
        from image: CGImage,
        windowFrame: CGRect
    ) throws -> CGImage {
        let scaleX = CGFloat(image.width) / max(1, windowFrame.width)
        let scaleY = CGFloat(image.height) / max(1, windowFrame.height)
        let relative = CGRect(
            x: (scrollFrame.minX - windowFrame.minX) * scaleX,
            y: CGFloat(image.height) - (scrollFrame.maxY - windowFrame.minY) * scaleY,
            width: scrollFrame.width * scaleX,
            height: scrollFrame.height * scaleY
        ).integral.intersection(
            CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        guard relative.width >= 20,
              relative.height >= 20,
              let cropped = image.cropping(to: relative) else {
            throw CaptureError.scrollableContentUnavailable
        }
        return cropped
    }

    nonisolated private static func stitchVerticalFrames(
        _ frames: [CGImage]
    ) throws -> CGImage {
        guard let first = frames.first else { throw CaptureError.imageUnavailable }
        var strips: [CGImage] = []
        var previous = first

        for next in frames.dropFirst() {
            let shift = try detectedVerticalShift(from: previous, to: next)
            guard shift >= 2 else { continue }
            let stripHeight = min(shift, next.height)
            guard let strip = copiedRegion(
                CGRect(
                    x: 0,
                    y: next.height - stripHeight,
                    width: next.width,
                    height: stripHeight
                ),
                from: next
            ) else { continue }
            strips.append(strip)
            previous = next
        }

        guard !strips.isEmpty else { throw CaptureError.longScreenshotNoMovement }
        return try stitchVerticalSegments(first: first, strips: strips)
    }

    nonisolated fileprivate static func stitchVerticalSegments(
        first: CGImage,
        strips: [CGImage],
        maximumPixelSize: CGSize? = nil
    ) throws -> CGImage {
        let totalHeight = first.height + strips.reduce(0) { $0 + $1.height }
        guard totalHeight <= 60_000,
              first.width > 0,
              totalHeight > 0 else {
            throw CaptureError.longScreenshotTooLarge
        }

        let scale: CGFloat
        if let maximumPixelSize {
            scale = min(
                1,
                maximumPixelSize.width / CGFloat(first.width),
                maximumPixelSize.height / CGFloat(totalHeight)
            )
        } else {
            scale = 1
        }
        let outputWidth = max(1, Int((CGFloat(first.width) * scale).rounded()))
        let outputHeight = max(1, Int((CGFloat(totalHeight) * scale).rounded()))
        guard let context = CGContext(
                data: nil,
                width: outputWidth,
                height: outputHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw CaptureError.imageEncodingFailed
        }

        context.interpolationQuality = scale < 1 ? .medium : .high
        context.scaleBy(x: scale, y: scale)
        var cursorY = totalHeight - first.height
        context.draw(
            first,
            in: CGRect(x: 0, y: cursorY, width: first.width, height: first.height)
        )
        for strip in strips {
            cursorY -= strip.height
            context.draw(
                strip,
                in: CGRect(x: 0, y: cursorY, width: first.width, height: strip.height)
            )
        }
        guard let result = context.makeImage() else {
            throw CaptureError.imageEncodingFailed
        }
        return result
    }

    nonisolated fileprivate static func copiedRegion(
        _ rect: CGRect,
        from image: CGImage
    ) -> CGImage? {
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let resolved = rect.integral.intersection(imageBounds)
        guard resolved.width >= 1,
              resolved.height >= 1,
              let cropped = image.cropping(to: resolved),
              let context = CGContext(
                data: nil,
                width: cropped.width,
                height: cropped.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.draw(
            cropped,
            in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height)
        )
        return context.makeImage()
    }

    nonisolated fileprivate static func detectedVerticalShift(
        from previous: CGImage,
        to next: CGImage
    ) throws -> Int {
        guard let estimate = LongScreenshotVisionOffsetEstimator().estimate(
            from: next,
            to: previous
        ) else {
            return 0
        }
        let shift = estimate.translation.y
        guard shift > 3 else { return 0 }
        return Int(shift.rounded())
    }

    nonisolated private static func raiseWindow(windowID: CGWindowID, processID: pid_t) {
        NSRunningApplication(processIdentifier: processID)?
            .activate(options: [.activateAllWindows])

        let targetFrame = windowFrame(windowID: windowID)
        let targetTitle = windowTitle(windowID: windowID)

        let application = AXUIElementCreateApplication(processID)
        _ = AXUIElementSetAttributeValue(
            application,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &rawWindows
        ) == .success,
              let windows = rawWindows as? [AXUIElement] else { return }

        for window in windows {
            var rawWindowNumber: CFTypeRef?
            let copiedWindowNumber = AXUIElementCopyAttributeValue(
                window,
                "AXWindowNumber" as CFString,
                &rawWindowNumber
            ) == .success
            let hasMatchingWindowNumber = copiedWindowNumber &&
                (rawWindowNumber as? NSNumber).map { CGWindowID($0.uint32Value) == windowID } == true
            let hasMatchingFrame = targetFrame.map { axWindowFrame(window).approximatelyEquals($0) } == true
            let hasMatchingTitle = targetTitle.map { axWindowTitle(window) == $0 } == true
            guard hasMatchingWindowNumber || hasMatchingFrame || hasMatchingTitle else { continue }

            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            _ = AXUIElementSetAttributeValue(
                window,
                kAXMainAttribute as CFString,
                kCFBooleanTrue
            )
            _ = AXUIElementSetAttributeValue(
                window,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
            return
        }
    }

    nonisolated private static func windowFrame(windowID: CGWindowID) -> CGRect? {
        guard let items = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            windowID
        ) as? [[CFString: Any]],
              let bounds = items.first?[kCGWindowBounds] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }

    nonisolated private static func windowTitle(windowID: CGWindowID) -> String? {
        guard let items = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            windowID
        ) as? [[CFString: Any]],
              let title = items.first?[kCGWindowName] as? String,
              !title.isEmpty else { return nil }
        return title
    }

    nonisolated private static func axWindowTitle(_ window: AXUIElement) -> String? {
        var rawTitle: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXTitleAttribute as CFString,
            &rawTitle
        ) == .success else { return nil }
        return rawTitle as? String
    }

    nonisolated private static func axWindowFrame(_ window: AXUIElement) -> CGRect {
        var rawPosition: CFTypeRef?
        var rawSize: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            &rawPosition
        ) == .success,
              AXUIElementCopyAttributeValue(
                window,
                kAXSizeAttribute as CFString,
                &rawSize
              ) == .success,
              let rawPosition,
              let rawSize,
              CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              CFGetTypeID(rawSize) == AXValueGetTypeID() else { return .null }

        var position = CGPoint.zero
        var size = CGSize.zero
        let positionValue = unsafeDowncast(rawPosition, to: AXValue.self)
        let sizeValue = unsafeDowncast(rawSize, to: AXValue.self)
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return .null }
        return CGRect(origin: position, size: size)
    }

    nonisolated private static func crop(_ image: CGImage, to normalizedRect: CGRect) throws -> CGImage {
        let clamped = normalizedRect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard clamped.width > 0, clamped.height > 0 else { throw CaptureError.invalidSelection }
        let cropRect = CGRect(
            x: clamped.minX * CGFloat(image.width),
            y: (1 - clamped.maxY) * CGFloat(image.height),
            width: clamped.width * CGFloat(image.width),
            height: clamped.height * CGFloat(image.height)
        ).integral
        guard let cropped = image.cropping(to: cropRect) else { throw CaptureError.invalidSelection }
        return cropped
    }

    nonisolated private static func drawing(
        _ annotations: [CaptureAnnotation],
        on image: CGImage
    ) throws -> CGImage {
        guard !annotations.isEmpty else { return image }
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CaptureError.imageEncodingFailed
        }

        let canvas = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.interpolationQuality = .high
        context.draw(image, in: canvas)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let highlightAnnotations = annotations.filter { $0.kind == .highlight }
        if !highlightAnnotations.isEmpty {
            context.saveGState()
            context.setFillColor(CGColor(gray: 0, alpha: 0.54))
            context.fill(canvas)
            for annotation in highlightAnnotations {
                let start = CGPoint(
                    x: annotation.start.x * CGFloat(image.width),
                    y: (1 - annotation.start.y) * CGFloat(image.height)
                )
                let end = CGPoint(
                    x: annotation.end.x * CGFloat(image.width),
                    y: (1 - annotation.end.y) * CGFloat(image.height)
                )
                let highlightRect = CGRect(
                    x: min(start.x, end.x),
                    y: min(start.y, end.y),
                    width: abs(start.x - end.x),
                    height: abs(start.y - end.y)
                )
                context.saveGState()
                context.clip(to: highlightRect)
                context.draw(image, in: canvas)
                context.restoreGState()
            }
            context.restoreGState()
        }

        var mosaicCache: [CaptureAnnotationThickness: CGImage] = [:]

        for annotation in annotations {
            let renderScale = max(1, min(3, CGFloat(image.width) / 1000))
            context.setStrokeColor(annotation.color.cgColor)
            context.setFillColor(annotation.color.cgColor)
            context.setLineWidth(annotation.thickness.rawValue * renderScale)
            let start = CGPoint(
                x: annotation.start.x * CGFloat(image.width),
                y: (1 - annotation.start.y) * CGFloat(image.height)
            )
            let end = CGPoint(
                x: annotation.end.x * CGFloat(image.width),
                y: (1 - annotation.end.y) * CGFloat(image.height)
            )
            if annotation.kind == .highlight {
                continue
            } else if annotation.kind == .mosaic {
                let pixelated: CGImage
                if let cached = mosaicCache[annotation.thickness] {
                    pixelated = cached
                } else {
                    let blockSize = switch annotation.thickness {
                    case .thin: 9
                    case .medium: 14
                    case .thick: 22
                    }
                    pixelated = try pixelatedImage(image, blockSize: blockSize)
                    mosaicCache[annotation.thickness] = pixelated
                }

                let normalizedPoints = annotation.points.isEmpty
                    ? [annotation.start, annotation.end]
                    : annotation.points
                guard let firstPoint = normalizedPoints.first else { continue }
                let brushPath = CGMutablePath()
                brushPath.move(
                    to: CGPoint(
                        x: firstPoint.x * CGFloat(image.width),
                        y: (1 - firstPoint.y) * CGFloat(image.height)
                    )
                )
                for point in normalizedPoints.dropFirst() {
                    brushPath.addLine(
                        to: CGPoint(
                            x: point.x * CGFloat(image.width),
                            y: (1 - point.y) * CGFloat(image.height)
                        )
                    )
                }
                let clippedPath = brushPath.copy(
                    strokingWithWidth: annotation.thickness.mosaicWidth * renderScale,
                    lineCap: .round,
                    lineJoin: .round,
                    miterLimit: 0
                )
                context.saveGState()
                context.addPath(clippedPath)
                context.clip()
                context.interpolationQuality = .none
                context.draw(pixelated, in: canvas)
                context.restoreGState()
                context.interpolationQuality = .high
                continue
            } else if annotation.kind == .text {
                guard let text = annotation.text, !text.isEmpty else { continue }
                let fontSize = (annotation.textSize?.rawValue
                    ?? annotation.thickness.textFontSize) * renderScale
                let font = CTFontCreateWithName("PingFang SC" as CFString, fontSize, nil)
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): annotation.color.cgColor
                ]
                let line = CTLineCreateWithAttributedString(
                    NSAttributedString(string: text, attributes: attributes)
                )
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                var leading: CGFloat = 0
                let textWidth = CGFloat(
                    CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
                )
                let paddingX = 5 * renderScale
                let paddingY = 3 * renderScale
                let backgroundRect = CGRect(
                    x: start.x - paddingX,
                    y: start.y - ascent - descent - paddingY,
                    width: textWidth + paddingX * 2,
                    height: ascent + descent + paddingY * 2
                )
                context.saveGState()
                if let backgroundColor = annotation.textBackground?.cgColor {
                    context.setFillColor(backgroundColor)
                    context.addPath(
                        CGPath(
                            roundedRect: backgroundRect,
                            cornerWidth: 4 * renderScale,
                            cornerHeight: 4 * renderScale,
                            transform: nil
                        )
                    )
                    context.fillPath()
                }
                context.textMatrix = .identity
                context.textPosition = CGPoint(x: start.x, y: start.y - ascent)
                CTLineDraw(line, context)
                context.restoreGState()
            } else if annotation.kind == .rectangle {
                context.stroke(
                    CGRect(
                        x: min(start.x, end.x),
                        y: min(start.y, end.y),
                        width: abs(start.x - end.x),
                        height: abs(start.y - end.y)
                    )
                )
            } else if annotation.kind == .ellipse {
                context.strokeEllipse(
                    in: CGRect(
                        x: min(start.x, end.x),
                        y: min(start.y, end.y),
                        width: abs(start.x - end.x),
                        height: abs(start.y - end.y)
                    )
                )
            } else {
                context.beginPath()
                context.move(to: start)
                context.addLine(to: end)
                context.strokePath()
            }

            if annotation.kind == .arrow {
                let angle = atan2(end.y - start.y, end.x - start.x)
                let length = max(14, CGFloat(image.width) / 45)
                let spread = CGFloat.pi / 6
                let first = CGPoint(
                    x: end.x - length * cos(angle - spread),
                    y: end.y - length * sin(angle - spread)
                )
                let second = CGPoint(
                    x: end.x - length * cos(angle + spread),
                    y: end.y - length * sin(angle + spread)
                )
                context.beginPath()
                context.move(to: first)
                context.addLine(to: end)
                context.addLine(to: second)
                context.strokePath()
            }
        }

        guard let result = context.makeImage() else {
            throw CaptureError.imageEncodingFailed
        }
        return result
    }

    nonisolated private static func pixelatedImage(
        _ image: CGImage,
        blockSize: Int
    ) throws -> CGImage {
        let smallWidth = max(1, image.width / max(2, blockSize))
        let smallHeight = max(1, image.height / max(2, blockSize))
        guard let smallContext = CGContext(
            data: nil,
            width: smallWidth,
            height: smallHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CaptureError.imageEncodingFailed
        }
        smallContext.interpolationQuality = .none
        smallContext.draw(
            image,
            in: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight)
        )
        guard let reduced = smallContext.makeImage(),
              let outputContext = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw CaptureError.imageEncodingFailed
        }
        outputContext.interpolationQuality = .none
        outputContext.draw(
            reduced,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        guard let result = outputContext.makeImage() else {
            throw CaptureError.imageEncodingFailed
        }
        return result
    }

    private func restoreWindowsHiddenForCapture() {
        AppDelegate.shared?.setCaptureOverlayActive(false)
        windowsHiddenForCapture.forEach { window in
            let identifier = window.identifier?.rawValue ?? ""
            let isIndependentFloatingWindow = identifier == FloatingThumbnailController.windowIdentifier.rawValue
                || identifier.hasPrefix(PinnedScreenshotController.windowIdentifierPrefix)
            if isIndependentFloatingWindow {
                window.orderFrontRegardless()
            } else {
                window.orderFront(nil)
            }
        }
        windowsHiddenForCapture = []
        frozenDisplayImages.removeAll()
    }

    nonisolated private static func captureFailureMessage(
        prefix: String,
        error: Error
    ) -> String {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain ||
            nsError.localizedDescription.localizedCaseInsensitiveContains("permission") {
            return "\(prefix)：当前实例尚未获得屏幕录制能力。若系统设置已经开启，请重新启动 M · Imago。"
        }
        return "\(prefix)：\(error.localizedDescription)"
    }

    private func recordingDestination(format: RecordingFileFormat) throws -> URL {
        guard let directory = CapturePreferences.shared.saveDirectory else {
            throw CaptureError.saveDirectoryRequired
        }
        let fileExtension = format == .mp4 ? "mp4" : "mov"
        return directory.appendingPathComponent("M-Imago_\(Self.timestamp()).\(fileExtension)")
    }

    nonisolated private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: .now)
            .replacingOccurrences(of: ":", with: "-")
    }

    private func clearRecordingState() {
        RecordingStatusPanel.dismiss()
        recordingDurationTask?.cancel()
        recordingDurationTask = nil
        stream = nil
        recordingOutput = nil
        isStoppingRecording = false
        isCapturing = false
        isRecording = false
        restoreWindowsHiddenForCapture()
    }
}

private enum CaptureError: LocalizedError {
    case noDisplayAvailable
    case imageEncodingFailed
    case imageUnavailable
    case saveDirectoryRequired
    case invalidSelection
    case windowUnavailable
    case longScreenshotRequiresWindow
    case scrollableContentUnavailable
    case accessibilityPermissionRequired
    case longScreenshotNoMovement
    case longScreenshotTooLarge

    var errorDescription: String? {
        switch self {
        case .noDisplayAvailable: "未找到可捕获的显示器。"
        case .imageEncodingFailed: "无法编码截图。"
        case .imageUnavailable: "当前显示器无法生成截图。"
        case .saveDirectoryRequired: "请先选择公共保存位置。"
        case .invalidSelection: "请选择有效的截图区域。"
        case .windowUnavailable: "选中的窗口已经关闭或暂时不可捕获。"
        case .longScreenshotRequiresWindow: "截长图需要先单击选择一个窗口。"
        case .scrollableContentUnavailable: "没有在选中窗口中找到可滚动区域。"
        case .accessibilityPermissionRequired:
            "截长图未获得辅助功能控制权限。若系统设置已经开启，请完全退出并重新打开 M · Imago。"
        case .longScreenshotNoMovement: "窗口内容没有发生滚动，无法生成长图。"
        case .longScreenshotTooLarge: "长图尺寸超过当前版本的安全限制。"
        }
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }

    func approximatelyEquals(_ other: CGRect, tolerance: CGFloat = 4) -> Bool {
        abs(minX - other.minX) <= tolerance &&
            abs(minY - other.minY) <= tolerance &&
            abs(width - other.width) <= tolerance &&
            abs(height - other.height) <= tolerance
    }
}
