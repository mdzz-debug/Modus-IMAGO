import AppKit
import ApplicationServices
import AVFoundation
import CoreText
import FormaUI
import Foundation
import ScreenCaptureKit

@MainActor
final class MImagoPermissions {
    static let shared = MImagoPermissions()
    let center = FormaPermissionCenter()

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
                    "当前由 swift run 启动，无法使用已授予 M-Imago.app 的屏幕录制权限。请运行 zsh scripts/package-app.sh。"
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

@MainActor
final class CaptureController: NSObject, ObservableObject, SCStreamDelegate, SCRecordingOutputDelegate {
    static let shared = CaptureController()

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
        statusMessage = "正在处理选区…"
        Task { [weak self] in
            defer { self?.restoreWindowsHiddenForCapture() }
            do {
                try await Task.sleep(for: .milliseconds(120))

                let captured: CGImage
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
                    prefix: "自由截图失败",
                    error: error
                )
            }
        }
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
        statusMessage = screens.count > 1
            ? "在任意屏幕选择窗口，或拖拽自由区域"
            : "移动鼠标选择窗口，或拖拽自由区域"
        FreeSelectionOverlay.present(
            on: screens,
            windowCandidatesByDisplayID: candidatesByDisplayID,
            initialPointerGlobalLocation: initialPointerGlobalLocation
        ) { result in
            CaptureController.shared.isSelectionOverlayPresented = false
            CaptureController.shared.takeFreeScreenshot(result)
        } onCancel: {
            CaptureController.shared.cancelFreeScreenshot()
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
        normalizedRect: CGRect
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
        configuration.showsCursor = true
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []),
            configuration: configuration
        )
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

    private static func raiseWindow(windowID: CGWindowID, processID: pid_t) {
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

    private static func windowFrame(windowID: CGWindowID) -> CGRect? {
        guard let items = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            windowID
        ) as? [[CFString: Any]],
              let bounds = items.first?[kCGWindowBounds] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }

    private static func windowTitle(windowID: CGWindowID) -> String? {
        guard let items = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            windowID
        ) as? [[CFString: Any]],
              let title = items.first?[kCGWindowName] as? String,
              !title.isEmpty else { return nil }
        return title
    }

    private static func axWindowTitle(_ window: AXUIElement) -> String? {
        var rawTitle: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXTitleAttribute as CFString,
            &rawTitle
        ) == .success else { return nil }
        return rawTitle as? String
    }

    private static func axWindowFrame(_ window: AXUIElement) -> CGRect {
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
            if annotation.kind == .text {
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

    var errorDescription: String? {
        switch self {
        case .noDisplayAvailable: "未找到可捕获的显示器。"
        case .imageEncodingFailed: "无法编码截图。"
        case .imageUnavailable: "当前显示器无法生成截图。"
        case .saveDirectoryRequired: "请先选择公共保存位置。"
        case .invalidSelection: "请选择有效的截图区域。"
        case .windowUnavailable: "选中的窗口已经关闭或暂时不可捕获。"
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
